#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PKGBUILD="$REPO_ROOT/maintainer/packages/steamos-waydroid-binder/PKGBUILD"

recipe_values="$({
	STEAMOS_BINDER_REPOSITORY=https://github.com/example/anbox-modules.git
	STEAMOS_BINDER_COMMIT=0123456789abcdef0123456789abcdef01234567
	STEAMOS_BINDER_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
	STEAMOS_BINDER_PKGREL=7
	STEAMOS_BINDER_IMPLEMENTATION=choff
	STEAMOS_BINDER_PATCH=binder-compat.patch
	STEAMOS_BINDER_PATCH_SHA256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
	STEAMOS_KERNEL_RELEASE=6.1.2-test
	export STEAMOS_BINDER_REPOSITORY STEAMOS_BINDER_COMMIT STEAMOS_BINDER_SHA256
	export STEAMOS_BINDER_PKGREL STEAMOS_BINDER_PATCH STEAMOS_BINDER_PATCH_SHA256
	export STEAMOS_KERNEL_RELEASE
	export STEAMOS_BINDER_IMPLEMENTATION
	# PKGBUILD is data-driven by the validated Binder lock environment.
	# shellcheck source=/dev/null
	source "$PKGBUILD"
	# Values below are assigned by the sourced PKGBUILD.
	# shellcheck disable=SC2154
	printf '%s\n' \
		"$pkgrel" \
		"$url" \
		"${source[0]}" \
		"${sha256sums[0]}" \
		"${source[1]}" \
		"${sha256sums[1]}"
	declare -f prepare
})"

grep -Fxq -- '7' <<<"$recipe_values"
grep -Fxq -- 'https://github.com/example/anbox-modules.git' <<<"$recipe_values"
grep -Fxq -- \
	'anbox-modules-0123456789abcdef0123456789abcdef01234567.tar.gz::https://github.com/example/anbox-modules/archive/0123456789abcdef0123456789abcdef01234567.tar.gz' \
	<<<"$recipe_values"
grep -Fxq -- 'binder-compat.patch' <<<"$recipe_values"
grep -Fq -- 'patch -d "$source_dir" -Np1 -i "$srcdir/$STEAMOS_BINDER_PATCH"' \
	<<<"$recipe_values"

if env \
	STEAMOS_BINDER_REPOSITORY=https://github.com/example/anbox-modules.git \
	STEAMOS_BINDER_COMMIT=0123456789abcdef0123456789abcdef01234567 \
	STEAMOS_BINDER_IMPLEMENTATION=choff \
	STEAMOS_BINDER_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
	STEAMOS_KERNEL_RELEASE=6.1.2-test \
	bash -c 'source "$1"' bash "$PKGBUILD" 2>/dev/null; then
	printf 'not ok - Binder PKGBUILD accepted a missing package revision\n' >&2
	exit 1
fi

# Verify the Valve implementation uses a commit-pinned source archive.
valve_values="$(
	STEAMOS_BINDER_IMPLEMENTATION=valve
	STEAMOS_BINDER_REPOSITORY=https://github.com/evlaV/linux-integration.git
	STEAMOS_BINDER_COMMIT=0123456789abcdef0123456789abcdef01234567
	STEAMOS_BINDER_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
	STEAMOS_BINDER_PKGREL=7
	STEAMOS_KERNEL_RELEASE=6.18.50-test

	unset STEAMOS_BINDER_PATCH STEAMOS_BINDER_PATCH_SHA256

	# shellcheck source=/dev/null
	source "$PKGBUILD"

	# shellcheck disable=SC2154
	printf '%s\n' "${source[0]}" "${sha256sums[0]}"
	declare -f prepare
)"

grep -Fxq -- \
	'linux-integration-0123456789abcdef0123456789abcdef01234567.tar.gz::https://github.com/evlaV/linux-integration/archive/0123456789abcdef0123456789abcdef01234567.tar.gz' \
	<<<"$valve_values" || {
	printf 'not ok - Valve Binder source archive is incorrect\n' >&2
	exit 1
}

grep -Fxq -- \
	'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
	<<<"$valve_values" || {
	printf 'not ok - Valve Binder source checksum is incorrect\n' >&2
	exit 1
}

grep -Fq -- \
	'linux-integration-${STEAMOS_BINDER_COMMIT}/drivers/android/' \
	<<<"$valve_values" || {
	printf 'not ok - Valve Binder prepare() uses the wrong source directory\n' >&2
	exit 1
}

printf 'ok - Binder lock fields drive the package recipe\n'
