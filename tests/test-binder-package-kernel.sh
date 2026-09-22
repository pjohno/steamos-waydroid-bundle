#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../libexec/steamos-waydroid/installer-functions.sh
source "$REPO_ROOT/libexec/steamos-waydroid/installer-functions.sh"

TEST_ROOT="$(mktemp -d)"
cleanup() { rm -rf -- "$TEST_ROOT"; }
trap cleanup EXIT

fail() {
	printf 'not ok - %s\n' "$*" >&2
	exit 1
}

MOCK_BIN="$TEST_ROOT/bin"
mkdir -p "$MOCK_BIN"

cat >"$MOCK_BIN/bsdtar" <<'EOF'
#!/usr/bin/env bash

[[ ${1:-} == -tf ]] || exit 1

case "${2##*/}" in
valid.pkg.tar.zst)
	cat <<'LISTING'
.PKGINFO
usr/
usr/lib/
usr/lib/modules/
usr/lib/modules/6.18.50-test/
usr/lib/modules/6.18.50-test/kernel/
usr/lib/modules/6.18.50-test/kernel/drivers/
usr/lib/modules/6.18.50-test/kernel/drivers/android/
usr/lib/modules/6.18.50-test/kernel/drivers/android/binder_linux.ko.zst
LISTING
	;;
mismatched.pkg.tar.zst)
	cat <<'LISTING'
.PKGINFO
usr/lib/modules/6.18.46-test/kernel/drivers/android/binder_linux.ko.zst
LISTING
	;;
leading-dot.pkg.tar.zst)
	cat <<'LISTING'
./usr/lib/modules/6.18.50-test/kernel/drivers/android/binder_linux.ko.xz
LISTING
	;;
missing-binder.pkg.tar.zst)
	cat <<'LISTING'
.PKGINFO
usr/lib/modules/6.18.50-test/kernel/drivers/android/something_else.ko.zst
LISTING
	;;
multiple-kernels.pkg.tar.zst)
	cat <<'LISTING'
usr/lib/modules/6.18.46-test/kernel/drivers/android/binder_linux.ko.zst
usr/lib/modules/6.18.50-test/kernel/drivers/android/binder_linux.ko.zst
LISTING
	;;
*)
	exit 1
	;;
esac
EOF

chmod +x "$MOCK_BIN/bsdtar"

for package in \
	valid.pkg.tar.zst \
	mismatched.pkg.tar.zst \
	leading-dot.pkg.tar.zst \
	missing-binder.pkg.tar.zst \
	multiple-kernels.pkg.tar.zst; do
	: >"$TEST_ROOT/$package"
done

PATH="$MOCK_BIN:$PATH"

kernel_release="$(
	binder_package_kernel_release "$TEST_ROOT/valid.pkg.tar.zst"
)" || fail 'valid Binder package was rejected'

[[ "$kernel_release" == 6.18.50-test ]] ||
	fail "valid Binder package returned unexpected kernel release: $kernel_release"

if ! validate_binder_kernel_match \
	"$kernel_release" \
	"6.18.50-test"; then
	fail 'Binder package matching the running kernel was rejected'
fi

mismatched_kernel_release="$(
	binder_package_kernel_release "$TEST_ROOT/mismatched.pkg.tar.zst"
)" || fail 'mismatched Binder package could not be inspected'

[[ "$mismatched_kernel_release" == 6.18.46-test ]] ||
	fail "mismatched Binder package returned unexpected kernel release: $mismatched_kernel_release"

if validate_binder_kernel_match \
	"$mismatched_kernel_release" \
	"6.18.50-test" \
	>"$TEST_ROOT/mismatch-output" 2>&1; then
	fail 'Binder package for a different running kernel was accepted'
fi

grep -Fq \
	'Bundled Binder module targets kernel 6.18.46-test.' \
	"$TEST_ROOT/mismatch-output" ||
	fail 'kernel mismatch did not report the Binder package kernel'

grep -Fq \
	'Running kernel is 6.18.50-test.' \
	"$TEST_ROOT/mismatch-output" ||
	fail 'kernel mismatch did not report the running kernel'

grep -Fq \
	'Refusing to install a Binder module built for a different kernel.' \
	"$TEST_ROOT/mismatch-output" ||
	fail 'kernel mismatch did not report that installation was refused'
	
kernel_release="$(
	binder_package_kernel_release "$TEST_ROOT/leading-dot.pkg.tar.zst"
)" || fail 'Binder package with ./ archive paths was rejected'

[[ "$kernel_release" == 6.18.50-test ]] ||
	fail "leading-dot package returned unexpected kernel release: $kernel_release"

if binder_package_kernel_release \
	"$TEST_ROOT/missing-binder.pkg.tar.zst" >/dev/null 2>&1; then
	fail 'package without binder_linux was accepted'
fi

if binder_package_kernel_release \
	"$TEST_ROOT/multiple-kernels.pkg.tar.zst" >/dev/null 2>&1; then
	fail 'package containing Binder modules for multiple kernels was accepted'
fi

if binder_package_kernel_release \
	"$TEST_ROOT/does-not-exist.pkg.tar.zst" >/dev/null 2>&1; then
	fail 'missing Binder package was accepted'
fi

printf 'ok - Binder package kernel release validation\n'
