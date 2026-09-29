#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

SYSTEM_PYTHON_FILES=(
	"$REPO_ROOT/steamos-waydroid-installer.sh"
	"$REPO_ROOT/extras/icon.py"
	"$REPO_ROOT/extras/scripts/Waydroid-Toolbox.sh"
	"$REPO_ROOT/extras/scripts/waydroid-mount"
	"$REPO_ROOT/libexec/steamos-waydroid/installer-functions.sh"
	"$REPO_ROOT/libexec/steamos-waydroid/uninstall.sh"
)

if rg -n '(^|[[:space:];|&(])python3([[:space:]]|$)' "${SYSTEM_PYTHON_FILES[@]}"; then
	printf 'not ok - SteamOS integration code uses PATH-resolved python3\n' >&2
	exit 1
fi

grep -Fq \
	'host_python_version=$(/usr/bin/python3 -c' \
	"$REPO_ROOT/steamos-waydroid-installer.sh"

grep -Fq \
	"if ! /usr/bin/python3 -c 'import gbinder'" \
	"$REPO_ROOT/steamos-waydroid-installer.sh"

grep -Fq \
	'#!/usr/bin/python3' \
	"$REPO_ROOT/extras/icon.py"

printf 'ok - SteamOS integration uses the system Python interpreter\n'
