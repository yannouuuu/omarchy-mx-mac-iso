# Omarchy MX Mac ISO

Install images for [Omarchy MX Mac](https://github.com/maralcbr/omarchy-mx-mac)
on Apple Silicon. The shipped artifact is a GPT disk image (`.img`) with a
FAT32 ESP and a btrfs payload, not an ISO9660 file — the repo name keeps
"iso" so people searching next to Omarchy's x86 ISO find it.

Design: [`plans/apple-silicon-image.md`](plans/apple-silicon-image.md).

## Status

Stage S3-S4 (first cut): `bin/omarchy-mx-mac-iso-make` produces two artifacts:

- `release/root.img` — sparse btrfs payload with a provisioned Omarchy 4
  Quattro root filesystem from the **signed** asahi-quattro channel.
- `release/omarchy-mx-mac-live.img` — the bootable GPT disk image: FAT32 ESP
  (standalone GRUB, kernel, initramfs with the explicit `dwc3-apple` module
  list and an overlay/`switch_root` hook) plus the payload partition.
  The live boot lands on a gum TUI that asks every question the install
  pipeline will consume; it writes nothing to disk yet.

No real-hardware boot test has happened — flashing to USB and booting after
a UEFI-only provision is the next milestone. Until this image matures,
[`install-omarchy-mx-mac.sh`](https://github.com/maralcbr/omarchy-mx-mac#install-omarchy-4)
remains the supported installation path.

## Build

Requires Docker with an `linux/arm64` VM — Docker Desktop on Apple Silicon
works as-is (its kernel ships btrfs and loop devices). The first run imports
the official Arch Linux ARM bootstrap (~250 MB) and syncs repositories; later
builds reuse caches.

```bash
./bin/omarchy-mx-mac-iso-make            # build release/root.img
./bin/omarchy-mx-mac-iso-make --debug    # shell into the builder container
```

Around 15 GB of free disk space are needed for caches plus the artifacts.
They arrive sparse (the payload is a 6G ceiling holding ~2.5 GiB of real
content): `fstrim` inside the builder and a GNU sparse tar stream keep the
holes, so the allocated footprint stays near the content size.

## Layout

- `plans/` — living design docs, deleted once implemented
- `bin/` — thin host entry points
- `builder/` — everything that runs inside the container (`lib/` helpers are
  sourced, not executed)
- `configs/` — pacman configuration and the explicit package list
- `test/unit/` — bash tests, runnable anywhere `sfdisk` exists (skip cleanly
  elsewhere)

## Safety

Nothing here resizes or writes Apple partitions — APFS, iBoot, Recovery type
GUIDs are refused in code, only partitions created by the current run are
ever touched, and destructive paths require a clean `--dry-run` first. See
"Not bricking our machines" in the plan.

## Attribution

Hardware findings and overall shape inherited from
[`omarchy-mac/omarchy-mac-iso`](https://github.com/omarchy-mac/omarchy-mac-iso)
(MIT). Package integrity comes from the signed asahi-quattro channel of
[`maralcbr/omarchy-pkgs`](https://github.com/maralcbr/omarchy-pkgs).

## License

[MIT](LICENSE)
