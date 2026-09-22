#!/bin/bash

# This script sets the SCRIPT_DIR variable to the directory where the script resides and then changes the working directory to that location.
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
cd "$SCRIPT_DIR" || exit 1

# This section sets up different modes for managing Waydroid on SteamOS using command-line arguments.
REPAIR_MODE=false
CONFIGURE_ARTIFACTS=false
UNINSTALL_MODE=false
FULL_UNINSTALL_MODE=false
PURGE_ANDROID_MODE=false
RESET_HOST_KEEP_ANDROID_MODE=false
REINSTALL_ANDROID_MODE=false
AUTO_REPAIR_MODE=false
ANDROID_REINSTALL_HAS_EXISTING=false
TEST_INSTALL_MODE=false
REMOVE_TEST_MODE=false
TEST_INSTALL_COMMITTED=false
TEST_INSTALL_CLEANUP_DONE=false
usage() {
	echo "Usage: $0 [OPTION]" >&2
	echo "Options:" >&2
	echo "  --repair                   Repairs the current installation of Waydroid." >&2
	echo "  --reinstall-android        Reinstalls the Android system on Waydroid." >&2
	echo "  --install-test             Installs a separate experimental Waydroid Test environment." >&2
	echo "  --remove-test              Removes the separate Waydroid Test Android environment." >&2
	echo "  --configure-artifacts      Configures additional artifacts for selecting a bundle." >&2
	echo "  --uninstall                Uninstalls Waydroid from SteamOS." >&2
	echo "  --purge-android            Purges all Android data and configurations." >&2
	echo "  --uninstall-all            Performs a full uninstall, including configuration files." >&2
	echo "  --reset-host-keep-android  Completely resets the host system while keeping Android data intact." >&2
}
if [ "$#" -gt 1 ]; then
	usage
	exit 1
fi
case "${1:-}" in
"") ;;
--repair) REPAIR_MODE=true ;;
--reinstall-android) REINSTALL_ANDROID_MODE=true ;;
--install-test) TEST_INSTALL_MODE=true ;;
--remove-test) REMOVE_TEST_MODE=true ;;
--configure-artifacts) CONFIGURE_ARTIFACTS=true ;;
--uninstall) UNINSTALL_MODE=true ;;
--purge-android) PURGE_ANDROID_MODE=true ;;
--uninstall-all) FULL_UNINSTALL_MODE=true ;;
--reset-host-keep-android) RESET_HOST_KEEP_ANDROID_MODE=true ;;
*)
	usage
	exit 1
	;;
esac

if [ "$REMOVE_TEST_MODE" = true ]; then
	exec "$SCRIPT_DIR/libexec/steamos-waydroid/remove-test-environment.sh"
fi

clear

echo SteamOS Waydroid Installer - target-built public bundle edition
echo https://github.com/pjohno/steamos-waydroid-bundle
echo Based on the installer by ryanrudolf / 10MinuteSteamDeckGamer
sleep 2

# define variables here
if SCRIPT_VERSION_SHA=$(git rev-parse --short HEAD 2>/dev/null); then
	:
elif [ -r .source-version ]; then
	SCRIPT_VERSION_SHA=$(cat .source-version)
else
	SCRIPT_VERSION_SHA=development
fi
if [ ! -r /etc/os-release ]; then
	echo SteamOS release metadata is unavailable. >&2
	exit 1
fi
# shellcheck source=/dev/null
source /etc/os-release

# following variables are used in externally sourced functions
# shellcheck disable=SC2034
STEAMOS_VERSION_ID=${VERSION_ID:-unknown}
# shellcheck disable=SC2034
STEAMOS_BUILD_ID=${BUILD_ID:-unknown}
# shellcheck disable=SC2034
STEAMOS_BRANCH=$(steamos-select-branch -c 2>/dev/null || true)

WORKING_DIR=$SCRIPT_DIR
DECK_CONFIG_FILE=${DECK_CONFIG_FILE:-$WORKING_DIR/.deck-config.env}
DECK_RUNTIME=$WORKING_DIR/libexec/steamos-waydroid
ARTIFACT_CONFIGURATOR=$DECK_RUNTIME/configure-artifacts.sh
# shellcheck source=libexec/steamos-waydroid/waydroid-profile.sh
source "$DECK_RUNTIME/waydroid-profile.sh"
if [ "$TEST_INSTALL_MODE" = true ]; then
	resolve_waydroid_profile test || exit $?
	export XDG_DATA_HOME=$WAYDROID_XDG_DATA_HOME
else
	resolve_waydroid_profile main || exit $?
fi
ANDROID_HOME=${WAYDROID_IMAGE%/*}
WAYDROID_LEGACY_USER_STATE=$HOME/waydroid
FIREWALL_OWNERSHIP_FILE=$HOME/.local/share/steamos-waydroid-installer/firewall-ownership.env
# shellcheck source=libexec/steamos-waydroid/installer-functions.sh
source "$DECK_RUNTIME/installer-functions.sh"
# shellcheck source=libexec/steamos-waydroid/android-image-sources.sh
source "$DECK_RUNTIME/android-image-sources.sh"
# shellcheck source=libexec/steamos-waydroid/installer-sanity-checks.sh
source "$DECK_RUNTIME/installer-sanity-checks.sh"
# shellcheck source=libexec/steamos-waydroid/firewall-rules.sh
source "$DECK_RUNTIME/firewall-rules.sh"
# shellcheck source=libexec/steamos-waydroid/lib/kernel-capabilities.sh
source "$DECK_RUNTIME/lib/kernel-capabilities.sh"
# shellcheck source=libexec/steamos-waydroid/shared-folder.sh
source "$DECK_RUNTIME/shared-folder.sh"
if [ "$FULL_UNINSTALL_MODE" = true ]; then
	STEAMOS_WAYDROID_INTERNAL=1 \
		"$DECK_RUNTIME/uninstall.sh" --full-process
	exit $?
elif [ "$RESET_HOST_KEEP_ANDROID_MODE" = true ]; then
	STEAMOS_WAYDROID_INTERNAL=1 \
		"$DECK_RUNTIME/uninstall.sh" --reset-host-keep-android
	exit $?
elif [ "$PURGE_ANDROID_MODE" = true ]; then
	STEAMOS_WAYDROID_INTERNAL=1 \
		"$DECK_RUNTIME/uninstall.sh" --purge-android
	exit $?
elif [ "$UNINSTALL_MODE" = true ]; then
	STEAMOS_WAYDROID_INTERNAL=1 \
		"$DECK_RUNTIME/uninstall.sh" --keep-android
	exit $?
elif [ "$CONFIGURE_ARTIFACTS" = true ]; then
	if ! STEAMOS_WAYDROID_INTERNAL=1 "$ARTIFACT_CONFIGURATOR" --force; then
		echo Artifact configuration was not completed. >&2
		exit 1
	fi
	exit 0
fi

# Test installation is deliberately independent from main repair/reinstall
# detection. Existing test state is never archived or replaced in stage 2.
if [ "$TEST_INSTALL_MODE" = true ]; then
	test_environment_install_allowed || exit 1
	ensure_waydroid_runtime_inactive_for_test_install || exit 1
fi

# A main persistent Android image is authoritative installation state. A normal
# run repairs the host around it; Android replacement requires an explicit option.
if [ "$TEST_INSTALL_MODE" != true ] &&
	[ "$REPAIR_MODE" != true ] && [ "$REINSTALL_ANDROID_MODE" != true ] &&
	{ [ -e "$WAYDROID_IMAGE" ] || [ -L "$WAYDROID_IMAGE" ]; }; then
	REPAIR_MODE=true
	AUTO_REPAIR_MODE=true
fi

if [ "$TEST_INSTALL_MODE" != true ] &&
	[ "$REPAIR_MODE" != true ] && [ "$REINSTALL_ANDROID_MODE" != true ] &&
	[ ! -e "$WAYDROID_IMAGE" ] && [ ! -L "$WAYDROID_IMAGE" ] &&
	{ [ -e "$WAYDROID_USER_STATE" ] || [ -L "$WAYDROID_USER_STATE" ] ||
		[ -e "$WAYDROID_LEGACY_USER_STATE" ] || [ -L "$WAYDROID_LEGACY_USER_STATE" ]; }; then
	echo Existing Android user data was found without its matching persistent image. >&2
	echo Restore the image before running repair, or use --reinstall-android to archive >&2
	echo the orphaned user data and deliberately create a new Android instance. >&2
	exit 1
fi

if ! run_nonprivileged_sanity_checks; then
	exit 1
fi

if [ "$REPAIR_MODE" = true ]; then
	if [ ! -f "$WAYDROID_IMAGE" ] || [ -L "$WAYDROID_IMAGE" ]; then
		echo "Existing-install repair requires a regular Android image: $WAYDROID_IMAGE" >&2
		exit 1
	fi
	if [ "$AUTO_REPAIR_MODE" = true ]; then
		echo Existing Android state detected. Selecting safe host-repair mode by default.
	fi
elif [ "$REINSTALL_ANDROID_MODE" = true ] &&
	{ [ -e "$WAYDROID_IMAGE" ] || [ -L "$WAYDROID_IMAGE" ] ||
		[ -e "$WAYDROID_USER_STATE" ] || [ -L "$WAYDROID_USER_STATE" ] ||
		[ -e "$WAYDROID_LEGACY_USER_STATE" ] || [ -L "$WAYDROID_LEGACY_USER_STATE" ]; }; then
	if { [ -e "$WAYDROID_IMAGE" ] || [ -L "$WAYDROID_IMAGE" ]; } &&
		{ [ ! -f "$WAYDROID_IMAGE" ] || [ -L "$WAYDROID_IMAGE" ]; }; then
		echo "Android reinstallation refuses a non-regular image: $WAYDROID_IMAGE" >&2
		exit 1
	fi
	if ! confirm_android_reinstall; then
		exit 1
	fi
	ANDROID_REINSTALL_HAS_EXISTING=true
fi

if [ ! -f "$DECK_CONFIG_FILE" ]; then
	echo No Deck artifact configuration was found. Using the official public bundle source.
	if ! STEAMOS_WAYDROID_INTERNAL=1 "$ARTIFACT_CONFIGURATOR" --defaults; then
		echo Artifact configuration was not completed. >&2
		exit 1
	fi
fi
if [ "$TEST_INSTALL_MODE" = true ]; then
	LOGFILE=$WORKING_DIR/logfile-test
else
	LOGFILE=$WORKING_DIR/logfile
fi
WAYDROID_SCRIPT=https://github.com/casualsnek/waydroid_script.git
WAYDROID_SCRIPT_DIR=$(mktemp -d)/waydroid_script
ARM_Choice=libhoudini
ACTIVE_BUNDLE=$HOME/.local/opt/steamos-waydroid/current
BUNDLED_CAGE=$ACTIVE_BUNDLE/bin/cage
BUNDLED_WLR_RANDR=$ACTIVE_BUNDLE/bin/wlr-randr
BUNDLE_TARGET_CHECK=$ACTIVE_BUNDLE/tools/check-bundle-target.sh
BUNDLE_COMPATIBILITY_REPORT=$ACTIVE_BUNDLE/tools/compatibility-report.sh
BUNDLE_TARGET_ALLOW=$HOME/.local/opt/steamos-waydroid/allow-target-mismatch
HOST_PACKAGE_ROOT=$ACTIVE_BUNDLE/packages

# android TV builds
ANDROID13_TV_OTA=https://ota.supechicken666.dev

echo "script version: $SCRIPT_VERSION_SHA"
if [ "$REPAIR_MODE" = true ]; then
	echo Mode: repair existing installation
elif [ "$REINSTALL_ANDROID_MODE" = true ]; then
	if [ "$ANDROID_REINSTALL_HAS_EXISTING" = true ]; then
		echo Mode: reinstall Android while retaining recoverable copies of the previous image and user data
	else
		printf 'Mode: install Android; no previous persistent image was found.\n'
	fi
elif [ "$TEST_INSTALL_MODE" = true ]; then
	printf 'Mode: install separate Waydroid Test environment\n'
fi

# Select an already-installed compatible target bundle, or fetch the matching
# published artifact, before this installer performs privileged integration.
if ! ensure_sanity_bundle; then
	exit 1
fi

# This runs as the normal SteamOS user. Existing contents, ownership, and
# permissions are deliberately left untouched.
if ! ensure_waydroid_share_source "$HOME"; then
	exit 1
fi

python_package=("$HOST_PACKAGE_ROOT"/python-gbinder*.zst)
if [ "${#python_package[@]}" -ne 1 ] || [ ! -f "${python_package[0]}" ]; then
	echo The target-built bundle must contain exactly one python-gbinder package. >&2
	exit 1
fi
packaged_python_version=$(bsdtar -tf "${python_package[0]}" |
	awk -F/ '$2 == "lib" && $3 ~ /^python[0-9]+\.[0-9]+$/ {sub(/^python/, "", $3); print $3; exit}')
host_python_version=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
if [ -z "$packaged_python_version" ] || [ "$packaged_python_version" != "$host_python_version" ]; then
	echo "Bundled python-gbinder targets Python ${packaged_python_version:-unknown}, but SteamOS provides Python $host_python_version." >&2
	echo Build and publish a compatible bundle before continuing. >&2
	exit 1
fi

# Defence in depth: repeat the active-bundle verification before continuing.
if [ ! -x "$BUNDLED_CAGE" ] || [ ! -x "$BUNDLED_WLR_RANDR" ] ||
	[ ! -x "$BUNDLE_TARGET_CHECK" ] ||
	[ ! -x "$BUNDLE_COMPATIBILITY_REPORT" ] ||
	[ ! -f "$ACTIVE_BUNDLE/.verified" ]; then
	echo Target-built bundle is missing or unverified.
	echo "Expected bundle: $ACTIVE_BUNDLE"
	echo Run the installer again and inspect the bundle-selection error.
	exit 1
fi
target_check_args=("$ACTIVE_BUNDLE")
active_bundle_version=$(basename "$(readlink -f "$ACTIVE_BUNDLE")")
if [ -r "$BUNDLE_TARGET_ALLOW" ] &&
	[ "$(cat "$BUNDLE_TARGET_ALLOW")" = "$active_bundle_version" ]; then
	target_check_args+=(--allow-target-mismatch)
fi
if ! "$BUNDLE_TARGET_CHECK" "${target_check_args[@]}"; then
	report_file="${XDG_STATE_HOME:-$HOME/.local/state}/steamos-waydroid/reports/$(date -u +%Y%m%dT%H%M%SZ)-compatibility.md"
	"$BUNDLE_COMPATIBILITY_REPORT" "$ACTIVE_BUNDLE" "$report_file" || true
	echo The active bundle was built for a different SteamOS target.
	echo Compatibility report: "$report_file"
	echo Build, publish, and install a bundle for the current SteamOS build first.
	exit 1
fi

# Validate Binder compatibility before requesting sudo or changing SteamOS.
running_kernel_release=$(uname -r)

shopt -s nullglob
binder_packages=(
	"$HOST_PACKAGE_ROOT"/steamos-waydroid-binder-*.pkg.tar.zst
)
shopt -u nullglob

if [ "${#binder_packages[@]}" -gt 1 ]; then
	echo The target-built bundle contains multiple steamos-waydroid-binder packages. >&2
	exit 1
fi

binder_builtin=false
binder_package_kernel=""

if running_kernel_has_builtin_binder; then
	binder_builtin=true
	echo "Running SteamOS kernel $running_kernel_release provides built-in Binder support."
elif [ "${#binder_packages[@]}" -eq 0 ]; then
	echo "Running kernel $running_kernel_release does not provide built-in Binder support." >&2
	echo "The selected bundle does not contain a steamos-waydroid-binder package." >&2
	echo "Build and publish a Binder package for the running kernel before continuing." >&2
	exit 1
else
	if ! binder_package_kernel=$(
		binder_package_kernel_release "${binder_packages[0]}"
	); then
		exit 1
	fi

	if ! validate_binder_kernel_match \
		"$binder_package_kernel" \
		"$running_kernel_release"; then
		exit 1
	fi

	echo "Bundled Binder module matches running kernel $running_kernel_release."
fi

abort_run() {
	if [ "$TEST_INSTALL_MODE" = true ]; then
		cleanup_failed_test_environment
		exit 1
	fi
	if [ "$REPAIR_MODE" = true ]; then
		echo Repair failed. Persistent Android data has not been removed. >&2
		exit 1
	fi
	cleanup_exit
}

run_profile_sudo() {
	if [ "$TEST_INSTALL_MODE" = true ]; then
		sudo -S env "XDG_DATA_HOME=$WAYDROID_XDG_DATA_HOME" "$@"
	else
		sudo -S "$@"
	fi
}

test_install_exit_cleanup() {
	local exit_status=$?

	trap - EXIT
	if [ "$TEST_INSTALL_COMMITTED" != true ]; then
		cleanup_failed_test_environment
	else
		restore_decky_loader || true
	fi
	return "$exit_status"
}

reinstall_exit_cleanup() {
	exit_status=$?
	trap - EXIT
	if [ "${ANDROID_REINSTALL_COMMITTED:-false}" != true ]; then
		restore_archived_android_state_after_failure || true
	fi
	restore_decky_loader || true
	return "$exit_status"
}

prompt_return_to_gaming_mode() {
	if zenity --question --text="Do you Want to Return to Gaming Mode?"; then
		qdbus org.kde.Shutdown /Shutdown org.kde.Shutdown.logout
	fi
}

# Return success only when no matching shortcut exists. Existing entries are
# deliberately left to Steam and are never modified or deleted here.
shortcut_should_be_created() {
	shortcut_target=$1
	shortcut_label=$2
	SHORTCUT_MATCH_COUNT=$(python3 "$WORKING_DIR/extras/icon.py" count "$shortcut_target")
	shortcut_status=$?
	if [ "$shortcut_status" -ne 0 ] || ! [[ "$SHORTCUT_MATCH_COUNT" =~ ^[0-9]+$ ]]; then
		echo "Warning: Steam shortcuts could not be inspected; $shortcut_label will not be changed." >&2
		return 1
	fi
	if [ "$SHORTCUT_MATCH_COUNT" -eq 0 ]; then
		return 0
	fi

	echo "$SHORTCUT_MATCH_COUNT matching $shortcut_label shortcut(s) already exist; leaving them unchanged."
	return 1
}

wait_for_new_shortcut() {
	shortcut_target=$1
	previous_count=$2
	shortcut_wait_attempt=0
	while [ "$shortcut_wait_attempt" -lt 45 ]; do
		current_count=$(python3 "$WORKING_DIR/extras/icon.py" count "$shortcut_target" 2>/dev/null) ||
			current_count=""
		if [[ "$current_count" =~ ^[0-9]+$ ]] && [ "$current_count" -gt "$previous_count" ]; then
			return 0
		fi
		sleep 1
		shortcut_wait_attempt=$((shortcut_wait_attempt + 1))
	done
	return 1
}

ensure_game_mode_shortcuts() {
	local main_image selected_profile test_image test_launcher

	echo "Checking Game Mode shortcuts..."
	logged_in_user=$(whoami)
	logged_in_home=$(eval echo "~$logged_in_user")
	launcher_script="${logged_in_home}/Android_Waydroid/Android_Waydroid_Cage.sh"
	if [ -d "${logged_in_home}/Android_Waydroid" ]; then
		mkdir -p "${logged_in_home}/Android_Waydroid/icons"
		cp "$WORKING_DIR/extras/icon.py" \
			"${logged_in_home}/Android_Waydroid/steam-shortcuts.py"
		cp -a "$WORKING_DIR/extras/icons/." \
			"${logged_in_home}/Android_Waydroid/icons/"
	fi
	selected_profile=$WAYDROID_PROFILE
	resolve_waydroid_profile main || return 1
	main_image=$WAYDROID_IMAGE
	resolve_waydroid_profile test || return 1
	test_image=$WAYDROID_IMAGE
	resolve_waydroid_profile "$selected_profile" || return 1
	test_launcher="${logged_in_home}/Android_Waydroid/Android_Waydroid_Test_Cage.sh"

	if [ -f "$main_image" ] && shortcut_should_be_created waydroid Waydroid; then
		if [ ! -f "$launcher_script" ]; then
			echo "Error: Launcher script '$launcher_script' not found." >&2
		else
			chmod +x "$launcher_script"
			TMP_DESKTOP="/tmp/waydroid-temp.desktop"
			cat >"$TMP_DESKTOP" <<EOF
[Desktop Entry]
Name=Waydroid
Exec=${launcher_script}
Path=${logged_in_home}/Android_Waydroid
Type=Application
Terminal=false
Icon=${logged_in_home}/Android_Waydroid/icons/waydroid/icon.png
EOF
			chmod +x "$TMP_DESKTOP"
			if steamos-add-to-steam "$TMP_DESKTOP"; then
				if wait_for_new_shortcut waydroid "$SHORTCUT_MATCH_COUNT"; then
					shortcut_reconcile_args=(
						reconcile waydroid
						--artwork-dir "$WORKING_DIR/extras/icons/waydroid"
					)
					shortcut_reconcile_args+=(--keep-duplicates)
					python3 "$WORKING_DIR/extras/icon.py" "${shortcut_reconcile_args[@]}" ||
						echo "Warning: Waydroid artwork could not be installed." >&2
				else
					echo "Warning: Steam did not create the Waydroid shortcut within 45 seconds." >&2
				fi
			else
				echo "Warning: Waydroid shortcut could not be created." >&2
			fi
			rm -f "$TMP_DESKTOP"
		fi
	fi

	if [ -f "$test_image" ] && shortcut_should_be_created waydroid-test "Waydroid Test"; then
		if [ ! -f "$test_launcher" ]; then
			echo "Error: Test launcher script '$test_launcher' not found." >&2
		else
			chmod +x "$test_launcher"
			TMP_TEST_DESKTOP="/tmp/waydroid-test-temp.desktop"
			cat >"$TMP_TEST_DESKTOP" <<EOF
[Desktop Entry]
Name=Waydroid Test
Exec=${test_launcher}
Path=${logged_in_home}/Android_Waydroid
Type=Application
Terminal=false
Icon=${logged_in_home}/Android_Waydroid/icons/waydroid-test/icon.png
EOF
			chmod +x "$TMP_TEST_DESKTOP"
			if steamos-add-to-steam "$TMP_TEST_DESKTOP"; then
				if wait_for_new_shortcut waydroid-test "$SHORTCUT_MATCH_COUNT"; then
					shortcut_reconcile_args=(
						reconcile waydroid-test
						--artwork-dir "$WORKING_DIR/extras/icons/waydroid-test"
					)
					shortcut_reconcile_args+=(--keep-duplicates)
					python3 "$WORKING_DIR/extras/icon.py" "${shortcut_reconcile_args[@]}" ||
						echo "Warning: Waydroid Test artwork could not be installed." >&2
				else
					echo "Warning: Steam did not create the Waydroid Test shortcut within 45 seconds." >&2
				fi
			else
				echo "Warning: Waydroid Test shortcut could not be created." >&2
			fi
			rm -f "$TMP_TEST_DESKTOP"
		fi
	fi

	if shortcut_should_be_created nested-desktop "Nested Desktop"; then
		if steamos-add-to-steam /usr/bin/steamos-nested-desktop &>/dev/null; then
			if wait_for_new_shortcut nested-desktop "$SHORTCUT_MATCH_COUNT"; then
				shortcut_reconcile_args=(
					reconcile nested-desktop
					--artwork-dir "$WORKING_DIR/extras/icons/nested-desktop"
				)
				shortcut_reconcile_args+=(--keep-duplicates)
				python3 "$WORKING_DIR/extras/icon.py" "${shortcut_reconcile_args[@]}" ||
					echo "Warning: Nested Desktop artwork could not be installed." >&2
			else
				echo "Warning: Steam did not create the Nested Desktop shortcut within 45 seconds." >&2
			fi
		else
			echo "Warning: Nested Desktop shortcut could not be created." >&2
		fi
	fi
}

# The bundle is present and verified; only now request sudo and stop Decky.
if ! run_privileged_sanity_checks; then
	exit 1
fi
if [ "${DECKY_LOADER_STOPPED:-false}" = true ]; then
	trap restore_decky_loader EXIT
	trap 'exit 130' HUP INT TERM
fi
if [ "$TEST_INSTALL_MODE" = true ]; then
	trap test_install_exit_cleanup EXIT
	trap 'exit 130' HUP INT TERM
	# Close the race between the early read-only check and privileged work.
	ensure_waydroid_runtime_inactive_for_test_install || exit 1
fi

# sanity checks are all good. lets go!
if [ "$REPAIR_MODE" = true ]; then
	repair_exit_cleanup() {
		trap - EXIT HUP INT TERM
		# shellcheck disable=SC2154
		echo -e "$current_password\n" | sudo -S systemctl stop waydroid-container.service &>/dev/null || true
		unmount_waydroid_var "$WAYDROID_IMAGE"
		# shellcheck disable=SC2154
		echo -e "$current_password\n" | sudo -S steamos-readonly enable &>/dev/null || true
	}
	trap repair_exit_cleanup EXIT
	trap 'exit 130' HUP INT TERM
	# An interrupted prior session must not leave the persistent image busy while
	# packages and root-owned integration are restored.
	echo -e "$current_password\n" | sudo -S systemctl stop waydroid-container.service &>/dev/null || true
	unmount_waydroid_var "$WAYDROID_IMAGE"
	if ! validate_existing_android_image; then
		echo Repair stopped before changing SteamOS host integration. >&2
		exit 1
	fi
elif [ "$REINSTALL_ANDROID_MODE" = true ] && [ "$ANDROID_REINSTALL_HAS_EXISTING" = true ]; then
	trap reinstall_exit_cleanup EXIT
	trap 'exit 130' HUP INT TERM
	if ! archive_existing_android_state; then
		echo Android reinstallation stopped before replacing the existing Android state. >&2
		exit 1
	fi
fi

# Android modification tooling is needed only for a new installation.
if [ "$REPAIR_MODE" != true ]; then
	echo Cloning casualsnek / aleasto waydroid_script repo.
	echo This can take a few minutes depending on the speed of the internet connection and if github is having issues.
	echo If the git clone is slow - cancel the script \(CTL-C\) and run it again.

	if git clone --depth=1 "$WAYDROID_SCRIPT" "$WAYDROID_SCRIPT_DIR" &>/dev/null; then
		echo Repo has been successfully cloned! Proceed to the next step.
	else
		echo Error cloning the casualsnek / aleasto waydroid_script repo!
		rm -rf "$WAYDROID_SCRIPT_DIR"
		abort_run
	fi
fi

# unlock the readonly and initialize keyring using the devmode method
echo Unlocking SteamOS and initializing keyring via steamos-devmode. This can take a while.
echo "*** steamos-devmode ***" >"$LOGFILE"

if { printf '%s\n' "$current_password" |
	sudo -S steamos-devmode enable --no-prompt; } >>"$LOGFILE" 2>&1; then
	echo pacman keyring has been initialized!
else
	echo Error initializing keyring!
	abort_run
fi

# Install the target-built Waydroid host package set from the verified bundle.
# SteamOS targets with Binder built into the kernel do not carry a Binder
# package. Targets without Binder carry exactly one steamos-waydroid-binder
# package containing the binder_linux module built for that target kernel.
echo Installing waydroid packages. This can take a while.
echo "*** pacman install waydroid packages ***" >>"$LOGFILE"
cd "$WORKING_DIR" || abort_run

host_packages=(
	"$HOST_PACKAGE_ROOT"/libglibutil*.zst
	"$HOST_PACKAGE_ROOT"/libgbinder*.zst
	"$HOST_PACKAGE_ROOT"/python-gbinder*.zst
	"$HOST_PACKAGE_ROOT"/waydroid*.zst
)

binder_package_installed=false

if [ "$binder_builtin" = true ]; then
	if [ "${#binder_packages[@]}" -eq 1 ]; then
		echo "Skipping bundled Binder package because kernel $running_kernel_release provides Binder itself."
	else
		echo "Using built-in Binder support from kernel $running_kernel_release."
	fi
else
	echo "Installing bundled Binder module for kernel $binder_package_kernel."
	host_packages+=("${binder_packages[0]}")
	binder_package_installed=true
fi

echo Resolving package dependencies against the configured SteamOS repositories.
echo "*** pacman dependency transaction preflight ***" >>"$LOGFILE"
if ! verify_pacman_transaction_dependencies "${host_packages[@]}" >>"$LOGFILE" 2>&1; then
	echo Pacman could not resolve a complete package transaction. >&2
	echo Review the preflight details in: "$LOGFILE" >&2
	abort_run
fi

if { printf '%s\n' "$current_password" |
	sudo -S pacman -U --noconfirm "${host_packages[@]}"; } >>"$LOGFILE" 2>&1; then
	echo Waydroid has been installed!

	if [ "$binder_package_installed" = true ]; then
		echo Registering the bundled Binder kernel module.
		echo "*** depmod binder_linux ***" >>"$LOGFILE"

		if ! { printf '%s\n' "$current_password" |
			sudo -S depmod -a "$running_kernel_release"; } >>"$LOGFILE" 2>&1; then
			echo Error running depmod for the bundled Binder kernel module. >&2
			abort_run
		fi

		if ! modinfo -k "$running_kernel_release" binder_linux >>"$LOGFILE" 2>&1; then
			echo The bundled binder_linux module was installed but cannot be found by modinfo. >&2
			abort_run
		fi

		echo "Binder module registered: $(modinfo -k "$running_kernel_release" -F filename binder_linux)"
	fi

	printf '%s\n' "$current_password" |
		sudo -S systemctl disable waydroid-container.service
else
	echo Error installing waydroid. Run the script again to install waydroid.
	abort_run
fi
# Configure only the four trusted-zone settings used by Waydroid. Runtime and
# permanent ownership are tracked independently, and a failed transaction
# removes only settings which this run added.
firewalld_was_active=false
if systemctl is-active --quiet firewalld.service; then
	firewalld_was_active=true
fi
firewall_sudo() {
	printf '%s\n' "$current_password" | sudo -S "$@"
}
if ! configure_firewall_rules \
	"$FIREWALL_OWNERSHIP_FILE" \
	"$firewalld_was_active" \
	"$LOGFILE" \
	firewall_sudo; then
	echo Failed to configure only the required Waydroid firewall settings. >&2
	abort_run
fi
unset -f firewall_sudo

# Recreate user-side host integration in both fresh-install and repair modes.
# These files live outside the Android image and are safe to refresh.
mkdir -p ~/Android_Waydroid/config &>/dev/null

# waydroid startup and shutdown scripts
echo -e "$current_password\n" | sudo -S cp extras/scripts/waydroid-startup-scripts /usr/bin/waydroid-startup-scripts
echo -e "$current_password\n" | sudo -S cp extras/scripts/waydroid-shutdown-scripts /usr/bin/waydroid-shutdown-scripts
echo -e "$current_password\n" | sudo -S cp extras/scripts/waydroid-controller-hotplug /usr/bin/waydroid-controller-hotplug
echo -e "$current_password\n" | sudo -S cp extras/scripts/waydroid-mount /usr/bin/waydroid-mount
echo -e "$current_password\n" | sudo -S cp extras/scripts/waydroid-firewall /usr/bin/waydroid-firewall
echo -e "$current_password\n" | sudo -S mkdir -p /usr/lib/steamos-waydroid
echo -e "$current_password\n" | sudo -S cp \
	libexec/steamos-waydroid/shared-folder.sh \
	libexec/steamos-waydroid/waydroid-profile.sh \
	/usr/lib/steamos-waydroid/
echo -e "$current_password\n" | sudo -S chmod +x /usr/bin/waydroid-startup-scripts /usr/bin/waydroid-shutdown-scripts /usr/bin/waydroid-controller-hotplug /usr/bin/waydroid-mount /usr/bin/waydroid-firewall

# custom sudoers file do not ask for sudo for the custom waydroid scripts
echo -e "$current_password\n" | sudo -S visudo -cf extras/zzzzzzzz-waydroid >/dev/null || abort_run
echo -e "$current_password\n" | sudo -S install -o root -g root -m 0440 \
	extras/zzzzzzzz-waydroid /etc/sudoers.d/zzzzzzzz-waydroid
echo -e "$current_password\n" | sudo -S systemctl daemon-reload

# Copy Waydroid launcher dependencies.
cp extras/scripts/Android_Waydroid_Cage.sh extras/scripts/Android_Waydroid_Test_Cage.sh \
	extras/scripts/Waydroid-Toolbox.sh \
	extras/scripts/Waydroid-Updater.sh extras/scripts/select-bundle ~/Android_Waydroid
# Toolbox delegates destructive reset operations back to this checkout so the
# protected canonical uninstaller owns image preservation and confirmation.
if ! printf '%s\n' "$WORKING_DIR" >~/Android_Waydroid/installer-root ||
	! chmod 0600 ~/Android_Waydroid/installer-root; then
	echo Failed to record the installer checkout for Waydroid Toolbox. >&2
	abort_run
fi
# Remove the pre-public helper name after installing its neutral replacement.
rm -f ~/Android_Waydroid/select-private-bundle
for config_file in fake_wifi fake_touch; do
	if [ "$REPAIR_MODE" != true ] || [ ! -e "$HOME/Android_Waydroid/config/$config_file" ]; then
		cp "extras/config/$config_file" ~/Android_Waydroid/config
	fi
done
cp extras/icon.py ~/Android_Waydroid/steam-shortcuts.py
mkdir -p ~/Android_Waydroid/icons
cp -a extras/icons/. ~/Android_Waydroid/icons/

# Waydroid launcher, toolbox and updater.
chmod +x ~/Android_Waydroid/*.sh ~/Android_Waydroid/select-bundle

# Dolphin File Manager extension for root access.
mkdir -p ~/.local/share/kio/servicemenus
cp extras/open_as_root.desktop ~/.local/share/kio/servicemenus
chmod +x ~/.local/share/kio/servicemenus/open_as_root.desktop

# Desktop shortcuts for toolbox + updater.
ln -sfn ~/Android_Waydroid/Waydroid-Toolbox.sh ~/Desktop/Waydroid-Toolbox &>/dev/null
ln -sfn ~/Android_Waydroid/Waydroid-Updater.sh ~/Desktop/Waydroid-Updater &>/dev/null

sudo mkdir -p /var/lib/waydroid
if [ "$REPAIR_MODE" = true ]; then
	echo Mounting the validated Android image read-only for repair verification.
	ROOTDEV=$(sudo losetup --find --show "$WAYDROID_IMAGE")
	if ! sudo mount -o ro,noload "$ROOTDEV" /var/lib/waydroid; then
		echo Error mounting the existing Android image. >&2
		abort_run
	fi
else
	if [ "$TEST_INSTALL_MODE" = true ]; then
		ensure_waydroid_runtime_inactive_for_test_install || abort_run
	fi
	if [ -e "$WAYDROID_IMAGE" ] || [ -L "$WAYDROID_IMAGE" ]; then
		echo Refusing to initialize Android while an unhandled image exists: "$WAYDROID_IMAGE" >&2
		abort_run
	fi
	echo Preparing a new persistent Android image.
	if ! mount_waydroid_var; then
		echo Error creating the new Android image. >&2
		abort_run
	fi
fi

if [ "$REPAIR_MODE" = true ]; then
	if [ ! -s /var/lib/waydroid/waydroid_base.prop ]; then
		echo The persistent image mounted, but waydroid_base.prop is missing. >&2
		echo Repair stopped without initializing or modifying Android. >&2
		abort_run
	fi

	echo Restoring the custom-image integration.
	echo -e "$current_password\n" | sudo -S mkdir -p /etc/waydroid-extra
	if [ -L /etc/waydroid-extra/images ]; then
		if [ "$(readlink /etc/waydroid-extra/images)" != /var/lib/waydroid/custom ]; then
			echo /etc/waydroid-extra/images points to an unexpected location. >&2
			echo Repair will not overwrite it. >&2
			abort_run
		fi
	elif [ -e /etc/waydroid-extra/images ]; then
		echo /etc/waydroid-extra/images exists and is not the expected symlink. >&2
		echo Repair will not overwrite it. >&2
		abort_run
	else
		echo -e "$current_password\n" | sudo -S ln -s /var/lib/waydroid/custom /etc/waydroid-extra/images
	fi

	echo Verifying repaired host integration.
	for required_file in \
		/usr/bin/waydroid \
		/usr/bin/waydroid-startup-scripts \
		/usr/bin/waydroid-shutdown-scripts \
		/usr/bin/waydroid-controller-hotplug \
		/usr/bin/waydroid-mount \
		/usr/bin/waydroid-firewall \
		/usr/lib/steamos-waydroid/shared-folder.sh \
		/usr/lib/steamos-waydroid/waydroid-profile.sh \
		/usr/lib/systemd/system/waydroid-container.service \
		/etc/sudoers.d/zzzzzzzz-waydroid; do
		if [ ! -e "$required_file" ]; then
			echo "Repair verification failed: $required_file is missing." >&2
			abort_run
		fi
	done
	if ! python3 -c 'import gbinder' &>/dev/null; then
		echo Repair verification failed: python-gbinder cannot be imported. >&2
		abort_run
	fi
	if ldd /usr/lib/libgbinder.so.1 2>/dev/null | grep -q 'not found'; then
		echo Repair verification failed: libgbinder has an unresolved dependency. >&2
		abort_run
	fi
	echo -e "$current_password\n" | sudo -S visudo -cf /etc/sudoers.d/zzzzzzzz-waydroid >/dev/null || abort_run

	echo Unmounting the persistent Android image after verification.
	echo -e "$current_password\n" | sudo -S systemctl stop waydroid-container.service &>/dev/null || true
	unmount_waydroid_var "$WAYDROID_IMAGE"
	echo -e "$current_password\n" | sudo -S steamos-readonly enable
	trap - EXIT HUP INT TERM
	echo Waydroid host integration has been repaired. Android data was not reinitialized or modified.
	ensure_game_mode_shortcuts
	prompt_return_to_gaming_mode
	exit 0
fi

echo Downloading waydroid image from sourceforge.
echo This can take a few seconds to a few minutes depending on the internet connection and the speed of the sourceforge mirror.
echo Sometimes it connects to a slow sourceforge mirror and the downloads are slow -. This is beyond my control!
echo If the downloads are slow due to a slow sourceforge mirror - cancel the script \(CTL-C\) and run it again.

# place custom overlay files here - key layout, hosts, audio.rc etc etc
# copy fixed key layout for Steam Controller
echo -e "$current_password\n" | sudo -S mkdir -p /var/lib/waydroid/overlay/system/usr/keylayout
echo -e "$current_password\n" | sudo -S cp extras/fixes/Vendor_28de_Product_11ff.kl /var/lib/waydroid/overlay/system/usr/keylayout/

# copy custom audio.rc patch to lower the audio latency
echo -e "$current_password\n" | sudo -S mkdir -p /var/lib/waydroid/overlay/system/etc/init
echo -e "$current_password\n" | sudo -S cp extras/fixes/audio.rc /var/lib/waydroid/overlay/system/etc/init/

# download custom hosts file from StevenBlack to block ads (adware + malware + fakenews + gambling + pr0n)
echo -e "$current_password\n" | sudo -S wget https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/fakenews-gambling-porn/hosts \
	-O /var/lib/waydroid/overlay/system/etc/hosts

if [ "$TEST_INSTALL_MODE" = true ]; then
	Android_Choice=$(zenity --width 1040 --height 480 --list --radiolist \
		--title "Install Waydroid Test - choose one Android image" \
		--column "Select One" \
		--column "ID" \
		--column "Option" \
		--column "Description" \
		--hide-column=2 --print-column=2 \
		TRUE A13_GAPPS "Android 13 — GApps" "Stable / standard Waydroid image" \
		FALSE A13_NO_GAPPS "Android 13 — Vanilla" "Stable / standard Waydroid image" \
		FALSE A16_GAPPS "Android 16 — GApps (Experimental)" "Latest test platform" \
		FALSE A16_NO_GAPPS "Android 16 — Vanilla (Experimental)" "Latest test platform" \
		FALSE TV16_GAPPS "Android TV 16 — GApps (Experimental)" "Latest Android TV test platform" \
		FALSE TV16_NO_GAPPS "Android TV 16 — Vanilla (Experimental)" "Latest Android TV test platform" \
		FALSE EXIT "Exit" "Exit this installer")
else
	Android_Choice=$(zenity --width 1040 --height 320 --list --radiolist --multiple \
		--title "SteamOS Waydroid Bundle  - https://github.com/pjohno/steamos-waydroid-bundle" \
		--column "Select One" \
		--column "Option" \
		--column="Description - Read this carefully!" \
		TRUE A13_GAPPS "Download official Android 13 image with Google Play Store." \
		FALSE A13_NO_GAPPS "Download official Android 13 image without Google Play Store." \
		FALSE TV13_GAPPS "Download unofficial Android 13 TV image with Google Play Store - thanks SupeChicken666 for the image!" \
		FALSE TV13_NO_GAPPS "Download unofficial Android 13 TV image without Google Play Store - thanks SupeChicken666 for the image!" \
		FALSE EXIT "***** Exit this script *****")
fi

if [ $? -eq 1 ] || [ "$Android_Choice" == "EXIT" ]; then
	echo User pressed CANCEL / EXIT. Goodbye!
	if [ "$TEST_INSTALL_MODE" = true ]; then
		cleanup_failed_test_environment
		exit 1
	fi
	cleanup_exit
fi

if ! set_android_image_selection "$Android_Choice"; then
	abort_run
elif [ "$Android_Choice" == "A13_GAPPS" ]; then
	echo Initializing Waydroid.
	echo -e "$current_password\n" | run_profile_sudo waydroid init -s GAPPS
	check_waydroid_init

elif [ "$Android_Choice" == "A13_NO_GAPPS" ]; then
	echo Initializing Waydroid.
	echo -e "$current_password\n" | run_profile_sudo waydroid init
	check_waydroid_init

elif [ "$Android_Choice" == "TV13_GAPPS" ]; then
	echo Initializing Waydroid.
	echo -e "$current_password\n" | run_profile_sudo waydroid init -c ${ANDROID13_TV_OTA}/system -v ${ANDROID13_TV_OTA}/vendor -s GAPPS
	check_waydroid_init

elif [ "$Android_Choice" == "TV13_NO_GAPPS" ]; then
	echo Initializing Waydroid.
	echo -e "$current_password\n" | run_profile_sudo waydroid init -c ${ANDROID13_TV_OTA}/system -v ${ANDROID13_TV_OTA}/vendor
	check_waydroid_init

elif [ "$ANDROID_VERSION" = 16 ]; then
	if ! install_experimental_android_image; then
		echo "Android $ANDROID_VERSION $ANDROID_VARIANT installation failed; no fallback image was installed." >&2
		abort_run
	fi
fi

# run casualsnek / aleasto waydroid_script
echo Install $ARM_Choice widevine and fingerprint spoof.
if [ "$Android_Choice" == "TV13_GAPPS" ] || [ "$Android_Choice" == "TV13_NO_GAPPS" ]; then
	echo No need for casualsnek / aleasto waydroid_script for TV13 images.
	echo TV13 images already contains libhoudini arm translation layer and widevine.
elif [ "$ANDROID_VERSION" = 16 ]; then
	echo "Skipping the Android-13-specific waydroid_script ARM/Widevine modification for Android $ANDROID_VERSION."
	echo "The experimental image's built-in ARM support is retained; Widevine is not modified."
	rm -rf -- "$WAYDROID_SCRIPT_DIR"
else
	if ! install_android_extras; then
		echo "Android extras installation failed; the incomplete installation will be cleaned up." >&2
		abort_run
	fi
fi

# apply custom config for controller detection, root and fingerprint spoof
apply_android_custom_config

# change GPU rendering to use minigbm_gbm_mesa
echo -e "$current_password\n" | sudo -S sed -i "s/ro.hardware.gralloc=.*/ro.hardware.gralloc=minigbm_gbm_mesa/g" /var/lib/waydroid/waydroid_base.prop

# all done lets re-enable the readonly
echo -e "$current_password\n" | sudo -S steamos-readonly enable
echo Waydroid has been successfully installed!

# unmount the custom /var/lib/waydroid
echo Unmounting the custom /var/lib/waydroid
echo -e "$current_password\n" | sudo systemctl stop waydroid-container.service
unmount_waydroid_var
if ! commit_new_android_image extras/waydroid.img; then
	echo Failed to activate the newly initialized Android image. >&2
	abort_run
fi
ANDROID_REINSTALL_COMMITTED=true
if [ "$TEST_INSTALL_MODE" = true ]; then
	if ! record_test_android_metadata; then
		echo Failed to record the Waydroid Test Android version metadata. >&2
		abort_run
	fi
	TEST_INSTALL_COMMITTED=true
	echo Waydroid Test has been successfully installed without modifying the normal Android environment.
fi
if [ -n "${ARCHIVED_ANDROID_IMAGE:-}" ] && [ -f "$ARCHIVED_ANDROID_IMAGE" ]; then
	printf 'The previous Android image remains archived at: %s\n' "$ARCHIVED_ANDROID_IMAGE"
fi
if [ -n "${ARCHIVED_ANDROID_USER_STATE:-}" ] &&
	{ [ -e "$ARCHIVED_ANDROID_USER_STATE" ] || [ -L "$ARCHIVED_ANDROID_USER_STATE" ]; }; then
	printf 'The previous Android user data remains archived at: %s\n' "$ARCHIVED_ANDROID_USER_STATE"
fi
if [ -n "${ARCHIVED_ANDROID_LEGACY_USER_STATE:-}" ] &&
	{ [ -e "$ARCHIVED_ANDROID_LEGACY_USER_STATE" ] || [ -L "$ARCHIVED_ANDROID_LEGACY_USER_STATE" ]; }; then
	printf 'The previous legacy Android user data remains archived at: %s\n' "$ARCHIVED_ANDROID_LEGACY_USER_STATE"
fi

ensure_game_mode_shortcuts

# If this run stopped Decky, offer to restart it before possibly ending the
# Desktop Mode session. The EXIT trap remains as a retry after a start failure.
prompt_restore_decky_loader || true

# all done! Display dialog box for Gaming Mode
prompt_return_to_gaming_mode
