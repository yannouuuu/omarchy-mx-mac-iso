#!/bin/bash
# Ensures a local Docker base image built from the official
# Arch Linux ARM aarch64 bootstrap tarball exists. No registry hosts an
# arm64 Arch container image, so we import the bootstrap directly.
#
# Runs on the host, before docker build. Idempotent: skips when the image
# is already imported, unless --force is given.

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
docker_bin="${DOCKER:-docker}"
base_image=omarchy-mx-mac-alarm-base
bootstrap_url="${ALARM_BOOTSTRAP_URL:-http://mirror.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz}"
cache_dir="$repo_root/.cache"

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

force=0
[[ ${1:-} == "--force" ]] && force=1
(( $# <= 1 )) || fail "Usage: fetch-bootstrap.sh [--force]"

if (( force == 0 )) && "$docker_bin" image inspect "$base_image" >/dev/null 2>&1; then
  printf '=> Base image %s already imported\n' "$base_image"
  exit 0
fi

command -v curl >/dev/null 2>&1 || fail "curl is unavailable."
mkdir -p "$cache_dir"

tar_path="$cache_dir/ArchLinuxARM-aarch64-latest.tar.gz"
if [[ ! -f $tar_path ]]; then
  printf '=> Downloading %s\n' "${bootstrap_url##*/}"
  curl --fail --location --retry 3 --output "$tar_path.part" "$bootstrap_url" ||
    fail "Could not download the Arch Linux ARM bootstrap."
  mv "$tar_path.part" "$tar_path"
fi

printf '=> Verifying checksum\n'
# The md5 lives on the flaky http mirror; a cached-and-verified tarball
# skips it entirely so repeat builds work offline.
marker="$tar_path.verified"
if [[ -f $marker ]]; then
  printf '=> Bootstrap tarball already verified\n'
else
  if ! expected=$(curl --fail --location --retry 3 -s "$bootstrap_url.md5" | awk '{ print $1 }'); then
    fail "Could not download the bootstrap checksum."
  fi
  [[ $expected =~ ^[0-9a-f]{32}$ ]] || fail "Could not read the bootstrap checksum."
  if command -v md5sum >/dev/null 2>&1; then
    actual=$(md5sum "$tar_path" | awk '{ print $1 }')
  else
    actual=$(md5 -q "$tar_path")
  fi
  [[ $actual == "$expected" ]] || fail "Bootstrap checksum mismatch."
  touch "$marker"
fi

printf '=> Importing %s into Docker\n' "$base_image"
gzip -dc "$tar_path" | "$docker_bin" import \
  --change 'CMD ["/bin/bash"]' \
  - "$base_image" >/dev/null
printf '=> Base image %s ready\n' "$base_image"
