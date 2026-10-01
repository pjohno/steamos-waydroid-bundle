#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

source "$REPO_ROOT/libexec/steamos-waydroid/lib/target-fingerprint.sh"
# shellcheck source=lib/kernel-support.sh"
source "$SCRIPT_DIR/lib/kernel-support.sh"

if [[ -n ${HOST_PACKAGE_LOG:-} ]]; then
	mkdir -p "$(dirname -- "$HOST_PACKAGE_LOG")"
	exec > >(tee -a "$HOST_PACKAGE_LOG") 2>&1
fi

require_copied_build_root

for command_name in bsdtar cython getent grep groupadd make makepkg modinfo pacman patch pkg-config python readelf setpriv tee useradd; do
	require_command "$command_name"
done

[[ -n ${HOST_UID:-} && -n ${HOST_GID:-} ]] ||
	die "HOST_UID and HOST_GID were not passed by enter-build-rootfs.sh"
[[ ${BUNDLE_VERSION:-} =~ ^[A-Za-z0-9._-]+$ ]] ||
	die "unsafe or missing BUNDLE_VERSION"

BUILDER_USER="$(getent passwd "$HOST_UID" 2>/dev/null | cut -d: -f1 || true)"
if [[ -z "$BUILDER_USER" ]]; then
	BUILDER_USER=steamos-waydroid-build
	if getent passwd "$BUILDER_USER" >/dev/null; then
		die "$BUILDER_USER exists with an unexpected UID"
	fi

	BUILDER_GROUP="$(getent group "$HOST_GID" 2>/dev/null | cut -d: -f1 || true)"
	if [[ -z "$BUILDER_GROUP" ]]; then
		BUILDER_GROUP=steamos-waydroid-build
		groupadd --gid "$HOST_GID" "$BUILDER_GROUP"
	fi

	useradd --uid "$HOST_UID" --gid "$BUILDER_GROUP" --no-create-home \
		--home-dir /work/src --shell /usr/bin/nologin "$BUILDER_USER"
fi

[[ "$BUILDER_USER" != root ]] || die "host UID must not resolve to root"

python -c 'import Cython, setuptools' ||
	die "Cython and setuptools must be installed in the copied rootfs"

python_header="$(python -c 'import sysconfig; print(sysconfig.get_config_var("INCLUDEPY"))')/Python.h"
[[ -r "$python_header" ]] || die "target Python header is missing: $python_header"

PACKAGE_RECIPE_ROOT="$SCRIPT_DIR/packages"
SOURCE_CACHE="${SOURCE_ROOT:-/work/src}/host-package-sources"
PACKAGE_WORK_ROOT="${SOURCE_ROOT:-/work/src}/host-package-work/$BUNDLE_VERSION"
PACKAGE_OUTPUT_ROOT="${PACKAGE_OUTPUT_ROOT:-/work/out/.host-packages-$BUNDLE_VERSION}"

# Waydroid stack lock.
WAYDROID_STACK_LOCK="${WAYDROID_STACK_LOCK:-maintainer/packages/locks/waydroid-stack-1.5.4.lock}"
if [[ "$WAYDROID_STACK_LOCK" = /* ]]; then
	WAYDROID_STACK_LOCK_PATH="$WAYDROID_STACK_LOCK"
else
	WAYDROID_STACK_LOCK_PATH="$REPO_ROOT/$WAYDROID_STACK_LOCK"
fi

[[ -r "$WAYDROID_STACK_LOCK_PATH" ]] ||
	die "Waydroid stack lock is missing: $WAYDROID_STACK_LOCK_PATH"

# shellcheck disable=SC1090
source "$WAYDROID_STACK_LOCK_PATH"

[[ "${format:-}" == "1" ]] ||
	die "unsupported Waydroid stack lock format: ${format:-missing}"

for required_var in \
	libglibutil_version libglibutil_pkgrel libglibutil_commit libglibutil_sha256 \
	libgbinder_version libgbinder_pkgrel libgbinder_commit libgbinder_sha256 \
	python_gbinder_version python_gbinder_pkgrel python_gbinder_commit python_gbinder_sha256 \
	waydroid_version waydroid_pkgrel waydroid_commit waydroid_sha256; do
	[[ -n "${!required_var:-}" ]] ||
		die "Waydroid stack lock is missing $required_var"
done

for pkgrel_var in libglibutil_pkgrel libgbinder_pkgrel python_gbinder_pkgrel waydroid_pkgrel; do
	[[ "${!pkgrel_var}" =~ ^[1-9][0-9]*$ ]] ||
		die "invalid $pkgrel_var in Waydroid stack lock: ${!pkgrel_var}"
done

if [[ -n "${libgbinder_patch:-}" ]]; then
	[[ -n "${libgbinder_patch_sha256:-}" ]] ||
		die "Waydroid stack selects libgbinder patch '$libgbinder_patch' but has no libgbinder_patch_sha256"
	[[ -r "$PACKAGE_RECIPE_ROOT/libgbinder/$libgbinder_patch" ]] ||
		die "selected libgbinder patch is missing: $PACKAGE_RECIPE_ROOT/libgbinder/$libgbinder_patch"
elif [[ -n "${libgbinder_patch_sha256:-}" ]]; then
	die "Waydroid stack defines libgbinder_patch_sha256 without libgbinder_patch"
fi

# Values below are supplied by the validated Waydroid stack lock.
# shellcheck disable=SC2154
{
	printf 'Using Waydroid stack lock:\n  %s\n' "$WAYDROID_STACK_LOCK_PATH"
	printf '  Waydroid:       %s-%s\n' "$waydroid_version" "$waydroid_pkgrel"
	printf '  libglibutil:    %s-%s\n' "$libglibutil_version" "$libglibutil_pkgrel"
	printf '  libgbinder:     %s-%s\n' "$libgbinder_version" "$libgbinder_pkgrel"
	printf '  python-gbinder: %s-%s\n' "$python_gbinder_version" "$python_gbinder_pkgrel"
}

# Target kernel / Binder state.
kernel_release="$(target_kernel_release)"
binder_state="$(target_binder_state "$kernel_release")"

printf '\nTarget kernel support:\n'
printf '  Kernel release: %s\n' "$kernel_release"
printf '  Binder support: %s\n' "$binder_state"

binder_implementation=""
binder_repository=""
binder_valve_tag=""
binder_valve_short_commit=""
binder_commit=""
binder_sha256=""
binder_pkgrel=""
binder_patch=""
binder_patch_sha256=""

if [[ "$binder_state" == "missing" ]]; then
	require_target_kernel_build_tree "$kernel_release" >/dev/null

	BINDER_SOURCE_LOCK="${BINDER_SOURCE_LOCK:-maintainer/packages/locks/binder-v1.lock}"
	if [[ "$BINDER_SOURCE_LOCK" = /* ]]; then
		BINDER_SOURCE_LOCK_PATH="$BINDER_SOURCE_LOCK"
	else
		BINDER_SOURCE_LOCK_PATH="$REPO_ROOT/$BINDER_SOURCE_LOCK"
	fi

	[[ -r "$BINDER_SOURCE_LOCK_PATH" ]] ||
		die "Binder source lock is missing: $BINDER_SOURCE_LOCK_PATH"

	unset format

	# BINDER_SOURCE_LOCK_PATH is validated before sourcing.
	# shellcheck disable=SC1090
	source "$BINDER_SOURCE_LOCK_PATH"

	case "${format:-}" in
		1)
			binder_implementation="choff"
			for required_var in binder_repository binder_commit binder_sha256 binder_pkgrel; do
				[[ -n "${!required_var:-}" ]] ||
					die "Binder source lock is missing $required_var"
			done
			;;
		2)
			[[ "${binder_implementation:-}" == "valve" ]] ||
				die "unsupported Binder implementation in format 2 lock: ${binder_implementation:-missing}"
			for required_var in binder_repository binder_pkgrel; do
				[[ -n "${!required_var:-}" ]] ||
					die "Binder source lock is missing $required_var"
			done
			;;
		*)
			die "unsupported Binder source lock format: ${format:-missing}"
			;;
	esac

	[[ "$binder_pkgrel" =~ ^[1-9][0-9]*$ ]] ||
		die "invalid binder_pkgrel in Binder source lock: $binder_pkgrel"
	[[ "$binder_repository" =~ ^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+(\.git)?$ ]] ||
		die "Binder repository must be an HTTPS GitHub repository: $binder_repository"

	if [[ "$binder_implementation" == "valve" ]]; then
		binder_valve_source_id="$(
			target_valve_kernel_source_id "$kernel_release"
		)"
		binder_valve_tag="${binder_valve_source_id%% *}"
		binder_valve_short_commit="${binder_valve_source_id##* }"

		binder_commit="$(
			git ls-remote "$binder_repository" "refs/tags/${binder_valve_tag}^{}" |
				awk 'NR == 1 { print $1 }'
		)"

		if [[ -z "$binder_commit" ]]; then
			binder_commit="$(
				git ls-remote "$binder_repository" "refs/tags/${binder_valve_tag}" |
					awk 'NR == 1 { print $1 }'
			)"
		fi

		[[ "$binder_commit" =~ ^[0-9a-fA-F]{40}$ ]] ||
			die "could not resolve Valve kernel tag $binder_valve_tag"

		[[ "$binder_commit" == "$binder_valve_short_commit"* ]] ||
			die "Valve tag $binder_valve_tag resolves to $binder_commit, expected commit prefix $binder_valve_short_commit"
	fi

	if [[ "$binder_implementation" == "choff" ]]; then
		[[ "$binder_commit" =~ ^[0-9a-fA-F]{40}$ ]] ||
			die "invalid binder_commit in Binder source lock: $binder_commit"
		[[ "$binder_sha256" =~ ^[0-9a-fA-F]{64}$ ]] ||
			die "invalid binder_sha256 in Binder source lock"
	fi

	if [[ -n "${binder_patch:-}" ]]; then
		[[ "$binder_patch" =~ ^[A-Za-z0-9._+-]+$ ]] ||
			die "unsafe Binder patch filename: $binder_patch"
		[[ -n "${binder_patch_sha256:-}" ]] ||
			die "Binder lock selects patch '$binder_patch' but has no binder_patch_sha256"
		[[ "$binder_patch_sha256" =~ ^[0-9a-fA-F]{64}$ ]] ||
			die "invalid binder_patch_sha256 in Binder source lock"
		[[ -r "$PACKAGE_RECIPE_ROOT/steamos-waydroid-binder/$binder_patch" ]] ||
			die "selected Binder patch is missing: $PACKAGE_RECIPE_ROOT/steamos-waydroid-binder/$binder_patch"
	elif [[ -n "${binder_patch_sha256:-}" ]]; then
		die "Binder lock defines binder_patch_sha256 without binder_patch"
	fi

	printf 'Using Binder source lock:\n  %s\n' "$BINDER_SOURCE_LOCK_PATH"
	printf '  Implementation: %s\n' "$binder_implementation"
	if [[ "$binder_implementation" == "choff" ]]; then
		printf '  Commit: %s\n' "$binder_commit"
	else
		printf '  Valve tag: %s\n' "$binder_valve_tag"
		printf '  Commit:    %s\n' "$binder_commit"
	fi
	printf '  pkgrel: %s\n' "$binder_pkgrel"
	printf '  Patch:  %s\n' "${binder_patch:-none}"
fi

rm -rf -- "$PACKAGE_WORK_ROOT" "$PACKAGE_OUTPUT_ROOT"
install -d -o "$HOST_UID" -g "$HOST_GID" \
	"$SOURCE_CACHE" "$PACKAGE_WORK_ROOT" "$PACKAGE_OUTPUT_ROOT"

build_package() {
	local package_name="$1"
	local recipe_source="$PACKAGE_RECIPE_ROOT/$package_name"
	local package_work="$PACKAGE_WORK_ROOT/$package_name"

	[[ -r "$recipe_source/PKGBUILD" ]] ||
		die "missing PKGBUILD for $package_name"

	install -d -o "$HOST_UID" -g "$HOST_GID" "$package_work"
	cp -a "$recipe_source"/. "$package_work"/
	chown -R "$HOST_UID:$HOST_GID" "$package_work"

	printf 'Building host package %s...\n' "$package_name"

	(
		cd "$package_work"
		# SHA values are populated by the validated, dynamically selected stack
		# lock sourced above; ShellCheck cannot infer those assignments.
		# shellcheck disable=SC2154
		setpriv --reuid="$HOST_UID" --regid="$HOST_GID" --clear-groups \
			env \
			HOME="$PACKAGE_WORK_ROOT" \
			USER="$BUILDER_USER" \
			LOGNAME="$BUILDER_USER" \
			SRCDEST="$SOURCE_CACHE" \
			PKGDEST="$PACKAGE_OUTPUT_ROOT" \
			BUILDDIR="$package_work/build" \
			WAYDROID_LIBGLIBUTIL_VERSION="$libglibutil_version" \
			WAYDROID_LIBGLIBUTIL_PKGREL="$libglibutil_pkgrel" \
			WAYDROID_LIBGLIBUTIL_SHA256="$libglibutil_sha256" \
			WAYDROID_LIBGBINDER_VERSION="$libgbinder_version" \
			WAYDROID_LIBGBINDER_PKGREL="$libgbinder_pkgrel" \
			WAYDROID_LIBGBINDER_SHA256="$libgbinder_sha256" \
			WAYDROID_LIBGBINDER_PATCH="${libgbinder_patch:-}" \
			WAYDROID_LIBGBINDER_PATCH_SHA256="${libgbinder_patch_sha256:-}" \
			WAYDROID_PYTHON_GBINDER_VERSION="$python_gbinder_version" \
			WAYDROID_PYTHON_GBINDER_PKGREL="$python_gbinder_pkgrel" \
			WAYDROID_PYTHON_GBINDER_SHA256="$python_gbinder_sha256" \
			WAYDROID_VERSION="$waydroid_version" \
			WAYDROID_PKGREL="$waydroid_pkgrel" \
			WAYDROID_SHA256="$waydroid_sha256" \
			STEAMOS_KERNEL_RELEASE="$kernel_release" \
			STEAMOS_BINDER_IMPLEMENTATION="${binder_implementation:-}" \
			STEAMOS_BINDER_REPOSITORY="${binder_repository:-}" \
			STEAMOS_BINDER_VALVE_TAG="${binder_valve_tag:-}" \
			STEAMOS_BINDER_COMMIT="${binder_commit:-}" \
			STEAMOS_BINDER_SHA256="${binder_sha256:-}" \
			STEAMOS_BINDER_PKGREL="${binder_pkgrel:-}" \
			STEAMOS_BINDER_PATCH="${binder_patch:-}" \
			STEAMOS_BINDER_PATCH_SHA256="${binder_patch_sha256:-}" \
			makepkg --cleanbuild --clean --force --nodeps --noconfirm
	)
}

install_built_package() {
	local package_name="$1"
	local matches=("$PACKAGE_OUTPUT_ROOT/$package_name-"*.pkg.tar.zst)

	((${#matches[@]} == 1)) && [[ -f "${matches[0]}" ]] ||
		die "expected exactly one built package for $package_name"

	pacman -U --noconfirm "${matches[0]}"
}

expected_package_version() {
	local package_name="$1"
	case "$package_name" in
	libglibutil) printf '%s-%s\n' "$libglibutil_version" "$libglibutil_pkgrel" ;;
	libgbinder) printf '%s-%s\n' "$libgbinder_version" "$libgbinder_pkgrel" ;;
	python-gbinder) printf '%s-%s\n' "$python_gbinder_version" "$python_gbinder_pkgrel" ;;
	waydroid) printf '%s-%s\n' "$waydroid_version" "$waydroid_pkgrel" ;;
	steamos-waydroid-binder) printf '1-%s\n' "$binder_pkgrel" ;;
	*) die "no expected package version mapping for $package_name" ;;
	esac
}

verify_built_package_metadata() {
	local package_name="$1"
	local package_matches=("$PACKAGE_OUTPUT_ROOT/$package_name-"*.pkg.tar.zst)
	local metadata_name metadata_version expected_version

	((${#package_matches[@]} == 1)) && [[ -f "${package_matches[0]}" ]] ||
		die "host package set is incomplete for $package_name"

	metadata_name="$(bsdtar -xOf "${package_matches[0]}" .PKGINFO |
		awk -F' = ' '$1 == "pkgname" {print $2; exit}')"
	[[ "$metadata_name" == "$package_name" ]] ||
		die "package metadata mismatch for $package_name"

	metadata_version="$(bsdtar -xOf "${package_matches[0]}" .PKGINFO |
		awk -F' = ' '$1 == "pkgver" {print $2; exit}')"
	expected_version="$(expected_package_version "$package_name")"

	[[ "$metadata_version" == "$expected_version" ]] ||
		die "package version mismatch for $package_name: expected $expected_version, got $metadata_version"
}

verify_binder_package() {
	local binder_packages=("$PACKAGE_OUTPUT_ROOT"/steamos-waydroid-binder-*.pkg.tar.zst)
	local binder_module_path verify_dir binder_vermagic

	((${#binder_packages[@]} == 1)) && [[ -f "${binder_packages[0]}" ]] ||
		die "expected exactly one Binder package"

	binder_module_path="$(bsdtar -tf "${binder_packages[0]}" |
		grep -F "usr/lib/modules/$kernel_release/updates/steamos-waydroid/binder_linux.ko" |
		head -n1 || true)"

	[[ -n "$binder_module_path" ]] ||
		die "Binder package does not contain binder_linux.ko for target kernel $kernel_release"

	verify_dir="$(mktemp -d)"
	bsdtar -xf "${binder_packages[0]}" -C "$verify_dir" "$binder_module_path"

	binder_vermagic="$(modinfo -F vermagic "$verify_dir/$binder_module_path" 2>/dev/null || true)"
	rm -rf -- "$verify_dir"

	[[ -n "$binder_vermagic" ]] ||
		die "could not read Binder module vermagic"
	[[ "$binder_vermagic" == "$kernel_release "* ]] ||
		die "Binder module vermagic does not match target kernel: expected '$kernel_release ...', got '$binder_vermagic'"

	printf 'Verified Binder module:\n'
	printf '  Module:   %s\n' "$binder_module_path"
	printf '  Vermagic: %s\n' "$binder_vermagic"
}

build_package libglibutil
install_built_package libglibutil
pkg-config --exists libglibutil || die "built libglibutil development metadata is unusable"

build_package libgbinder
install_built_package libgbinder
pkg-config --exists libgbinder || die "built libgbinder development metadata is unusable"

build_package python-gbinder
install_built_package python-gbinder
python -c 'import gbinder' || die "built python-gbinder cannot be imported"

build_package waydroid

if [[ "$binder_state" == "missing" ]]; then
	build_package steamos-waydroid-binder
fi

for package_name in libglibutil libgbinder python-gbinder waydroid; do
	verify_built_package_metadata "$package_name"
done

if [[ "$binder_state" == "missing" ]]; then
	verify_built_package_metadata steamos-waydroid-binder
	verify_binder_package
fi

waydroid_package=("$PACKAGE_OUTPUT_ROOT/waydroid-"*.pkg.tar.zst)
for required_path in \
	usr/bin/waydroid \
	usr/lib/systemd/system/waydroid-container.service \
	usr/share/dbus-1/system.d/id.waydro.Container.conf \
	usr/share/polkit-1/actions/id.waydro.Container.policy; do
	bsdtar -tf "${waydroid_package[0]}" | grep -Fx "$required_path" >/dev/null ||
		die "Waydroid package is missing $required_path"
done

libgbinder_package=("$PACKAGE_OUTPUT_ROOT/libgbinder-"*.pkg.tar.zst)
libgbinder_library="$(bsdtar -tf "${libgbinder_package[0]}" |
	awk '/^usr\/lib\/libgbinder\.so\.1\.[0-9]+\.[0-9]+$/ {print; exit}')"
[[ -n "$libgbinder_library" ]] || die "libgbinder package has no versioned shared library"

python_package=("$PACKAGE_OUTPUT_ROOT/python-gbinder-"*.pkg.tar.zst)
packaged_python_version="$(bsdtar -tf "${python_package[0]}" |
	awk -F/ '$2 == "lib" && $3 ~ /^python[0-9]+\.[0-9]+$/ {sub(/^python/, "", $3); print $3; exit}')"
host_python_version="$(python -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
[[ "$packaged_python_version" == "$host_python_version" ]] ||
	die "python-gbinder targets Python $packaged_python_version, not $host_python_version"

install -m 0644 "$WAYDROID_STACK_LOCK_PATH" "$PACKAGE_OUTPUT_ROOT/waydroid-stack.lock"
if [[ "$binder_state" == "missing" ]]; then
	install -m 0644 "$BINDER_SOURCE_LOCK_PATH" "$PACKAGE_OUTPUT_ROOT/binder-source.lock"
fi

chown -R "$HOST_UID:$HOST_GID" "$PACKAGE_OUTPUT_ROOT"

printf '\nVerified host packages created at:\n  %s\n' "$PACKAGE_OUTPUT_ROOT"
