#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_BUNDLE_SELECTOR="$SCRIPT_DIR/select-bundle"
PROFILE_LIB=/usr/lib/steamos-waydroid/waydroid-profile.sh
if [ ! -r "$PROFILE_LIB" ] &&
	[ -r "$SCRIPT_DIR/../../libexec/steamos-waydroid/waydroid-profile.sh" ]; then
	PROFILE_LIB="$SCRIPT_DIR/../../libexec/steamos-waydroid/waydroid-profile.sh"
fi
if [ ! -r "$PROFILE_LIB" ]; then
	kdialog --error "Waydroid profile helper is missing: $PROFILE_LIB

Run the SteamOS Waydroid installer in Desktop Mode to repair the host integration."
	exit 1
fi
# shellcheck source=../../libexec/steamos-waydroid/waydroid-profile.sh
source "$PROFILE_LIB"

REQUESTED_PROFILE=main
if [ "${1:-}" = --profile ]; then
	if [ -z "${2:-}" ]; then
		printf 'usage: %s [--profile main|test] [PACKAGE]\n' "$0" >&2
		exit 2
	fi
	REQUESTED_PROFILE=$2
	shift 2
fi
if (($# > 1)); then
	printf 'usage: %s [--profile main|test] [PACKAGE]\n' "$0" >&2
	exit 2
fi
resolve_waydroid_profile "$REQUESTED_PROFILE" || exit $?
export XDG_DATA_HOME=$WAYDROID_XDG_DATA_HOME

if [ -x "$LOCAL_BUNDLE_SELECTOR" ] &&
	! SELECTOR_OUTPUT=$("$LOCAL_BUNDLE_SELECTOR" 2>&1); then
	kdialog --error "No installed Cage bundle is compatible with this SteamOS host.

$SELECTOR_OUTPUT

Run the SteamOS Waydroid installer from Desktop Mode to fetch or repair the matching bundle."
	exit 1
fi

BUNDLE="$HOME/.local/opt/steamos-waydroid/current"
CAGE="$BUNDLE/bin/cage"
WLR_RANDR="$BUNDLE/bin/wlr-randr"
TARGET_CHECK="$BUNDLE/tools/check-bundle-target.sh"
COMPATIBILITY_REPORT="$BUNDLE/tools/compatibility-report.sh"
TARGET_ALLOW="$HOME/.local/opt/steamos-waydroid/allow-target-mismatch"
CONFIG_DIR="$SCRIPT_DIR/config"
RESOLUTION="$(xdpyinfo | awk '/dimensions/{print $2; found=1} END {if (!found) exit 1}')"

if [ ! -x "$CAGE" ] ||
	[ ! -x "$WLR_RANDR" ] ||
	[ ! -x "$TARGET_CHECK" ] ||
	[ ! -f "$BUNDLE/.verified" ]; then
	kdialog --error "Cage bundle is missing or unverified. Run the installer from Desktop Mode."
	exit 1
fi

target_check_args=("$BUNDLE")
active_bundle_version="$(basename "$(readlink -f "$BUNDLE")")"

if [ -r "$TARGET_ALLOW" ] &&
	[ "$(cat "$TARGET_ALLOW")" = "$active_bundle_version" ]; then
	target_check_args+=(--allow-target-mismatch)
fi

if ! TARGET_CHECK_OUTPUT=$("$TARGET_CHECK" "${target_check_args[@]}" 2>&1); then
	REPORT_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/steamos-waydroid/reports/$(date -u +%Y%m%dT%H%M%SZ)-compatibility.md"

	if [ -x "$COMPATIBILITY_REPORT" ]; then
		"$COMPATIBILITY_REPORT" "$BUNDLE" "$REPORT_FILE" || true
	fi

	kdialog --error "The Cage bundle is incompatible with this SteamOS host.

$TARGET_CHECK_OUTPUT

Compatibility report: $REPORT_FILE

Rebuild and install the bundle before launching Waydroid."
	exit 1
fi

if [ ! -x /usr/bin/waydroid ]; then
	kdialog --sorry "Cannot start Waydroid because the SteamOS host component is missing. \
\nIf SteamOS was recently updated, run the SteamOS Waydroid installer from Desktop Mode. \
\nSteamOS version: $(grep -i VERSION_ID /etc/os-release | cut -d '=' -f 2) \
\nKernel version: $(uname -r | cut -d '-' -f 1-5)"
	exit 1
fi

if [ -z "$RESOLUTION" ] ||
	[ ! -r "$CONFIG_DIR/fake_wifi" ] ||
	[ ! -r "$CONFIG_DIR/fake_touch" ]; then
	kdialog --error "Waydroid launcher configuration is incomplete. Reinstall the host component."
	exit 1
fi

SHARED_FOLDER_LIB="${STEAMOS_WAYDROID_SHARED_FOLDER_LIB:-/usr/lib/steamos-waydroid/shared-folder.sh}"
if [ ! -r "$SHARED_FOLDER_LIB" ]; then
	kdialog --error "Waydroid shared-folder helper is missing: $SHARED_FOLDER_LIB

Run the SteamOS Waydroid installer in Desktop Mode to repair the host integration."
	exit 1
fi
# shellcheck source=../../libexec/steamos-waydroid/shared-folder.sh
source "$SHARED_FOLDER_LIB"
if ! SHARE_OUTPUT=$(ensure_waydroid_share_source "$HOME" 2>&1); then
	kdialog --error "Waydroid shared-folder setup failed.

$SHARE_OUTPUT"
	exit 1
fi

cleanup_required=false
LAUNCH_ERROR_LOG="$(mktemp "${XDG_RUNTIME_DIR:-/tmp}/steamos-waydroid-launch.XXXXXX")"

cleanup() {
	if [ "$cleanup_required" = true ]; then
		cleanup_required=false
		sudo /usr/bin/waydroid-shutdown-scripts "$WAYDROID_PROFILE" || true
	fi
	rm -f -- "$LAUNCH_ERROR_LOG"
}

show_launch_failure() {
	local launch_status="$1"
	local error_details

	error_details="$(tail -n 30 "$LAUNCH_ERROR_LOG" 2>/dev/null || true)"
	if [ -z "$error_details" ]; then
		error_details="Cage exited with status $launch_status without diagnostic output."
	fi
	cleanup
	kdialog --error "Waydroid could not finish starting.

$error_details

Run the SteamOS Waydroid installer in Desktop Mode to repair the reported problem."
	exit 1
}

trap cleanup EXIT
trap 'exit 130' HUP INT TERM

# Check profile ownership before stopping any existing user session. This
# prevents a test launch from disrupting a running main environment (and vice
# versa). waydroid-mount repeats the check immediately before mounting.
if ! PROFILE_CHECK_OUTPUT=$(sudo /usr/bin/waydroid-mount "$WAYDROID_PROFILE" --check-only 2>&1); then
	kdialog --error "Waydroid cannot switch profiles while another environment is active.

$PROFILE_CHECK_OUTPUT

Shut down Waydroid, then try again."
	exit 1
fi

# A running Waydroid session remains bound to the Wayland compositor that
# started it. Stop it gracefully before waydroid-mount stops the container, so
# the session started below will bind to Cage instead of returning immediately
# through the stale session on the desktop compositor.
/usr/bin/waydroid session stop >/dev/null 2>&1 || true

# Mount persistent Android state before starting the container. From this point
# onward, the EXIT trap owns cleanup, including launch failures and signals.
if ! PREFLIGHT_OUTPUT=$(sudo /usr/bin/waydroid-mount "$WAYDROID_PROFILE" 2>&1); then
	kdialog --error "Waydroid preflight failed before Cage was started.

$PREFLIGHT_OUTPUT

Run the SteamOS Waydroid installer in Desktop Mode to repair the reported problem."
	exit 1
fi
cleanup_required=true

if ! CONTAINER_OUTPUT=$(sudo /usr/bin/waydroid-firewall 2>&1); then
	kdialog --error "Waydroid container startup failed.

$CONTAINER_OUTPUT

Run the SteamOS Waydroid installer in Desktop Mode to repair the host integration."
	exit 1
fi

if ! systemctl is-active --quiet waydroid-container.service; then
	SERVICE_STATUS="$(systemctl status --no-pager waydroid-container.service 2>&1 || true)"
	kdialog --error "The Waydroid container did not remain active.

$SERVICE_STATUS

Run the SteamOS Waydroid installer in Desktop Mode to repair the host integration."
	exit 1
fi

if [ -z "${1:-}" ]; then

	# Variables inside this single-quoted command are intentionally expanded
	# by the inner bash process using the positional arguments supplied below.
	# shellcheck disable=SC2016
	if "$CAGE" -- bash -c '
		readonly WLR_RANDR="$1"
		readonly RESOLUTION="$2"
		readonly CONFIG_DIR="$3"
		readonly WAYDROID_PROFILE="$4"

		"$WLR_RANDR" \
			--output X11-1 \
			--custom-mode "$RESOLUTION"

		/usr/bin/waydroid show-full-ui &
		readonly WAYDROID_SESSION_PID=$!

		if ! sudo /usr/bin/waydroid-startup-scripts "$WAYDROID_PROFILE"; then
			jobs -pr | while IFS= read -r child_pid; do
				kill "$child_pid" 2>/dev/null || true
			done
			wait 2>/dev/null || true
			exit 1
		fi

		waydroid prop set \
			persist.waydroid.fake_wifi \
			"$(cat "$CONFIG_DIR/fake_wifi")"

		waydroid prop set \
			persist.waydroid.fake_touch \
			"$(cat "$CONFIG_DIR/fake_touch")"

		wait "$WAYDROID_SESSION_PID"
	' bash "$WLR_RANDR" "$RESOLUTION" "$CONFIG_DIR" "$WAYDROID_PROFILE" \
		>"$LAUNCH_ERROR_LOG" 2>&1; then
		:
	else
		launch_status=$?
		show_launch_failure "$launch_status"
	fi
else
	PACKAGE="$1"

	# Variables inside this single-quoted command are intentionally expanded
	# by the inner bash process using the positional arguments supplied below.
	# shellcheck disable=SC2016
	if "$CAGE" -- bash -c '
		readonly WLR_RANDR="$1"
		readonly RESOLUTION="$2"
		readonly CONFIG_DIR="$3"
		readonly PACKAGE="$4"
		readonly WAYDROID_PROFILE="$5"

		"$WLR_RANDR" \
			--output X11-1 \
			--custom-mode "$RESOLUTION"

		/usr/bin/waydroid session start &
		readonly WAYDROID_SESSION_PID=$!

		if ! sudo /usr/bin/waydroid-startup-scripts "$WAYDROID_PROFILE"; then
			jobs -pr | while IFS= read -r child_pid; do
				kill "$child_pid" 2>/dev/null || true
			done
			wait 2>/dev/null || true
			exit 1
		fi

		waydroid prop set \
			persist.waydroid.fake_wifi \
			"$(cat "$CONFIG_DIR/fake_wifi")"

		waydroid prop set \
			persist.waydroid.fake_touch \
			"$(cat "$CONFIG_DIR/fake_touch")"
		sleep 1

		/usr/bin/waydroid app launch "$PACKAGE" &
		sleep 1

		/usr/bin/waydroid show-full-ui &
		wait "$WAYDROID_SESSION_PID"
	' bash "$WLR_RANDR" "$RESOLUTION" "$CONFIG_DIR" "$PACKAGE" "$WAYDROID_PROFILE" \
		>"$LAUNCH_ERROR_LOG" 2>&1; then
		:
	else
		launch_status=$?
		show_launch_failure "$launch_status"
	fi
fi
