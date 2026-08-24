#!/bin/bash
# Unit tests for builder/lib/disk-safety.sh.
#
# Runs against loopback image files, so it needs sfdisk but never root or a
# real disk. Skips cleanly (exit 0) where sfdisk is unavailable, e.g. macOS.

set -uo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=builder/lib/disk-safety.sh
source "$repo_root/builder/lib/disk-safety.sh"

if ! command -v sfdisk >/dev/null 2>&1; then
  echo "SKIP: sfdisk is unavailable on this host; run inside the build container."
  exit 0
fi

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-mx-mac-iso-test.XXXXXXXX")
trap 'rm -rf "$work_dir"' EXIT

failures=0

pass() { echo "ok - $1"; }
fail() { echo "not ok - $1" >&2; ((failures += 1)); }

new_image() {
  local image="$work_dir/$1"
  truncate -s 64M "$image"
  sfdisk "$image" <<<"label: gpt" >/dev/null 2>&1
  printf '%s' "$image"
}

write_partition() {
  local image=$1 index=$2 type=$3
  {
    sfdisk -d "$image" | grep -v '^label-id'
    printf '%s%s : start=2048, size=4096, type=%s\n' "$(basename "$image")" "$index" "$type"
  } | sfdisk "$image" >/dev/null 2>&1
}

apfs="7C3457EF-0000-11AA-AA11-00306543ECAC"
iboot="69646961-0000-11AA-AA11-00306543ECAC"
recovery="52637672-0000-11AA-AA11-00306543ECAC"
efi="C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
linux="0FC63DAF-8483-4772-8E79-3D69D8477DE4"

echo "# ds_is_apple_type_guid"

for guid in "$apfs" "$iboot" "$recovery"; do
  if ds_is_apple_type_guid "$guid"; then
    pass "refuses known Apple GUID ${guid:0:8}"
  else
    fail "should refuse $guid"
  fi
done

if ds_is_apple_type_guid "7c3457ef-0000-11aa-aa11-00306543ecac"; then
  pass "matches lowercase GUIDs too"
else
  fail "lowercase GUID not matched"
fi

for guid in "$efi" "$linux"; do
  if ! ds_is_apple_type_guid "$guid"; then
    pass "accepts non-Apple GUID ${guid:0:8}"
  else
    fail "false positive on $guid"
  fi
done

echo "# ds_assert_no_apple_partitions"

image=$(new_image apple.img)
write_partition "$image" 1 "$apfs"
write_partition "$image" 2 "$iboot"
if output=$(ds_assert_no_apple_partitions "$image" 2>&1); then
  fail "Apple-only image must be refused"
else
  if grep -q 'Apple partitions present' <<<"$output"; then
    pass "refusal explains Apple partitions present"
  else
    fail "refusal message unclear: $output"
  fi
fi

image=$(new_image mixed.img)
write_partition "$image" 1 "$efi"
write_partition "$image" 2 "$recovery"
if ds_assert_no_apple_partitions "$image" >/dev/null 2>&1; then
  fail "mixed image with recovery partition must be refused"
else
  pass "mixed image refused"
fi

image=$(new_image clean.img)
write_partition "$image" 1 "$efi"
write_partition "$image" 2 "$linux"
if ds_assert_no_apple_partitions "$image" >/dev/null 2>&1; then
  pass "clean image accepted"
else
  fail "clean image wrongly refused"
fi

echo "# created parts rollback"

image=$(new_image rollback.img)
write_partition "$image" 1 "$efi"
ds_record_created_part "$image" 1
ds_record_created_part "$image" 2
(( ${#ds_created_parts[@]} == 2 )) && pass "two created parts recorded" || fail "record count wrong"
if ds_rollback_created_parts; then
  pass "rollback succeeded"
else
  fail "rollback reported failure"
fi
count=$(sfdisk -d "$image" 2>/dev/null | grep -c ' : ' || true)
(( count == 0 )) && pass "partition table empty after rollback" || fail "table still has $count partitions"
(( ${#ds_created_parts[@]} == 0 )) && pass "registry cleared" || fail "registry not cleared"

echo
if (( failures == 0 )); then
  echo "all gpt-safety tests passed"
  exit 0
fi
echo "$failures gpt-safety test(s) failed" >&2
exit 1
