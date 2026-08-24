#!/bin/bash
# Downloads and verifies the signed asahi-quattro channel into a bundle dir.
#
# Mirrors the verification chain of install-asahi-quattro exactly:
# pinned release key fingerprint, signed channel pointer, signed release
# descriptor with source_commit pinning, signed six-package manifest, and
# per-package checksum + signature + .PKGINFO identity checks.
#
# Usage: verify-channel.sh [--verify-only] [--release-tag TAG] BUNDLE_DIR
#
# Environment overrides (same names as the upstream installer where they
# exist):
#   ASAHI_QUATTRO_DOWNLOAD_BASE_URL   release asset base URL
#   ASAHI_QUATTRO_KEY_URL             release signing key location
#   OMARCHY_MX_MAC_ISO_KEY_FINGERPRINT  pinned key fingerprint override

set -euo pipefail

REPOSITORY=maralcbr/omarchy-pkgs
CHANNEL_TAG=asahi-quattro-channel
KEY_FINGERPRINT="${OMARCHY_MX_MAC_ISO_KEY_FINGERPRINT:-5983B1CA32CB778F4D74D24ECFF35022CA5B5959}"
DOWNLOAD_BASE_URL="${ASAHI_QUATTRO_DOWNLOAD_BASE_URL:-https://github.com/$REPOSITORY/releases/download}"
KEY_URL="${ASAHI_QUATTRO_KEY_URL:-https://raw.githubusercontent.com/maralcbr/omarchy-mx-mac/main/default/omarchy-release.gpg}"

EXPECTED_PACKAGES=(omarchy-keyring omarchy-settings-dev omarchy-dev omarchy-nvim quickshell-git ttf-jetbrains-mono-nerd-basic)
EXPECTED_ARCHES=(any aarch64 aarch64 any aarch64 any)

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

usage() {
  grep '^#' "$0" | sed -n '8,14s/^# \{0,1\}//p'
  exit "${1:-0}"
}

verify_only=0
release_tag=""
while (($#)); do
  case "$1" in
    --verify-only)
      verify_only=1
      ;;
    --release-tag)
      (($# > 1)) || fail "--release-tag requires a tag."
      release_tag="$2"
      shift
      ;;
    -h|--help)
      usage
      ;;
    -*)
      fail "Unknown option '$1'."
      ;;
    *)
      break
      ;;
  esac
  shift
done
(( $# == 1 )) || fail "Exactly one bundle directory is required."
bundle_dir=$1

for command_name in bsdtar curl gpg sha256sum; do
  command -v "$command_name" >/dev/null 2>&1 || fail "Required command '$command_name' is unavailable."
done
[[ $release_tag =~ ^asahi-quattro-[0-9a-f]{8}$ ]] || [[ -z $release_tag ]] || fail "Invalid release tag."
mkdir -p "$bundle_dir"

work_dir=$(mktemp -d "$bundle_dir/.verify.XXXXXXXX")
trap 'rm -rf "$work_dir"' EXIT
gnupg_dir="$work_dir/gnupg"
mkdir -m 0700 "$gnupg_dir"

say() { printf '=> %s\n' "$*" >&2; }

download_url() {
  local url=$1 destination=$2
  say "Downloading ${url##*/}"
  curl --proto '=https' --tlsv1.2 --fail --location --retry 3 --silent --output "$destination" "$url" ||
    fail "Download failed: ${url##*/}."
}

download_release_asset() {
  download_url "$DOWNLOAD_BASE_URL/$1/$2" "$3"
}

read_field() {
  sed -n "s/^$1=//p" "$2" | head -1
}

key_file="$work_dir/omarchy-release.gpg"
download_url "$KEY_URL" "$key_file"
actual_fingerprint=$(gpg --batch --show-keys --with-colons "$key_file" |
  awk -F: '$1 == "fpr" { print $10; exit }')
[[ $actual_fingerprint == "$KEY_FINGERPRINT" ]] ||
  fail "Omarchy signing key fingerprint mismatch: got '${actual_fingerprint:-none}'."
gpg --batch --homedir "$gnupg_dir" --import "$key_file" >/dev/null 2>&1 ||
  fail "Could not import the Omarchy signing key."

verify_signature() {
  # The isolated keyring contains only the pinned public key; signatures may
  # be made by its signing subkey.
  gpg --batch --homedir "$gnupg_dir" --verify "$2" "$1" >/dev/null 2>&1 ||
    fail "Signature verification failed for '${1##*/}'."
}

channel_sequence=""
if [[ -z $release_tag ]]; then
  say "Reading the channel pointer"
  channel="$work_dir/asahi-quattro-channel"
  download_release_asset "$CHANNEL_TAG" asahi-quattro-channel "$channel"
  download_release_asset "$CHANNEL_TAG" asahi-quattro-channel.sig "$channel.sig"
  verify_signature "$channel" "$channel.sig"
  grep -Fxq 'format=1' "$channel" || fail "Unsupported channel pointer format."
  grep -Fxq 'channel=asahi-quattro' "$channel" || fail "Invalid channel pointer."
  channel_sequence=$(read_field sequence "$channel")
  release_tag=$(read_field release_tag "$channel")
  expected_release_sha256=$(read_field release_sha256 "$channel")
  [[ $release_tag =~ ^asahi-quattro-[0-9a-f]{8}$ ]] || fail "The channel contains an invalid release tag."
  [[ $channel_sequence =~ ^[1-9][0-9]*$ ]] || fail "The channel contains an invalid release sequence."
  [[ $expected_release_sha256 =~ ^[0-9a-f]{64}$ ]] || fail "The channel contains an invalid release checksum."
fi

say "Verifying release descriptor $release_tag"
release="$work_dir/asahi-quattro-release"
download_release_asset "$release_tag" asahi-quattro-release "$release"
download_release_asset "$release_tag" asahi-quattro-release.sig "$release.sig"
if [[ -n ${expected_release_sha256:-} ]]; then
  printf '%s  %s\n' "$expected_release_sha256" "$release" | sha256sum --check --status - ||
    fail "Release descriptor checksum verification failed."
fi
verify_signature "$release" "$release.sig"
grep -Fxq 'format=1' "$release" || fail "Unsupported release descriptor format."
grep -Fxq 'bundle=asahi-quattro' "$release" || fail "Invalid release descriptor."
release_sequence=$(read_field sequence "$release")
[[ $release_sequence =~ ^[1-9][0-9]*$ ]] || fail "Invalid release sequence."
[[ -z $channel_sequence || $release_sequence == "$channel_sequence" ]] ||
  fail "Release sequence does not match the signed channel."
grep -Fxq "release_tag=$release_tag" "$release" || fail "Release descriptor tag mismatch."
source_commit=$(read_field source_commit "$release")
package_source_commit=$(read_field package_source_commit "$release")
manifest_sha256=$(read_field manifest_sha256 "$release")
upgrader_sha256=$(read_field upgrader_sha256 "$release")
bundle_updater_sha256=$(read_field bundle_updater_sha256 "$release")
fresh_installer_sha256=$(read_field fresh_installer_sha256 "$release")
[[ $source_commit =~ ^[0-9a-f]{40}$ && $release_tag == "asahi-quattro-${source_commit:0:8}" ]] ||
  fail "Invalid release bundle identity."
[[ $package_source_commit =~ ^[0-9a-f]{40}$ ]] || fail "This release has no verified package source."
[[ $manifest_sha256 =~ ^[0-9a-f]{64}$ && $upgrader_sha256 =~ ^[0-9a-f]{64}$ &&
  $bundle_updater_sha256 =~ ^[0-9a-f]{64}$ ]] || fail "Invalid release asset checksums."

check_checksummed_asset() {
  local name=$1 sha256=$2
  local path="$work_dir/$name"
  download_release_asset "$release_tag" "$name" "$path"
  printf '%s  %s\n' "$sha256" "$path" | sha256sum --check --status - ||
    fail "Checksum verification failed for '$name'."
  printf '%s' "$path"
}

say "Verifying bundle manifest"
manifest_path=$(check_checksummed_asset asahi-quattro-bundle.manifest "$manifest_sha256")
download_release_asset "$release_tag" asahi-quattro-bundle.manifest.sig "$manifest_path.sig"
verify_signature "$manifest_path" "$manifest_path.sig"
grep -Fxq 'format=2' "$manifest_path" || fail "Unsupported bundle manifest format."
grep -Fxq 'bundle=asahi-quattro' "$manifest_path" || fail "Invalid bundle manifest."
grep -Fxq "source_commit=$source_commit" "$manifest_path" || fail "Bundle source identity mismatch."
grep -Fxq 'package_count=6' "$manifest_path" || fail "The release does not contain the complete six-package bundle."

archives=()
package_count=0
while IFS='|' read -r prefix package_name package_version package_arch package_file checksum extra; do
  [[ $prefix == package=* ]] || continue
  sequence=${prefix#package=}
  (( package_count < ${#EXPECTED_PACKAGES[@]} )) || fail "The manifest contains too many packages."
  [[ $sequence == "$((package_count + 1))" && $package_name == "${EXPECTED_PACKAGES[$package_count]}" ]] ||
    fail "The manifest package sequence is invalid."
  [[ -n $package_version && $package_version != *'|'* ]] || fail "The manifest contains an invalid package version."
  [[ $package_arch == "${EXPECTED_ARCHES[$package_count]}" ]] || fail "The manifest contains an invalid package architecture."
  [[ $package_file == "$(basename "$package_file")" && $package_file == "$package_name"-*.pkg.tar.* ]] ||
    fail "The manifest contains an invalid package filename."
  [[ $checksum =~ ^[0-9a-f]{64}$ && -z $extra ]] || fail "The manifest contains an invalid package checksum."

  say "Fetching $package_name ($sequence/${#EXPECTED_PACKAGES[@]})"
  package_path="$bundle_dir/$package_file"
  download_release_asset "$release_tag" "$package_file" "$package_path"
  download_release_asset "$release_tag" "$package_file.sig" "$package_path.sig"
  printf '%s  %s\n' "$checksum" "$package_path" | sha256sum --check --status - ||
    fail "Checksum verification failed for '$package_file'."
  verify_signature "$package_path" "$package_path.sig"
  rm -f "$package_path.sig"
  metadata=$(bsdtar -xOf "$package_path" .PKGINFO 2>/dev/null) ||
    fail "'$package_file' is not a package archive."
  grep -Fxq "pkgname = $package_name" <<<"$metadata" || fail "'$package_file' has the wrong package name."
  grep -Fxq "pkgver = $package_version" <<<"$metadata" || fail "'$package_file' has the wrong package version."
  grep -Fxq "arch = $package_arch" <<<"$metadata" || fail "'$package_file' has the wrong package architecture."
  archives+=("$package_path")
  ((package_count += 1))
done <"$manifest_path"
(( package_count == ${#EXPECTED_PACKAGES[@]} )) ||
  fail "The release does not contain the complete six-package bundle."

settings_source=$(bsdtar -xOf "${archives[1]}" .PKGINFO |
  sed -n 's/^provides = omarchy-quattro-bundle=//p')
runtime_source=$(bsdtar -xOf "${archives[2]}" .PKGINFO |
  sed -n 's/^provides = omarchy-quattro-bundle=//p')
[[ $settings_source == "$source_commit" && $runtime_source == "$source_commit" ]] ||
  fail "Paired packages do not match the source commit."

upgrader_path=$(check_checksummed_asset omarchy-upgrade-to-quattro "$upgrader_sha256")
rm -f "$upgrader_path"
bundle_updater="$work_dir/omarchy-update-asahi-bundle"
download_release_asset "$release_tag" omarchy-update-asahi-bundle "$bundle_updater"
download_release_asset "$release_tag" omarchy-update-asahi-bundle.sig "$bundle_updater.sig"
printf '%s  %s\n' "$bundle_updater_sha256" "$bundle_updater" | sha256sum --check --status - ||
  fail "Bundle updater checksum verification failed."
verify_signature "$bundle_updater" "$bundle_updater.sig"
if [[ -n $fresh_installer_sha256 ]]; then
  fresh_installer="$work_dir/omarchy-install-asahi-fresh"
  download_release_asset "$release_tag" omarchy-install-asahi-fresh "$fresh_installer"
  download_release_asset "$release_tag" omarchy-install-asahi-fresh.sig "$fresh_installer.sig"
  printf '%s  %s\n' "$fresh_installer_sha256" "$fresh_installer" | sha256sum --check --status - ||
    fail "Fresh installer checksum verification failed."
  verify_signature "$fresh_installer" "$fresh_installer.sig"
fi

if (( verify_only )); then
  say "Verified $release_tag ($source_commit) for Apple Silicon."
  exit 0
fi

printf 'Verified %s (%s), %d packages in %s\n' "$release_tag" "$source_commit" "$package_count" "$bundle_dir"
