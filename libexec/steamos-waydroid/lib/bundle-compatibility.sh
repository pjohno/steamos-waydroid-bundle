#!/usr/bin/env bash

# Classify a bundle fingerprint against a current host fingerprint. The state
# is printed as one of: exact, abi-compatible, incompatible.

bundle_compatibility() {
	local bundle_fingerprint="$1"
	local current_fingerprint="$2"
	local expected_version expected_build expected_kernel expected_abi
	local current_version current_build current_kernel current_abi

	expected_version="$(fingerprint_value "$bundle_fingerprint" STEAMOS_VERSION_ID)"
	expected_build="$(fingerprint_value "$bundle_fingerprint" STEAMOS_BUILD_ID)"
	expected_kernel="$(fingerprint_value "$bundle_fingerprint" KERNEL_RELEASE)"
	expected_abi="$(fingerprint_value "$bundle_fingerprint" ABI_SHA256)"
	current_version="$(fingerprint_value "$current_fingerprint" STEAMOS_VERSION_ID)"
	current_build="$(fingerprint_value "$current_fingerprint" STEAMOS_BUILD_ID)"
	current_kernel="$(fingerprint_value "$current_fingerprint" KERNEL_RELEASE)"
	current_abi="$(fingerprint_value "$current_fingerprint" ABI_SHA256)"

	if [[ -n "$expected_abi" && "$expected_version" == "$current_version" ]] &&
		[[ "$expected_build" == "$current_build" ]] &&
		[[ "$expected_abi" == "$current_abi" ]]; then
		printf 'exact\n'
	elif [[ -n "$expected_abi" && "$expected_abi" == "$current_abi" ]] &&
		{
			running_kernel_has_builtin_binder ||
				[[ -n "$expected_kernel" && "$expected_kernel" == "$current_kernel" ]]
		}; then
		printf 'abi-compatible\n'
	else
		printf 'incompatible\n'
	fi
}
