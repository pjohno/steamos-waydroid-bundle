#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if (cd "$REPO_ROOT" && rg -n \
	--glob '!tests/**' \
	--glob '!*.md' \
	'(^|[[:space:];|&(])python3([[:space:]]|$)' \
	.); then
	printf 'not ok - production code uses PATH-resolved python3\n' >&2
	exit 1
fi

printf 'ok - production code does not use PATH-resolved python3\n'
