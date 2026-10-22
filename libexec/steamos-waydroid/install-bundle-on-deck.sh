#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
CONFIG_FILE="${DECK_CONFIG_FILE:-$REPO_ROOT/.deck-config.env}"
ALLOW_TARGET_MISMATCH=false

if [[ ${1:-} == --allow-target-mismatch ]]; then
	ALLOW_TARGET_MISMATCH=true
elif [[ $# -ne 0 ]]; then
	printf 'usage: %s [--allow-target-mismatch]\n' "$0" >&2
	exit 1
fi

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

[[ ${STEAMOS_WAYDROID_INTERNAL:-} == 1 ]] ||
	die "this is an internal helper; run ./steamos-waydroid-installer.sh"

[[ "$(id -un)" == deck ]] || die "run this script as the deck user"
[[ -r /etc/os-release ]] || die "cannot read /etc/os-release"
# shellcheck source=/dev/null
source /etc/os-release
[[ ${ID:-} == steamos ]] || die "this script may only run on SteamOS"
[[ -f "$CONFIG_FILE" ]] ||
	die "run ./steamos-waydroid-installer.sh --configure-artifacts or create .deck-config.env"
# shellcheck source=/dev/null
source "$CONFIG_FILE"

# shellcheck source=lib/target-fingerprint.sh
source "$SCRIPT_DIR/lib/target-fingerprint.sh"
# shellcheck source=lib/kernel-capabilities.sh
source "$SCRIPT_DIR/lib/kernel-capabilities.sh"

ARTIFACT_SOURCE="${ARTIFACT_SOURCE:-}"
BUNDLE_VERSION="${BUNDLE_VERSION:-}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
GITHUB_RELEASE_TAG="${GITHUB_RELEASE_TAG:-bundles}"
[[ -n "$ARTIFACT_SOURCE" ]] || die "ARTIFACT_SOURCE is not configured"
[[ -n "$BUNDLE_VERSION" ]] || die "BUNDLE_VERSION is not configured"

GITHUB_CLI=""
if [[ "$ARTIFACT_SOURCE" == github-release ]]; then
	if command -v gh >/dev/null 2>&1; then
		GITHUB_CLI="$(command -v gh)"
	elif [[ -x "$HOME/.local/bin/gh" ]]; then
		GITHUB_CLI="$HOME/.local/bin/gh"
	else
		die "gh is required for a private GitHub Release artifact source"
	fi
	[[ "$GITHUB_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
		die "GITHUB_REPOSITORY must use the OWNER/REPOSITORY form"
	[[ "$GITHUB_RELEASE_TAG" =~ ^[A-Za-z0-9._-]+$ ]] ||
		die "GITHUB_RELEASE_TAG contains unsafe characters"
	"$GITHUB_CLI" auth status --hostname github.com >/dev/null 2>&1 ||
		die "GitHub CLI is not authenticated; run gh auth login on the Deck"
fi

for command_name in sha256sum tar; do
	command -v "$command_name" >/dev/null || die "required command not found: $command_name"
done

PROJECT_ROOT="$HOME/.local/opt/steamos-waydroid"
TARGET_MISMATCH_ALLOW_FILE="$PROJECT_ROOT/allow-target-mismatch"
REPORT_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/steamos-waydroid/reports"
mkdir -p "$HOME/.cache"
DOWNLOAD_ROOT="$(mktemp -d "$HOME/.cache/steamos-waydroid-artifact.XXXXXX")"
cleanup() {
	rm -rf -- "$DOWNLOAD_ROOT"
}
trap cleanup EXIT

fetch_file() {
	local filename="$1"
	case "$ARTIFACT_SOURCE" in
	github-release)
		"$GITHUB_CLI" release download "$GITHUB_RELEASE_TAG" \
			--repo "$GITHUB_REPOSITORY" \
			--pattern "$filename" \
			--output "$DOWNLOAD_ROOT/$filename"
		;;
	https://* | http://*)
		command -v curl >/dev/null || die "curl is required for an HTTP artifact source"
		curl --fail --location \
			"$ARTIFACT_SOURCE/$filename" \
			--output "$DOWNLOAD_ROOT/$filename"
		;;
	*:*)
		command -v rsync >/dev/null || die "rsync is required for an SSH artifact source"
		rsync -a -- "$ARTIFACT_SOURCE/$filename" "$DOWNLOAD_ROOT/$filename"
		;;
	*)
		die "ARTIFACT_SOURCE must be github-release, an SSH rsync source, or an http(s) URL"
		;;
	esac
}

manifest_value() {
	local manifest_file="$1"
	local key="$2"
	awk -F= -v wanted="$key" '$1 == wanted {sub(/^[^=]*=/, ""); print; exit}' \
		"$manifest_file"
}

if [[ "$BUNDLE_VERSION" == auto ]]; then
	printf 'Resolving the published bundle for this SteamOS target...\n'
	CURRENT_FINGERPRINT="$DOWNLOAD_ROOT/current-target-fingerprint.env"
	collect_target_fingerprint "$CURRENT_FINGERPRINT"
	CURRENT_TARGET_ENVIRONMENT="$(fingerprint_value \
		"$CURRENT_FINGERPRINT" TARGET_ENVIRONMENT_ID)"
	CURRENT_ABI="$(fingerprint_value "$CURRENT_FINGERPRINT" ABI_SHA256)"
	CURRENT_KERNEL="$(fingerprint_value "$CURRENT_FINGERPRINT" KERNEL_RELEASE)"
	BUNDLE_VERSION=""
	if fetch_file targets.manifest; then
		# Format 3 adds kernel-specific mappings. Older format 2 catalogs
		# remain supported through the target/ABI fallbacks below.
		BUNDLE_VERSION="$(manifest_value "$DOWNLOAD_ROOT/targets.manifest" \
			"target-kernel|$CURRENT_TARGET_ENVIRONMENT|$CURRENT_KERNEL")"
		if [[ -n "$BUNDLE_VERSION" ]]; then
			printf 'Exact target and kernel match found in the catalog.\n'
		fi
		if [[ -z "$BUNDLE_VERSION" ]]; then
			BUNDLE_VERSION="$(manifest_value "$DOWNLOAD_ROOT/targets.manifest" \
				"abi-kernel|$CURRENT_ABI|$CURRENT_KERNEL")"
			if [[ -n "$BUNDLE_VERSION" ]]; then
				printf 'ABI and kernel match found in the catalog.\n'
			fi
		fi
		if [[ -z "$BUNDLE_VERSION" ]]; then
			BUNDLE_VERSION="$(manifest_value "$DOWNLOAD_ROOT/targets.manifest" \
				"target|$CURRENT_TARGET_ENVIRONMENT")"
			if [[ -n "$BUNDLE_VERSION" ]]; then
				printf 'Exact target match found in the catalog.\n'
			fi
		fi
		if [[ -z "$BUNDLE_VERSION" ]] && running_kernel_has_builtin_binder; then
			BUNDLE_VERSION="$(manifest_value "$DOWNLOAD_ROOT/targets.manifest" \
				"abi|$CURRENT_ABI")"
			if [[ -n "$BUNDLE_VERSION" ]]; then
				printf 'ABI-compatible bundle match found in the catalog.\n'
				printf 'Userspace ABI matches and the running kernel provides Binder.\n'
			fi
		fi
	else
		printf 'Target catalog is not published yet; checking the legacy latest pointer.\n' >&2
		if fetch_file latest.manifest; then
			latest_target="$(fingerprint_value \
				"$DOWNLOAD_ROOT/latest.manifest" TARGET_ENVIRONMENT_ID)"
			if [[ "$latest_target" == "$CURRENT_TARGET_ENVIRONMENT" ]]; then
				BUNDLE_VERSION="$(manifest_value \
					"$DOWNLOAD_ROOT/latest.manifest" bundle_version)"
			elif running_kernel_has_builtin_binder &&
				[[ "$(fingerprint_value "$DOWNLOAD_ROOT/latest.manifest" ABI_SHA256)" == "$CURRENT_ABI" ]]; then
				BUNDLE_VERSION="$(manifest_value \
					"$DOWNLOAD_ROOT/latest.manifest" bundle_version)"
				printf 'Using ABI-compatible bundle from the legacy latest pointer.\n'
			fi
		else
			die "bundle catalog is unavailable or has not been published"
		fi
	fi
	[[ -n "$BUNDLE_VERSION" ]] ||
		die "no compatible bundle is published for target $CURRENT_TARGET_ENVIRONMENT"
fi
[[ "$BUNDLE_VERSION" =~ ^[A-Za-z0-9._-]+$ ]] || die "unsafe BUNDLE_VERSION"

ARCHIVE_NAME="$BUNDLE_VERSION.tar.gz"
HASH_NAME="$ARCHIVE_NAME.sha256"
MANIFEST_NAME="$BUNDLE_VERSION.manifest"
TARGET_ROOT="$PROJECT_ROOT/builds/$BUNDLE_VERSION"
STAGING_ROOT="$PROJECT_ROOT/.$BUNDLE_VERSION.staging"

printf 'Fetching target-built bundle %s...\n' "$BUNDLE_VERSION"
fetch_file "$MANIFEST_NAME"
manifest_bundle_version="$(manifest_value \
	"$DOWNLOAD_ROOT/$MANIFEST_NAME" bundle_version)"
[[ "$manifest_bundle_version" == "$BUNDLE_VERSION" ]] ||
	die "artifact manifest version does not match $BUNDLE_VERSION"
fetch_file "$ARCHIVE_NAME"
fetch_file "$HASH_NAME"

printf 'Checking artifact hash...\n'
(
	cd "$DOWNLOAD_ROOT"
	sha256sum --check "$HASH_NAME"
)

printf 'Checking archive paths before extraction...\n'
while IFS= read -r member; do
	case "$member" in
	"$BUNDLE_VERSION" | "$BUNDLE_VERSION/"*) ;;
	*) die "archive contains a path outside $BUNDLE_VERSION: $member" ;;
	esac
	case "/$member/" in
	*/../*) die "archive contains parent traversal: $member" ;;
	esac
done < <(tar -tzf "$DOWNLOAD_ROOT/$ARCHIVE_NAME")

mkdir -p "$PROJECT_ROOT/builds"
if [[ -e "$TARGET_ROOT" ]]; then
	printf 'Bundle version already exists; verifying it without overwriting.\n'
else
	[[ ! -e "$STAGING_ROOT" ]] ||
		mv "$STAGING_ROOT" "$STAGING_ROOT.failed-$(date +%Y%m%d-%H%M%S)"
	mkdir -p "$DOWNLOAD_ROOT/extracted"
	tar -xzf "$DOWNLOAD_ROOT/$ARCHIVE_NAME" \
		--no-same-owner --no-same-permissions \
		-C "$DOWNLOAD_ROOT/extracted"
	mv "$DOWNLOAD_ROOT/extracted/$BUNDLE_VERSION" "$STAGING_ROOT"
	mv "$STAGING_ROOT" "$TARGET_ROOT"
fi

printf 'Verifying the bundle against this SteamOS host...\n'
"$SCRIPT_DIR/verify-bundle.sh" "$TARGET_ROOT"
[[ -f "$TARGET_ROOT/.verified" ]] || die "artifact has no build verification marker"
target_check_arguments=("$TARGET_ROOT")
if ! target_state="$($TARGET_ROOT/tools/check-bundle-target.sh \
	"$TARGET_ROOT" --compatibility-state 2>/dev/null)"; then
	target_state=incompatible
fi
if [[ "$ALLOW_TARGET_MISMATCH" == true ]]; then
	target_check_arguments+=(--allow-target-mismatch)
fi
if ! target_check_output=$(
	"$TARGET_ROOT/tools/check-bundle-target.sh" "${target_check_arguments[@]}" 2>&1
); then
	report_file="$REPORT_ROOT/$(date -u +%Y%m%dT%H%M%SZ)-compatibility.md"
	"$TARGET_ROOT/tools/compatibility-report.sh" \
		"$TARGET_ROOT" "$report_file" || true
	printf '%s\n' "$target_check_output" >&2
	die "bundle target check failed; report saved to $report_file"
fi
printf '%s\n' "$target_check_output"

if [[ "$ALLOW_TARGET_MISMATCH" == true && "$target_state" == incompatible ]]; then
	printf '%s\n' "$BUNDLE_VERSION" >"$TARGET_MISMATCH_ALLOW_FILE"
else
	rm -f -- "$TARGET_MISMATCH_ALLOW_FILE"
fi

(
	cd "$PROJECT_ROOT"
	ln -sfn "builds/$BUNDLE_VERSION" current
)

printf '\nTarget-built bundle installed and activated:\n  %s\n' "$TARGET_ROOT"
