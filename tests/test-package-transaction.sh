#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

command -v rg >/dev/null 2>&1 || {
	printf 'not ok - rg (ripgrep) is required to run this test\n' >&2
	exit 1
}

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

MOCK_BIN="$TEST_ROOT/bin"
mkdir -p "$MOCK_BIN"

for package_name in libglibutil libgbinder python-gbinder waydroid; do
	: >"$TEST_ROOT/$package_name.pkg.tar.zst"
done

cat >"$MOCK_BIN/bsdtar" <<'EOF'
#!/usr/bin/env bash
package_file="${2:-}"
package_name="$(basename -- "$package_file" .pkg.tar.zst)"
printf 'pkgname = %s\n' "$package_name"
EOF

cat >"$MOCK_BIN/pacman" <<'EOF'
#!/usr/bin/env bash
if [[ ${PACMAN_FAIL:-false} == true ]]; then
	exit 1
fi
for package_name in ${PLANNED_PACKAGES:?PLANNED_PACKAGES is required}; do
	case "$package_name" in
	libglibutil | libgbinder | python-gbinder | waydroid)
		printf '%s||1.0-1\n' "$package_name"
		;;
	*)
		printf '%s|%s|1.0-1\n' "$package_name" "${PACKAGE_REPOSITORY-holo}"
		;;
	esac
done
EOF
chmod +x "$MOCK_BIN/bsdtar" "$MOCK_BIN/pacman"

# shellcheck source=/dev/null
source "$REPO_ROOT/libexec/steamos-waydroid/installer-functions.sh"

packages=(
	"$TEST_ROOT/libglibutil.pkg.tar.zst"
	"$TEST_ROOT/libgbinder.pkg.tar.zst"
	"$TEST_ROOT/python-gbinder.pkg.tar.zst"
	"$TEST_ROOT/waydroid.pkg.tar.zst"
)

PATH="$MOCK_BIN:/usr/bin:/bin" \
	PLANNED_PACKAGES='libglibutil libgbinder python-gbinder waydroid' \
	verify_pacman_transaction_dependencies "${packages[@]}" >/dev/null

PATH="$MOCK_BIN:/usr/bin:/bin" \
	PLANNED_PACKAGES='libglibutil libgbinder python-gbinder waydroid lxc dnsmasq recursive-dependency' \
	verify_pacman_transaction_dependencies "${packages[@]}" \
	>"$TEST_ROOT/output"
grep -Fq -- 'configured SteamOS repositories' "$TEST_ROOT/output"
grep -Fq -- 'lxc' "$TEST_ROOT/output"
grep -Fq -- 'dnsmasq' "$TEST_ROOT/output"
grep -Fq -- 'recursive-dependency' "$TEST_ROOT/output"
grep -Fq -- 'holo/lxc 1.0-1' "$TEST_ROOT/output"

if PATH="$MOCK_BIN:/usr/bin:/bin" \
	PACKAGE_REPOSITORY='' \
	PLANNED_PACKAGES='libglibutil libgbinder python-gbinder waydroid lxc' \
	verify_pacman_transaction_dependencies "${packages[@]}" \
	>"$TEST_ROOT/output" 2>&1; then
	printf 'not ok - a dependency without a repository source was accepted\n' >&2
	exit 1
fi
grep -Fq -- 'without a valid sync-repository source' "$TEST_ROOT/output"

if PATH="$MOCK_BIN:/usr/bin:/bin" \
	PACMAN_FAIL=true \
	PLANNED_PACKAGES=unused \
	verify_pacman_transaction_dependencies "${packages[@]}" \
	>"$TEST_ROOT/output" 2>&1; then
	printf 'not ok - an unresolved Pacman transaction was accepted\n' >&2
	exit 1
fi
grep -Fq -- 'could not resolve' "$TEST_ROOT/output"

if PATH="$MOCK_BIN:/usr/bin:/bin" \
	PLANNED_PACKAGES='libglibutil libgbinder python-gbinder' \
	verify_pacman_transaction_dependencies "${packages[@]}" \
	>"$TEST_ROOT/output" 2>&1; then
	printf 'not ok - incomplete Pacman preview was accepted\n' >&2
	exit 1
fi
grep -Fq -- 'waydroid' "$TEST_ROOT/output"

if rg -n -- \
	'libdisplay-info\.so\.[0-9]|pacman -U[^\n]*--nodeps|pacman -U[^\n]*-d([[:space:]]|$)' \
	"$REPO_ROOT/maintainer/build-bundle.sh" \
	"$REPO_ROOT/libexec/steamos-waydroid/verify-bundle.sh" \
	"$REPO_ROOT/steamos-waydroid-installer.sh"; then
	printf 'not ok - historical SONAME pin or disabled dependency checking remains\n' >&2
	exit 1
fi

printf 'ok - package installation resolves repository dependencies and remains SONAME-neutral\n'
