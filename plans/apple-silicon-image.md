# Plan: an Apple Silicon install image for Omarchy MX Mac

> Adapted for Omarchy MX Mac from
> `omarchy-mac/omarchy-mac-iso` `plans/apple-silicon-image.md`
> (MIT License, Copyright (c) 2026 Omarchy Mac). Hardware findings from their
> 2026-08-22 spike are inherited, not re-proven. Divergences from that plan
> are stated deliberately in "Divergence from omarchy-mac" below.

## Context

Installing Omarchy MX Mac today is two network-dependent steps: the Asahi
Alarm installer from macOS (~8 min), then `install-omarchy-mx-mac.sh` on the
booted Asahi Arch Minimal system (packages, user creation, Quattro setup,
multiple minutes on the network). It works and it is signed end to end, but it
is a long tail of steps where any failure lands the user in a half-built
machine, and it needs working networking (`nmtui`) before anything starts.

The shape proposed by omarchy-mac holds for us too: do Asahi's one-time
UEFI-only provision from macOS, then boot our own USB straight into a live
installer that pulls firmware from the internal ESP and installs from a
bundled offline root image. Target: macOS step unchanged (~6-8 min, dominated
by Apple's own stub download and not compressible), then **one boot, one set
of questions, one reboot, a few minutes**, fully offline, with encryption as a
fresh `luksFormat` instead of an in-place migration.

Upstream Omarchy's own plans state Apple Silicon (Asahi) is out of scope.
omarchy-mac claims that lane for their fork; this repo claims it for ours.

## What was verified on hardware (inherited, 2026-08-22, M2 Max)

Spikes by omarchy-mac in `~/code/omarchy-mac-iso-spike/`. We treat these as
established and do not repeat them:

| Claim | Consequence for us |
|---|---|
| Firmware comes from the internal ESP with no custom code | Stock `asahi` initcpio hook; `/boot/vendorfw/firmware.cpio` (~32 MB) is loaded from the System ESP. |
| USB storage works in an initramfs **if `dwc3-apple` is present** | Our live initramfs carries an explicit module list and does not trust the packaged asahi hook (stale: adds `dwc3? dwc3-of-simple?`, never `dwc3-apple`). |
| The "USB-PD dependency cycle" dmesg noise is harmless | No `fw_devlink=permissive` needed. |
| Loop-mount of a USB `root.img` works | Payload-on-FAT layout proven; we ship the cleaner partition-payload layout. |
| U-Boot boots a stick: `usb start; bootflow scan -l usb; bootflow select 0; bootflow boot` | Fresh UEFI-only machines have no NVMe EFI payload, so the stick wins automatically. Do not `saveenv`. |
| Built-in keyboard works in U-Boot via `stdin=serial,usbkbd,spikbd,mtpkbd` | Installer questions can run before Linux drivers exist. |
| We must not touch APFS | Altering APFS containers forces a DFU restore. UEFI-only leaves unallocated GPT space for the root. |
| The medium needs its own ESP and must not manage `boot.bin` until installed | Live USB GRUB is `grub-mkstandalone`. After install we own `update-m1n1`; the live installer does not. |

Still unproven anywhere (ours to prove when we get there): Wi-Fi association
in the live environment, overlay + `switch_root` into a writable userspace,
and the install `dd` onto a target disk.

## Architecture: one rootfs, two front doors

Build a single provisioned Omarchy 4 Quattro root filesystem image, then ship
it two ways:

1. **Live USB image** (`.img`, GPT + FAT32 ESP + btrfs payload partition).
   Boots via m1n1/U-Boot after a UEFI-only provision, runs a TUI installer,
   supports fresh `luksFormat`, doubles as a repair/reinstall medium. This is
   the encrypted default path and the first artifact this repo builds.
2. **asahi-installer os package** (zip + our own `installer_data.json`) — the
   macOS one-liner offers "Omarchy MX Mac" directly, no USB stick.
   Unencrypted fast path; encrypt afterwards with the same tooling the
   installer uses, never a full reinstall.

The payload is **one artifact**: `root.img`, a btrfs filesystem image with
`@` / `@home` / `@log` subvolumes (`@factory` snapshot is taken at install
time). Keep the filesystem **uncompressed internally** so the published zip
still shrinks; internal btrfs zstd would make the zip larger, not smaller.
After install, new writes can compress normally.

Two layouts work. Prefer (a) for shipping:

- **(a) Payload partition that *is* the btrfs image.** GPT: FAT32 ESP + one
  Linux partition. Live boot mounts that partition read-only, overlays a
  tmpfs, then `switch_root`. Install is `dd` of the partition onto the target.
- **(b) `root.img` as a file on the FAT ESP.** Fine for development; extra
  loop layer in production.

Live boot command line: `systemd.unit=omarchy-mx-mac-install.target` so only
the installer starts. Booting the default target later gives a live desktop
for free.

Initramfs (small): `base asahi udev` plus the explicit module list that does
not trust the packaged asahi hook for USB:

```
dwc3-apple dwc3 phy-apple-atc mux-apple-display-crossbar
tps6598x typec xhci-plat-hcd xhci-hcd usb-storage uas loop
```

Then a hook that waits for the payload, sets up overlay, `switch_root`.

Install pipeline (S4):

```
pick target free space → parted (read back the slot, never guess) →
optional fresh luksFormat → dd root.img onto the new partition →
btrfs resize max → btrfstune -u → personalize (fstab, crypttab, hostname,
user, keymap, locale) → mkinitcpio -P (asahi hook **and** dwc3-apple) →
GRUB into the existing ESP (EFI/BOOT and grub/ only) → @factory snapshot →
reboot
```

Hard constraints, enforced as refusals in code, not comments:

- Never resize or touch APFS (`7C3457EF-…`), iBoot (`69646961-…`), or
  Recovery (`52637672-…`). Refuse every GPT type GUID carrying the shared
  Apple suffix `-11AA-AA11-00306543ECAC`.
- Only write to partitions the current run created (`created_parts[]` +
  rollback).
- Never write `m1n1/boot.bin`, `vendorfw/`, or `asahi/` on the internal ESP.
  Writing `EFI/BOOT/BOOTAA64.EFI` and `grub/` is required so the installed
  system boots; leave Asahi's pairing data alone.
- Never create a second ESP on the USB-after-UEFI-only path.
- After install the OS **does** own `update-m1n1`.
- `--dry-run` prints every destructive command; require a clean dry run
  before a real one.

Deliberately **not** an ISO9660 hybrid and **not** archiso. Asahi wants a
FAT32 ESP with `BOOTAA64.EFI`. If a mount hook fights us, copy archiso's
overlay hook approach, not mkarchiso.

### Divergence from omarchy-mac, stated deliberately

Same idea, different package politics:

- They pull Omarchy packages from a rolling `[omarchy-aarch64]` edge repo.
  We consume the **signed asahi-quattro channel**
  (`maralcbr/omarchy-pkgs`, tag `asahi-quattro-channel`): channel pointer →
  release descriptor → six-package manifest, all GPG-signed against the
  pinned release key fingerprint
  `5983B1CA32CB778F4D74D24ECFF35022CA5B5959`, with `source_commit` pinning.
  The image must be as reproducible and attributable as
  `install-omarchy-mx-mac.sh`, not more rolling than it.
- We install **final Omarchy 4 Quattro directly** — never an intermediate v3.
- Base system is Arch Linux ARM + `[asahi-alarm]` + `[aur]`, matching what
  the signed fresh installer requires (`core extra alarm aur asahi-alarm`,
  `linux-asahi`, `networkmanager`, `iwd`, `grub`).
- Wi-Fi backend stays NetworkManager with iwd — already validated on M1 Pro
  (`apple,j314s`) by the release regression.
- Their os-package front door targets their edge flow; our S5 will wrap the
  same signed bundle instead. Deferred until the USB image works.

Do **not** bake the pacman package cache into `root.img` (~2 GB here). That
fights the GitHub Releases 2 GiB per-file cap and the "dd in seconds" target.
Optional apps offline can be a second artifact later.

### Rejected: live root inside the initramfs

A multi-GB initramfs under GRUB/U-Boot was parked by omarchy-mac once USB in
the initramfs worked; same call here. Unproven risks remain (contiguous EFI
`AllocatePages`, unpack RAM on 8 GB machines) and we do not need them.

## Repo conventions

A separate repo from `maralcbr/omarchy-mx-mac`, mirroring omarchy-mac's split:
the main repo stays the desktop fork; this one owns image building. The name
keeps "iso" for discoverability even though the artifact is a `.img`.

- `bin/omarchy-mx-mac-iso-make` — thin host script driving the container;
  future siblings `-boot`, `-test`, `-release`, `-upload`.
- `builder/` — Containerfile + build scripts, everything runs inside the
  container, output `chown`ed back to `HOST_UID:HOST_GID`.
- `configs/` — pacman.conf, explicit package list.
- `plans/*.md` as living design docs, deleted once implemented.
- `test/unit/` — bash tests; partitioning/safety logic tested against
  loopback image files (works unprivileged inside any Linux container).

Style follows the mx repo AGENTS.md: `#!/bin/bash`, two spaces, bash 5
conditionals, atomic commits.

## Build inputs

- Repositories: `[core] [extra] [alarm] [aur]` from
  `mirror.archlinuxarm.org` (no valid TLS there; archives are `.pkg.tar.xz`),
  plus `[asahi-alarm]` from
  `github.com/asahi-alarm/asahi-alarm/releases/download/$arch`.
- Asahi stack installed into the image: `linux-asahi`, `m1n1`,
  `uboot-asahi`, `grub`, `asahi-scripts`, `asahi-configs`, `asahi-fwextract`,
  `asahi-audio`, `alsa-ucm-conf-asahi`, Mesa Vulkan asahi driver,
  `speakersafetyd`, PipeWire/Pulse wiring.
- Signed quattro bundle: `omarchy-keyring` (installed first),
  `omarchy-settings-dev`, `omarchy-dev`, `omarchy-nvim`, `quickshell-git`,
  `ttf-jetbrains-mono-nerd-basic` — exactly the manifest order and arches the
  release descriptor pins, verified per-package (checksum + signature +
  `.PKGINFO` identity + paired `omarchy-quattro-bundle=` provides).
- Build-time hardware provisioning (not per-machine): `hid_apple fnmode=1`,
  `appledrm show_notch=1`, audio stack defaults. Per-machine things
  (keymap, user, hostname, encryption) stay deferred to installer/first boot.
- Do not apply upstream's `fix-brcmfmac-supplicant.sh` on Asahi (it wedges
  BCM4387).

## Build time and size

omarchy-mac measured, for ~950 packages on M2 Max: cold **~12-20 min**, warm
**~7-11 min** (pacstrap dominates either way). Expect similar in a container
on Apple Silicon. Alarm Minimal's `root.img` is ~2.06 GiB raw; a full desktop
image looks like Alarm Desktop (12.7 GB raw, 1.88 GiB zipped). GitHub
Releases caps single files at 2 GiB — measure our zip before picking hosting
(Releases vs R2 vs split assets); that decision is deferred until S3 prints a
number.

CI shape (S6): `ubuntu-24.04-arm` runner, buildx, `jlumbroso/free-disk-space`,
nightly + `workflow_dispatch`. Privileged containers are required for loop
devices; until the root is lean, local Apple Silicon stays the release
builder.

On macOS hosts specifically: Docker Desktop's linuxkit kernel (6.12 as of
2026-08) ships btrfs built-in and working loop devices, so the probe passes
there — verified during the first S3 build. Two macOS quirks are handled by
the host script: a stuck credential helper makes every registry call hang
(bypassed with an empty client config, we only pull public images), and
`docker cp` does not preserve sparseness, so the copied artifact allocates
its full size.

## Not bricking our machines

First-class requirement, inherited verbatim in spirit: Apple Silicon cannot
be permanently bricked by software — boot ROM is immutable and DFU restore
always recovers. The real worst case ("macOS gone, needs a second Mac") is a
ruined day, not a dead laptop. Our code never performs the dangerous
operation: APFS resizing, boot policy, LocalPolicy, 1TR, and m1n1 stage-1
live inside Asahi's installer, which we do not reimplement. We start from
UEFI-only + unallocated space and only write into space we created.

Rails, cheapest first:

1. Partitioning unit-tested against loopback image files.
2. Refuse Apple GPT type GUIDs in code, not comments.
3. Only write to partitions this run created (`created_parts[]` + rollback).
4. `--dry-run` printing every destructive command.
5. Develop against external disks (`--target /dev/sdX`).
6. Backup the target GPT off-machine before any internal-disk test
   (`sfdisk --dump`, `sgdisk --backup`).
7. Assert the internal ESP is byte-identical for `m1n1/boot.bin`,
   `vendorfw/`, `asahi/` before and after an install test.

## Stages

- **S0 — Repo hygiene**: done; this file is the first commit.
- **S1 — Hardware spike**: inherited from omarchy-mac; re-confirm on one M1/M2
  machine when the first stick exists.
- **S2 — Builder container**: `bin/omarchy-mx-mac-iso-make` running
  `docker --platform linux/arm64` from Arch Linux ARM with `[asahi-alarm]`;
  native on a Mac first, then CI. **This session.**
- **S3 — The rootfs artifact**: pacstrap → Asahi stack → signed quattro
  bundle → build-time provisioning → sparse `root.img` (btrfs, `@/@home/@log`,
  uncompressed internally). Regenerate btrfs UUID at install (`btrfstune -u`).
  **This session, basic version.**
- **S4 — The installer**: overlay + `switch_root` live boot, TUI (gum),
  questions sourced like the mx installers (username, password, hostname,
  keymap) plus its own encrypt question (default yes). Install pipeline above.
- **S5 — asahi-installer os package**: same `root.img` + `esp/` (GRUB,
  kernel, initramfs on the ESP), wrapping the signed bundle. Later.
- **S6 — CI and hosting**: `workflow_dispatch` green before nightly; hosting
  decided by measured size.
- **S7 — Testing**: unit tests in-container; hardware installs go to an
  external disk first; no Apple SoC QEMU.

## Verification

1. `bash -n` over every script; shellcheck clean where available.
2. `test/unit/gpt-safety-test.sh` green (Apple GUID refusals, rollback).
3. `bin/omarchy-mx-mac-iso-make` produces `release/root.img`; it mounts read
   only and shows the expected subvolumes.
4. Later: external-disk install (unencrypted, then encrypted), boot both,
   Wi-Fi/audio/brightness/media keys, `@factory` visible to snapshots.
5. Later: internal ESP byte-identical check across an install test.
6. Later: timed end-to-end against the current two-script path.

## Coordination

Work lands in `maralcbr/omarchy-mx-mac-iso`, not as PRs into omarchy-mac.
`install-omarchy-mx-mac.sh` remains the supported install path for existing
and new users while this image matures; nothing in this repo may break or
shadow it. When the image is real, the README of the main repo gets a
pointer, not a switch.
