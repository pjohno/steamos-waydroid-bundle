#!/usr/bin/env bash
# Rebuild targets.manifest from already-uploaded assets in one GitHub Release.
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
GITHUB_RELEASE_TAG="${GITHUB_RELEASE_TAG:-bundles}"
OUTPUT=""
UPLOAD=false
while (($#)); do
	case "$1" in
	--output)
		(($# >= 2)) || {
			printf 'error: --output requires a path\n' >&2
			exit 1
		}
		OUTPUT="$2"
		shift 2
		;;
	--upload)
		UPLOAD=true
		shift
		;;
	*)
		printf 'usage: %s [--output PATH] [--upload]\n' "$0" >&2
		exit 1
		;;
	esac
done

[[ "$GITHUB_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
	printf 'error: set GITHUB_REPOSITORY to OWNER/REPO\n' >&2
	exit 1
}
[[ "$GITHUB_RELEASE_TAG" =~ ^[A-Za-z0-9._-]+$ ]] || {
	printf 'error: invalid GITHUB_RELEASE_TAG\n' >&2
	exit 1
}
for tool in gh python3; do
	command -v "$tool" >/dev/null || {
		printf 'error: missing %s\n' "$tool" >&2
		exit 1
	}
done

staging="$(mktemp -d)"
trap 'rm -rf -- "$staging"' EXIT
mkdir -p "$staging/manifests"
release_id="$(gh api "repos/$GITHUB_REPOSITORY/releases/tags/$GITHUB_RELEASE_TAG" --jq '.id')"
[[ "$release_id" =~ ^[0-9]+$ ]] || {
	printf 'error: invalid release ID\n' >&2
	exit 1
}

gh api --paginate "repos/$GITHUB_REPOSITORY/releases/$release_id/assets?per_page=100" \
	--jq '.[] | [.name, .created_at, (.size | tostring)] | @tsv' \
	>"$staging/assets.tsv"
gh release download "$GITHUB_RELEASE_TAG" --repo "$GITHUB_REPOSITORY" \
	--pattern '*.manifest' --dir "$staging/manifests"
python3 "$SCRIPT_DIR/rebuild-release-catalog.py" \
	--assets "$staging/assets.tsv" \
	--manifests "$staging/manifests" \
	--output "$staging/targets.manifest"

if [[ -n "$OUTPUT" ]]; then
	cp -- "$staging/targets.manifest" "$OUTPUT"
fi
if $UPLOAD; then
	gh release upload "$GITHUB_RELEASE_TAG" "$staging/targets.manifest" \
		--clobber --repo "$GITHUB_REPOSITORY"
	printf 'Updated targets.manifest on %s (%s)\n' "$GITHUB_RELEASE_TAG" "$GITHUB_REPOSITORY"
else
	printf 'Dry run: no GitHub assets modified.\n'
	if [[ -z "$OUTPUT" ]]; then
		cat "$staging/targets.manifest"
	fi
fi
