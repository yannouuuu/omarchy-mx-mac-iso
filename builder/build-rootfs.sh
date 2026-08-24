#!/bin/bash
# Builds release/root.img inside the builder container (run as root).
#
# Pipeline: stage a root filesystem with pacman against configs/pacman.conf,
# layer the signed asahi-quattro bundle on top, apply build-time hardware
# provisioning, then assemble the sparse btrfs payload image with @/@home/@log
# subvolumes. Pacman hooks are disabled during staging on purpose: initramfs
# generation and user creation happen at install time (mkinitcpio -P,
# systemd-sysusers at first boot), keeping this artifact deterministic.
#
# Usage: build-rootfs.sh [--out DIR] [--size SIZE]

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
configs_dir="$repo_root/configs"

out_dir=/out
image_size=16G

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --out)
      (($# > 1)) || fail "--out requires a directory."
      out_dir=$2
      shift
      ;;
    --size)
      (($# > 1)) || fail "--size requires a size, e.g. 16G."
      image_size=$2
      shift
      ;;
    *)
      fail "Unknown option '$1'."
      ;;
  esac
  shift
done

(( EUID == 0 )) || fail "Run me as root inside the builder container."

for command_name in bsdtar curl gpg mkfs.btrfs mount pacman pacstrap sha256sum sfdisk truncate rsync losetup; do
  command -v "$command_name" >/dev/null 2>&1 || fail "Required command '$command_name' is unavailable."
done

[[ -f $configs_dir/pacman.conf && -f $configs_dir/packages.txt ]] ||
  fail "configs/pacman.conf or configs/packages.txt is missing."

mapfile -t packages < <(grep -vE '^[[:space:]]*(#|$)' "$configs_dir/packages.txt")
(( ${#packages[@]} > 0 )) || fail "No packages listed in configs/packages.txt."

mkdir -p "$out_dir"
work_dir=$(mktemp -d "$out_dir/.build.XXXXXXXX")
trap 'rm -rf "$work_dir"' EXIT
rootfs_dir="$work_dir/rootfs"
bundle_dir="$work_dir/bundle"
hook_dir="$work_dir/empty-hooks"
cache_dir=/cache/pacman
mkdir -p "$rootfs_dir" "$bundle_dir" "$hook_dir" "$cache_dir"

pac_flags=(
  --config "$configs_dir/pacman.conf"
  --root "$rootfs_dir"
  --cachedir "$cache_dir"
  --hookdir "$hook_dir"
  --logfile "$work_dir/pacman.log"
  --noconfirm
  --needed
)

say() { printf '=> %s\n' "$*"; }

say "Syncing repository databases"
mkdir -p "$rootfs_dir/var/lib/pacman"
pacman "${pac_flags[@]}" -Sy

say "Installing ${#packages[@]} repository packages into the staged root"
pacman "${pac_flags[@]}" -S "${packages[@]}"

say "Verifying the signed asahi-quattro channel"
bash "$repo_root/builder/verify-channel.sh" "$bundle_dir"

say "Installing the six verified bundle packages"
pacman "${pac_flags[@]}" -U "$bundle_dir"/*.pkg.tar.*

say "Applying build-time provisioning"

install -D -m 0644 "$configs_dir/pacman.conf" "$rootfs_dir/etc/pacman.conf"
: >"$rootfs_dir/etc/machine-id"

cat >"$rootfs_dir/etc/modprobe.d/omarchy-mac.conf" <<'EOF'
options hid_apple fnmode=1
options appledrm show_notch=1
EOF

install -D -m 0644 /dev/null "$rootfs_dir/etc/NetworkManager/conf.d/wifi-backend.conf"
cat >"$rootfs_dir/etc/NetworkManager/conf.d/wifi-backend.conf" <<'EOF'
[device]
wifi.backend=iwd
EOF

wants_dir=$rootfs_dir/etc/systemd/system/multi-user.target.wants
mkdir -p "$wants_dir"
for service_name in NetworkManager.service iwd.service; do
  ln -sf "/usr/lib/systemd/system/$service_name" "$wants_dir/$service_name"
done

target_gnupg=$rootfs_dir/etc/pacman.d/gnupg
pacman-key --gpgdir "$target_gnupg" --init >/dev/null

# Keyrings shipped in this builder container import through --populate.
populate_names=()
for keyring_name in archlinux archlinuxarm asahi-alarm omarchy; do
  if [[ -f /usr/share/pacman/keyrings/$keyring_name.gpg ]]; then
    populate_names+=("$keyring_name")
  fi
done
if (( ${#populate_names[@]} )); then
  pacman-key --gpgdir "$target_gnupg" --populate "${populate_names[@]}" >/dev/null
fi

# Keyrings that only exist inside the staged root (omarchy-keyring comes
# from the signed bundle, not a repository) are imported by hand and every
# key locally signed so Required signatures verify.
import_staged_keyring() {
  local keyring_path=$1 fingerprint
  pacman-key --gpgdir "$target_gnupg" --add "$keyring_path"
  while IFS= read -r fingerprint; do
    pacman-key --gpgdir "$target_gnupg" --lsign-key "$fingerprint" >/dev/null
  done < <(gpg --show-keys --with-colons "$keyring_path" |
    awk -F: '$1 == "fpr" { print $10 }')
}

for keyring_path in "$rootfs_dir"/usr/share/pacman/keyrings/*.gpg; do
  [[ -e $keyring_path ]] || break
  keyring_name=$(basename "$keyring_path" .gpg)
  case ",${populate_names[*]}," in
    *",$keyring_name,"*) continue ;;
  esac
  say "Importing staged keyring $keyring_name"
  import_staged_keyring "$keyring_path"
done

say "Probing loop devices and the btrfs module"
probe_img="$work_dir/probe.img"
truncate -s 128M "$probe_img"
probe_mnt="$work_dir/probe-mnt"
mkdir "$probe_mnt"
# modprobe is allowed to fail: kernels with CONFIG_BTRFS_FS=y (Docker
# Desktop's linuxkit) have no module file but do support the filesystem.
modprobe btrfs >/dev/null 2>&1 || true
if mkfs.btrfs -q "$probe_img" &&
  mount -o loop "$probe_img" "$probe_mnt" 2>/dev/null &&
  umount "$probe_mnt"; then
  rm -f "$probe_img"
else
  rm -f "$probe_img"
  fail "The container kernel cannot loop-mount btrfs. On Docker Desktop use colima instead: 'colima start --arch aarch64 --vm-type vz', or build on an ubuntu-24.04-arm CI runner."
fi

say "Assembling root.img ($image_size, sparse)"
image_path="$out_dir/root.img"
rm -f "$image_path"
truncate -s "$image_size" "$image_path"
mkfs.btrfs -q -L omarchy-mx-mac "$image_path"
mnt_dir="$work_dir/mnt"
mkdir "$mnt_dir"
mount -o loop "$image_path" "$mnt_dir"

for subvol_name in @ @home @log; do
  btrfs subvolume create "$mnt_dir/$subvol_name" >/dev/null
done

say "Populating @"
rsync -aHAX --numeric-ids "$rootfs_dir"/ "$mnt_dir/@/"

umount "$mnt_dir"
rm -rf "$rootfs_dir" "$bundle_dir"

apparent=$(du -h --apparent-size "$image_path" | cut -f1)
actual=$(du -h "$image_path" | cut -f1)
say "Writing checksum"
sha256sum "$image_path" >"$image_path.sha256"

printf '\nDone: %s\n  apparent size %s, allocated %s\n  sha256 %s\n' \
  "$image_path" "$apparent" "$actual" "$(cut -d' ' -f1 "$image_path.sha256")"
