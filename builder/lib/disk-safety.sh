#
# GPT safety helpers shared by omarchy-mx-mac-iso builders and installers.
#
# This file is sourced, not executed: it intentionally has no shebang.
# Every function fails loudly instead of guessing. Apple partition types are
# refused by GUID suffix, not by enumeration: every Apple Silicon partition
# type carries -11AA-AA11-00306543ECAC.
#

DS_APPLE_GPT_SUFFIX="-11AA-AA11-00306543ECAC"
DS_KNOWN_APPLE_GUIDS=(
  "7C3457EF-0000-11AA-AA11-00306543ECAC" # Apple APFS
  "69646961-0000-11AA-AA11-00306543ECAC" # Apple iBoot/boot product
  "52637672-0000-11AA-AA11-00306543ECAC" # Apple recovery
)

ds_fail() {
  printf 'Error: %s\n' "$*" >&2
  return 1
}

ds_require_sfdisk() {
  command -v sfdisk >/dev/null 2>&1 || ds_fail "sfdisk is unavailable."
}

ds_is_apple_type_guid() {
  local guid="${1,,}"
  [[ $guid == *"$DS_APPLE_GPT_SUFFIX" ]]
}

ds_list_partition_type_guids() {
  local image=$1
  ds_require_sfdisk
  [[ -e $image ]] || ds_fail "No such image or device: '$image'."
  sfdisk -d "$image" 2>/dev/null | sed -n 's/^.*type=\([^,]*\).*$/\1/p'
}

ds_apple_partitions() {
  local image=$1 line name guid found=()
  ds_require_sfdisk
  while IFS= read -r line; do
    name=${line%% :*}
    guid=$(sed -n 's/^.*type=\([^,]*\).*$/\1/p' <<<"$line")
    if ds_is_apple_type_guid "$guid"; then
      found+=("${name##*/}")
    fi
  done < <(sfdisk -d "$image" 2>/dev/null | grep ' : ')
  (( ${#found[@]} )) && printf '%s\n' "${found[@]}"
  return 0
}

ds_assert_no_apple_partitions() {
  local image=$1 offenders=() name
  ds_require_sfdisk
  [[ -e $image ]] || ds_fail "No such image or device: '$image'."
  while IFS= read -r name; do
    offenders+=("$name")
  done < <(ds_apple_partitions "$image")
  if (( ${#offenders[@]} )); then
    ds_fail "Refusing to touch '${image}': Apple partitions present (${offenders[*]}). APFS, iBoot, and recovery partitions must never be resized or written."
  fi
}

ds_dump_gpt() {
  local image=$1 backup=$2
  ds_require_sfdisk
  sfdisk --dump "$image" >"$backup" || ds_fail "Could not back up the partition table of '${image}'."
}

ds_created_parts=()

ds_record_created_part() {
  ds_created_parts+=("$1:$2")
}

ds_rollback_created_parts() {
  local entry image index status=0
  for entry in "${ds_created_parts[@]}"; do
    image=${entry%:*}
    index=${entry#*:}
    if ! sfdisk --delete "$image" "$index" >/dev/null 2>&1; then
      printf 'Error: rollback failed for partition %s on %s.\n' "$index" "$image" >&2
      status=1
    fi
  done
  ds_created_parts=()
  return $status
}
