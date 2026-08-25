#!/bin/bash
# Assembles release/omarchy-mx-mac-live.img from a staged root filesystem
# and the btrfs payload image.
#
# Layout (a) from plans/apple-silicon-image.md: GPT with a FAT32 ESP
# (standalone GRUB, kernel, live initramfs) followed by a Linux partition
# whose content IS the btrfs root.img. Partition numbers are read back from
# the table, never guessed.
#
# Usage: build-live-image.sh --rootfs DIR --payload IMG --out DIR

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

rootfs_dir=
payload_img=
out_dir=
while (($#)); do
  case "$1" in
    --rootfs)
      (($# > 1)) || fail "--rootfs requires a directory."
      rootfs_dir=$2
      shift
      ;;
    --payload)
      (($# > 1)) || fail "--payload requires an image."
      payload_img=$2
      shift
      ;;
    --out)
      (($# > 1)) || fail "--out requires a directory."
      out_dir=$2
      shift
      ;;
    *)
      fail "Unknown option '$1'."
      ;;
  esac
  shift
done

[[ -d $rootfs_dir && -f $payload_img && -d $out_dir ]] ||
  fail "A staged rootfs directory, the payload image, and an output directory are required."

for command_name in dd grub-mkstandalone mkfs.vfat sfdisk truncate; do
  command -v "$command_name" >/dev/null 2>&1 || fail "Required command '$command_name' is unavailable."
done
(( EUID == 0 )) || fail "Run me as root inside the builder container."

work_dir=$(mktemp -d "$out_dir/.live.XXXXXXXX")
cleanup() {
  local mount_point
  for mount_point in "$rootfs_dir/dev" "$rootfs_dir/sys" "$rootfs_dir/proc"; do
    mountpoint -q "$mount_point" && umount "$mount_point"
  done
  if [[ -n ${esp_mnt:-} ]]; then
    mountpoint -q "$esp_mnt" && umount "$esp_mnt"
    losetup -D 2>/dev/null || true
  fi
}
trap cleanup EXIT

say() { printf '=> %s\n' "$*" >&2; }

kver=""
for module_dir in "$rootfs_dir"/usr/lib/modules/*; do
  module_dir_name=${module_dir##*/}
  [[ $module_dir_name == extramodules* ]] && continue
  if [[ -z $kver ]] || [[ $module_dir_name > $kver ]]; then
    kver=$module_dir_name
  fi
done
[[ -d $rootfs_dir/usr/lib/modules/$kver ]] ||
  fail "No kernel module tree found in the staged root."
# linux-asahi ships the kernel inside its module tree, not in /boot.
kernel_image="$rootfs_dir/usr/lib/modules/$kver/vmlinuz"
[[ -f $kernel_image ]] || fail "The staged root has no kernel image."
say "Kernel version: $kver"

say "Preparing the live initramfs (generated inside the staged root)"
for bind_dir in proc sys dev; do
  mkdir -p "$rootfs_dir/$bind_dir"
  mount --bind "/$bind_dir" "$rootfs_dir/$bind_dir"
done
install -m 0644 "$repo_root/builder/live/mkinitcpio.conf" "$rootfs_dir/tmp/mkinitcpio-live.conf"
install -m 0755 "$repo_root/builder/live/install/omarchy-live" \
  "$rootfs_dir/usr/lib/initcpio/install/omarchy-live"
install -m 0755 "$repo_root/builder/live/hooks/omarchy-live" \
  "$rootfs_dir/usr/lib/initcpio/hooks/omarchy-live"
chroot "$rootfs_dir" depmod "$kver"
chroot "$rootfs_dir" mkinitcpio --config /tmp/mkinitcpio-live.conf -k "$kver" \
  -g /tmp/live-initramfs.img
mv "$rootfs_dir/tmp/live-initramfs.img" "$work_dir/initramfs-linux-asahi.img"
rm -f "$rootfs_dir/tmp/mkinitcpio-live.conf"
for bind_dir in dev sys proc; do
  mountpoint -q "$rootfs_dir/$bind_dir" && umount "$rootfs_dir/$bind_dir"
done

say "Building the standalone GRUB EFI binary"
# The explicit module lists are load-bearing: without them the binary only
# auto-loads what the memdisk pulls in, and search finds no filesystems
# (proven on hardware by omarchy-mac).
efi_dir="$work_dir/esp-content"
mkdir -p "$efi_dir/EFI/BOOT" "$efi_dir/grub"
grub-mkstandalone -O arm64-efi \
  --fonts="" --locales="" --themes="" \
  --install-modules="linux fat ext2 btrfs part_gpt search search_label search_fs_uuid search_fs_file echo normal configfile gzio reboot sleep" \
  --modules="part_gpt fat search search_fs_file configfile linux echo normal" \
  -o "$efi_dir/EFI/BOOT/BOOTAA64.EFI" \
  "boot/grub/grub.cfg=$repo_root/builder/live/grub-embed.cfg" >/dev/null
# The real menu is a plain file on the ESP: cmdline experiments never
# require a rebuild, just an edit from macOS.
cp "$repo_root/builder/live/grub.cfg" "$efi_dir/grub/grub.cfg"
: >"$efi_dir/omarchy-usb-live"
cp "$kernel_image" "$efi_dir/vmlinuz-linux-asahi"
cp "$work_dir/initramfs-linux-asahi.img" "$efi_dir/initramfs-linux-asahi.img"

say "Creating the FAT32 live ESP"
esp_img="$work_dir/esp.img"
truncate -s 512M "$esp_img"
# FAT volume labels are limited to 11 characters.
mkfs.vfat -n MXMAC-LIVE "$esp_img" >/dev/null
esp_mnt="$work_dir/esp-mnt"
mkdir "$esp_mnt"
mount -o loop "$esp_img" "$esp_mnt"
cp -a "$efi_dir/." "$esp_mnt/"
sync
umount "$esp_mnt"
esp_mnt=

say "Laying out the GPT disk image"
final_img="$out_dir/omarchy-mx-mac-live.img"
rm -f "$final_img"
payload_size=$(stat -c %s "$payload_img")
slack=$((1024 * 1024))
esp_sectors=$((512 * 1024 * 1024 / 512))
truncate -s $((2048 * 512 + esp_sectors * 512 + payload_size + slack)) "$final_img"
sfdisk "$final_img" <<EOF
label: gpt
name=omarchy-mx-esp, size=$esp_sectors, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
name=omarchy-mx-root, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
EOF

table=$(sfdisk -d "$final_img")
# Partition names are not echoed by sfdisk -d; match on the type GUIDs.
# Numbers come space-padded ("start=        2048"), so strip blanks first.
strip_line() { tr -d '[:space:]' <<<"$1"; }
start_esp=$(sed -n 's/.*start=\([0-9]*\),.*/\1/p' <<<"$(strip_line "$(
  grep 'type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B,' <<<"$table"
)")")
start_root=$(sed -n 's/.*start=\([0-9]*\),.*/\1/p' <<<"$(strip_line "$(
  grep 'type=0FC63DAF-8483-4772-8E79-3D69D8477DE4,' <<<"$table"
)")")
[[ -n $start_esp && -n $start_root ]] || fail "Could not parse the partition offsets."
say "ESP at sector $start_esp, payload at sector $start_root"

say "Writing partition contents"
dd if="$esp_img" of="$final_img" bs=512 seek="$start_esp" conv=notrunc status=none
dd if="$payload_img" of="$final_img" bs=4M seek="$((start_root * 512))" \
  oflag=seek_bytes conv=notrunc,sparse status=none
rm -f "$esp_img"

say "Writing checksum"
sha256sum "$final_img" >"$final_img.sha256"

apparent=$(du -h --apparent-size "$final_img" | cut -f1)
actual=$(du -h "$final_img" | cut -f1)
printf '\nDone: %s\n  apparent size %s, allocated %s\n  sha256 %s\n' \
  "$final_img" "$apparent" "$actual" "$(cut -d' ' -f1 "$final_img.sha256")"
