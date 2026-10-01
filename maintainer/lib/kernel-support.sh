#!/usr/bin/env bash

# Shared helpers for inspecting the captured SteamOS target kernel.
#
# This library is intentionally read-only:
#   - it does not install kernel headers;
#   - it does not build Binder;
#   - it does not modify the copied SteamOS rootfs.
#
# Callers use the returned information to decide whether matching kernel
# headers need to be installed and whether a Binder package needs to be built.
#
# IMPORTANT:
# Maintainer build steps run inside a copied SteamOS rootfs while sharing the
# build host's running kernel. Therefore `uname -r` describes the build host,
# not the captured SteamOS target, and must not be used here.

KERNEL_SUPPORT_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=common.sh
if ! declare -F die >/dev/null 2>&1; then
	source "$KERNEL_SUPPORT_LIB_DIR/common.sh"
fi

# shellcheck source=../../libexec/steamos-waydroid/lib/target-fingerprint.sh
if ! declare -F fingerprint_value >/dev/null 2>&1; then
	source "$REPO_ROOT/libexec/steamos-waydroid/lib/target-fingerprint.sh"
fi

target_kernel_release() {
	local kernel_release

	[[ -r "$TARGET_FINGERPRINT_FILE" ]] || die "target fingerprint is missing: $TARGET_FINGERPRINT_FILE"

	kernel_release="$(
		fingerprint_value "$TARGET_FINGERPRINT_FILE" KERNEL_RELEASE
	)"

	[[ -n "$kernel_release" ]] || die "target fingerprint does not contain KERNEL_RELEASE"

	[[ "$kernel_release" != missing && "$kernel_release" != unknown ]] || die "target fingerprint contains an unusable KERNEL_RELEASE: $kernel_release"

	printf '%s\n' "$kernel_release"
}

target_kernel_modules_dir() {
	local kernel_release
	kernel_release="${1:-$(target_kernel_release)}"
	printf '/usr/lib/modules/%s\n' "$kernel_release"
}

require_target_kernel_modules_dir() {
	local kernel_release modules_dir
	kernel_release="${1:-$(target_kernel_release)}"
	modules_dir="$(target_kernel_modules_dir "$kernel_release")"

	[[ -d "$modules_dir" ]] || die "target kernel modules directory is missing: $modules_dir"

	printf '%s\n' "$modules_dir"
}

target_binder_state() {
	local kernel_release modules_dir

	kernel_release="${1:-$(target_kernel_release)}"
	modules_dir="$(require_target_kernel_modules_dir "$kernel_release")"

	if [[ -r "$modules_dir/modules.builtin" ]] &&
		grep -Eq '(^|/)(binder|binder_linux)\.ko$' \
			"$modules_dir/modules.builtin"; then
		printf 'builtin\n'
		return 0
	fi

	if find "$modules_dir" -type f \
		\( \
		-name 'binder.ko' \
		-o -name 'binder.ko.xz' \
		-o -name 'binder.ko.zst' \
		-o -name 'binder.ko.gz' \
		-o -name 'binder_linux.ko' \
		-o -name 'binder_linux.ko.xz' \
		-o -name 'binder_linux.ko.zst' \
		-o -name 'binder_linux.ko.gz' \
		\) \
		-print -quit |
		grep -q .; then
		printf 'module\n'
		return 0
	fi

	printf 'missing\n'
}

target_kernel_package() {
	local kernel_release modules_dir candidate package_name
	kernel_release="${1:-$(target_kernel_release)}"
	modules_dir="$(require_target_kernel_modules_dir "$kernel_release")"

	for candidate in "$modules_dir/modules.builtin" "$modules_dir/modules.order" "$modules_dir/pkgbase"; do
		[[ -e "$candidate" ]] || continue

		package_name="$(pacman -Qqo "$candidate" 2>/dev/null | head -n1 || true)"
		if [[ -n "$package_name" ]]; then
			printf '%s\n' "$package_name"
			return 0
		fi
	done

	while IFS= read -r candidate; do
		package_name="$(pacman -Qqo "$candidate" 2>/dev/null | head -n1 || true)"
		if [[ "$package_name" == linux-neptune-* ]]; then
			printf '%s\n' "$package_name"
			return 0
		fi
	done < <(find "$modules_dir" -type f -print 2>/dev/null)

	die "could not identify the installed package for target kernel $kernel_release"
}

target_kernel_headers_package() {
	local kernel_package
	kernel_package="${1:-$(target_kernel_package)}"
	printf '%s-headers\n' "$kernel_package"
}

target_kernel_package_version() {
	local kernel_package package_version
	kernel_package="${1:-$(target_kernel_package)}"

	package_version="$(
		pacman -Q "$kernel_package" 2>/dev/null |
			awk '{print $2; exit}' || true
	)"

	[[ -n "$package_version" ]] || die "could not determine installed version of $kernel_package"

	printf '%s\n' "$package_version"
}

target_kernel_headers_repository_version() {
	local headers_package repository_version
	headers_package="${1:-$(target_kernel_headers_package)}"

	repository_version="$(
		LC_ALL=C pacman -Si "$headers_package" 2>/dev/null |
			awk '
                /^Version[[:space:]]*:/ {
                    sub(/^[^:]*:[[:space:]]*/, "")
                    print
                    exit
                }
            ' || true
	)"

	[[ -n "$repository_version" ]] || die "target kernel headers package is unavailable: $headers_package"

	printf '%s\n' "$repository_version"
}

require_matching_target_kernel_headers() {
	local kernel_package headers_package
	local kernel_version headers_version

	kernel_package="$(target_kernel_package)"
	headers_package="$(target_kernel_headers_package "$kernel_package")"

	kernel_version="$(target_kernel_package_version "$kernel_package")"
	headers_version="$(
		target_kernel_headers_repository_version "$headers_package"
	)"

	[[ "$headers_version" == "$kernel_version" ]] || die "target kernel/header mismatch: $kernel_package=$kernel_version, $headers_package=$headers_version"

	printf '%s\n' "$headers_package"
}

require_target_kernel_build_tree() {
	local kernel_release build_dir
	kernel_release="${1:-$(target_kernel_release)}"
	build_dir="/usr/lib/modules/$kernel_release/build"

	[[ -d "$build_dir" ]] || die "target kernel build tree is missing: $build_dir"

	[[ -r "$build_dir/Makefile" ]] || die "target kernel build tree has no readable Makefile: $build_dir/Makefile"

	printf '%s\n' "$build_dir"
}

print_target_kernel_support() {
	local kernel_release kernel_package binder_state

	kernel_release="$(target_kernel_release)"
	kernel_package="$(target_kernel_package "$kernel_release")"
	binder_state="$(target_binder_state "$kernel_release")"

	printf 'Target kernel release: %s\n' "$kernel_release"
	printf 'Target kernel package: %s\n' "$kernel_package"
	printf 'Target Binder support: %s\n' "$binder_state"
}

target_valve_kernel_source_id() {
	local kernel_release tag commit

	kernel_release="${1:-$(target_kernel_release)}"

	if [[ "$kernel_release" =~ ^(.+-valve[0-9]+)-[0-9]+-neptune-[^-]+-g([0-9a-fA-F]+)$ ]]; then
		tag="${BASH_REMATCH[1]}"
		commit="${BASH_REMATCH[2]}"
	else
		die "cannot derive Valve kernel source from release: $kernel_release"
	fi

	printf '%s %s\n' "$tag" "$commit"
}
