#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -r "$SCRIPT_DIR/lib/target-fingerprint.sh" ]]; then
	# shellcheck source=lib/target-fingerprint.sh
	source "$SCRIPT_DIR/lib/target-fingerprint.sh"
elif [[ -r "$SCRIPT_DIR/target-fingerprint.sh" ]]; then
	# Installed bundle layout.
	# shellcheck source=lib/target-fingerprint.sh
	source "$SCRIPT_DIR/target-fingerprint.sh"
else
	printf 'error: target fingerprint helper is missing\n' >&2
	exit 1
fi

if [[ -r "$SCRIPT_DIR/lib/kernel-capabilities.sh" ]]; then
	# shellcheck source=lib/kernel-capabilities.sh
	source "$SCRIPT_DIR/lib/kernel-capabilities.sh"
	# shellcheck source=lib/bundle-compatibility.sh
	source "$SCRIPT_DIR/lib/bundle-compatibility.sh"
elif [[ -r "$SCRIPT_DIR/kernel-capabilities.sh" ]]; then
	# Installed bundle layout.
	# shellcheck source=lib/kernel-capabilities.sh
	source "$SCRIPT_DIR/kernel-capabilities.sh"
	# shellcheck source=lib/bundle-compatibility.sh
	source "$SCRIPT_DIR/bundle-compatibility.sh"
else
	printf 'error: kernel capability helper is missing\n' >&2
	exit 1
fi

BUNDLE_ROOT="${1:-}"
ALLOW_MISMATCH=false
PRINT_STATE=false
shift || true
while (($#)); do
	case "$1" in
	--allow-target-mismatch) ALLOW_MISMATCH=true ;;
	--compatibility-state) PRINT_STATE=true ;;
	*)
		printf 'usage: %s BUNDLE_DIRECTORY [--allow-target-mismatch] [--compatibility-state]\n' "$0" >&2
		exit 1
		;;
	esac
	shift
done

EXPECTED="$BUNDLE_ROOT/target-fingerprint.env"
[[ -r "$EXPECTED" ]] || {
	printf 'error: bundle target fingerprint is missing: %s\n' "$EXPECTED" >&2
	exit 1
}

CURRENT="$(mktemp)"
cleanup() {
	rm -f -- "$CURRENT"
}
trap cleanup EXIT
collect_target_fingerprint "$CURRENT"

expected_version="$(fingerprint_value "$EXPECTED" STEAMOS_VERSION_ID)"
expected_build="$(fingerprint_value "$EXPECTED" STEAMOS_BUILD_ID)"
expected_abi="$(fingerprint_value "$EXPECTED" ABI_SHA256)"
current_version="$(fingerprint_value "$CURRENT" STEAMOS_VERSION_ID)"
current_build="$(fingerprint_value "$CURRENT" STEAMOS_BUILD_ID)"
current_abi="$(fingerprint_value "$CURRENT" ABI_SHA256)"
compatibility="$(bundle_compatibility "$EXPECTED" "$CURRENT")"

if [[ "$PRINT_STATE" == true ]]; then
	printf '%s\n' "$compatibility"
	[[ "$compatibility" != incompatible || "$ALLOW_MISMATCH" == true ]]
	exit
fi

mismatches=()
[[ "$expected_version" == "$current_version" ]] ||
	mismatches+=("SteamOS version: built for $expected_version, running $current_version")
[[ "$expected_build" == "$current_build" ]] ||
	mismatches+=("SteamOS build: built for $expected_build, running $current_build")
[[ "$expected_abi" == "$current_abi" ]] ||
	mismatches+=("userspace ABI fingerprint: built for $expected_abi, running $current_abi")

if [[ "$compatibility" == exact ]]; then
	printf 'Exact bundle match: SteamOS %s build %s (ABI %s).\n' \
		"$current_version" "$current_build" "${current_abi:0:12}"
elif [[ "$compatibility" == abi-compatible ]]; then
	printf 'ABI-compatible bundle match.\n'
	printf 'Using ABI-compatible bundle built for a different SteamOS release.\n'
	printf 'Userspace ABI and Binder compatibility requirements are satisfied.\n'
elif ((${#mismatches[@]} > 0)); then
	printf 'Incompatible bundle:\n' >&2
	printf '  %s\n' "${mismatches[@]}" >&2
	if [[ "$ALLOW_MISMATCH" != true ]]; then
		printf 'Rebuild for this SteamOS target, or explicitly use --allow-target-mismatch for testing.\n' >&2
		exit 1
	fi
	printf 'WARNING: continuing with an explicitly allowed target mismatch.\n' >&2
else
	printf 'Incompatible bundle: target metadata is incomplete.\n' >&2
	exit 1
fi
