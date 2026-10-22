#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_non_root
for command_name in gh git python3; do
	require_command "$command_name"
done

resolve_bundle_version

GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
GITHUB_RELEASE_TAG="${GITHUB_RELEASE_TAG:-bundles}"
[[ "$GITHUB_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
	die "GITHUB_REPOSITORY must use the OWNER/REPOSITORY form"
[[ "$GITHUB_RELEASE_TAG" =~ ^[A-Za-z0-9._-]+$ ]] ||
	die "GITHUB_RELEASE_TAG contains unsafe characters"
gh auth status --hostname github.com >/dev/null 2>&1 ||
	die "GitHub CLI is not authenticated; run gh auth login on Fedora"

ARCHIVE_NAME="$BUNDLE_VERSION.tar.gz"
HASH_NAME="$ARCHIVE_NAME.sha256"
MANIFEST_NAME="$BUNDLE_VERSION.manifest"
LATEST_MANIFEST_NAME="latest.manifest"
TARGETS_MANIFEST_NAME="targets.manifest"

immutable_assets=(
	"$PUBLISH_ROOT/$ARCHIVE_NAME"
	"$PUBLISH_ROOT/$HASH_NAME"
	"$PUBLISH_ROOT/$MANIFEST_NAME"
)
catalog_assets=(
	"$PUBLISH_ROOT/$LATEST_MANIFEST_NAME"
	"$PUBLISH_ROOT/$TARGETS_MANIFEST_NAME"
)
for asset in "${immutable_assets[@]}" "${catalog_assets[@]}"; do
	[[ -f "$asset" ]] ||
		die "published asset is missing: $asset (run maintainer/publish-bundle.sh first)"
done

SOURCE_REVISION="$(git -C "$REPO_ROOT" rev-parse HEAD)"
gh api "repos/$GITHUB_REPOSITORY/commits/$SOURCE_REVISION" >/dev/null 2>&1 ||
	die "source revision $SOURCE_REVISION is not available in $GITHUB_REPOSITORY; push it first"
if ! gh release view "$GITHUB_RELEASE_TAG" \
	--repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
	printf 'Creating target-bundle Release %s...\n' "$GITHUB_RELEASE_TAG"
	release_flags=(--latest=false)
	if [[ "$GITHUB_RELEASE_TAG" == bundles ]]; then
		release_flags=(--latest)
	elif [[ "$GITHUB_RELEASE_TAG" == experimental-bundles ]]; then
		release_flags=(--prerelease --latest=false)
	fi
	gh release create "$GITHUB_RELEASE_TAG" \
		--repo "$GITHUB_REPOSITORY" \
		--target "$SOURCE_REVISION" \
		--title "SteamOS Waydroid target bundles" \
		--notes "Target-specific verified SteamOS Waydroid bundles." \
		"${release_flags[@]}"
fi

mapfile -t existing_assets < <(
	gh release view "$GITHUB_RELEASE_TAG" \
		--repo "$GITHUB_REPOSITORY" \
		--json assets \
		--jq '.assets[].name'
)
for immutable_asset in "${immutable_assets[@]}"; do
	immutable_name="$(basename -- "$immutable_asset")"
	for existing_name in "${existing_assets[@]}"; do
		[[ "$existing_name" != "$immutable_name" ]] ||
			die "immutable GitHub Release asset already exists: $immutable_name"
	done
done

printf 'Uploading immutable bundle assets for %s...\n' "$BUNDLE_VERSION"
gh release upload "$GITHUB_RELEASE_TAG" \
	"${immutable_assets[@]}" \
	--repo "$GITHUB_REPOSITORY"

printf 'Updating GitHub Release latest pointer...\n'
gh release upload "$GITHUB_RELEASE_TAG" \
	"$PUBLISH_ROOT/$LATEST_MANIFEST_NAME" \
	--clobber \
	--repo "$GITHUB_REPOSITORY"

printf 'Rebuilding the catalog from ALL published bundles in %s...\n' "$GITHUB_RELEASE_TAG"
"$SCRIPT_DIR/rebuild-release-catalog.sh" \
	--output "$PUBLISH_ROOT/$TARGETS_MANIFEST_NAME" --upload

# Keep experimental releases in the background, and production marked Latest.
if [[ "$GITHUB_RELEASE_TAG" == bundles ]]; then
	gh release edit "$GITHUB_RELEASE_TAG" --latest --repo "$GITHUB_REPOSITORY"
elif [[ "$GITHUB_RELEASE_TAG" == experimental-bundles ]]; then
	gh release edit "$GITHUB_RELEASE_TAG" --prerelease --repo "$GITHUB_REPOSITORY"
fi

printf '\nGitHub bundle published:\n'
printf '  repository: %s\n' "$GITHUB_REPOSITORY"
printf '  release:    %s\n' "$GITHUB_RELEASE_TAG"
printf '  bundle:     %s\n' "$BUNDLE_VERSION"
