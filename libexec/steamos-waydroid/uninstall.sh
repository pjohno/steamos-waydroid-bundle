#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# Uninstall remains scoped to the existing main installation in stage 1.
# shellcheck source=waydroid-profile.sh
source "$SCRIPT_DIR/waydroid-profile.sh"
resolve_waydroid_profile main || exit $?
ANDROID_HOME=${WAYDROID_IMAGE%/*}
ANDROID_IMAGE=$WAYDROID_IMAGE
WAYDROID_SHARE_TARGET="$WAYDROID_DATA/media/0/Waydroid Share"
resolve_waydroid_profile test || exit $?
WAYDROID_TEST_HOME=${WAYDROID_IMAGE%/*}
resolve_waydroid_profile main || exit $?
WAYDROID_LEGACY_USER_STATE="$HOME/waydroid"
STATE_ROOT="${XDG_STATE_HOME:-$HOME/.local/state}/steamos-waydroid"
PRESERVATION_CANDIDATE="${XDG_STATE_HOME:-$HOME/.local/state}/steamos-waydroid-preserved-reset"
FIREWALL_OWNERSHIP_FILE="$HOME/.local/share/steamos-waydroid-installer/firewall-ownership.env"
SHORTCUT_MANAGER="$PROJECT_ROOT/extras/icon.py"
READONLY_DISABLED=false
FULL_PROCESS_RESET=false
KEEP_ANDROID_STATE=false
RESET_ARTIFACT_STATE=false
PRESERVATION_ROOT=""
PRESENT_ANDROID_USER_STATE=()
ANDROID_STATE_FILES=()
PRESERVED_ANDROID_FILES=()
MANUAL_SHORTCUT_REMOVAL=false
RESET_LOG=""

if [[ ${1:-} == --full-process ]]; then
	FULL_PROCESS_RESET=true
elif [[ ${1:-} == --keep-android ]]; then
	KEEP_ANDROID_STATE=true
elif [[ ${1:-} == --reset-host-keep-android ]]; then
	KEEP_ANDROID_STATE=true
	RESET_ARTIFACT_STATE=true
elif [[ ${1:-} == --purge-android ]]; then
	:
elif [[ $# -ne 0 ]]; then
	printf 'usage: %s [--full-process | --keep-android | --reset-host-keep-android | --purge-android]\n' "$0" >&2
	exit 1
fi

if [[ ${STEAMOS_WAYDROID_INTERNAL:-} != 1 ]]; then
	printf 'error: run ./steamos-waydroid-installer.sh with a supported reset option\n' >&2
	exit 1
fi

# shellcheck source=firewall-rules.sh
source "$SCRIPT_DIR/firewall-rules.sh"

reset_log() {
	local message="$*"
	local timestamp

	timestamp="$(date --iso-8601=seconds)"
	if [[ -z "$RESET_LOG" ]]; then
		printf '%s RESET %s\n' "$timestamp" "$message" >&2
		return 0
	fi
	if ! printf '%s RESET %s\n' "$timestamp" "$message" | tee -a "$RESET_LOG"; then
		printf 'warning: could not append reset diagnostics to %s\n' "$RESET_LOG" >&2
	fi
	# Closing the append for each line flushes userspace buffers. Ask the kernel
	# to persist the file as well so the last completed stage survives power loss.
	sync -f "$RESET_LOG" 2>/dev/null || sync 2>/dev/null || true
	logger --tag steamos-waydroid-reset -- "RESET $message" 2>/dev/null || true
}

stage_start() {
	reset_log "stage=$1 start${2:+ $2}"
}

stage_complete() {
	reset_log "stage=$1 complete${2:+ $2}"
}

move_android_state() {
	local source_file="$1"
	local destination_file="$2"

	# Both directories are deck-owned. Moving even a root-owned regular file
	# only requires directory permissions and preserves its existing ownership.
	if ! mv -- "$source_file" "$destination_file"; then
		printf 'error: could not move Android state without elevated privileges: %s\n' \
			"$source_file" >&2
		return 1
	fi
}

restore_readonly() {
	if [[ "$READONLY_DISABLED" == true ]]; then
		printf '\nRe-enabling the SteamOS read-only filesystem...\n'
		if sudo steamos-readonly enable; then
			READONLY_DISABLED=false
		else
			reset_log "stage=readonly-enable failed"
		fi
	fi
}

restore_android_files() {
	local index preserved_file destination_file

	[[ "$KEEP_ANDROID_STATE" == true ]] || return 0
	((${#PRESERVED_ANDROID_FILES[@]} > 0)) || return 0

	for index in "${!PRESERVED_ANDROID_FILES[@]}"; do
		preserved_file=${PRESERVED_ANDROID_FILES[$index]}
		destination_file=${ANDROID_STATE_FILES[$index]}
		if [[ -e "$destination_file" || -L "$destination_file" ]]; then
			printf 'error: refusing to overwrite Android state while restoring it: %s\n' \
				"$destination_file" >&2
			printf 'Preserved Android state remains at: %s\n' "$preserved_file" >&2
			return 1
		fi
	done
	mkdir -p -- "$ANDROID_HOME"
	for index in "${!PRESERVED_ANDROID_FILES[@]}"; do
		preserved_file=${PRESERVED_ANDROID_FILES[$index]}
		destination_file=${ANDROID_STATE_FILES[$index]}
		move_android_state "$preserved_file" "$destination_file"
	done
	rmdir -- "$PRESERVATION_ROOT" 2>/dev/null || true
	PRESERVATION_ROOT=""
	PRESERVED_ANDROID_FILES=()
}

cleanup() {
	local exit_status=$?
	trap - EXIT HUP INT TERM
	if ((exit_status != 0)); then
		reset_log "stage=reset aborted status=$exit_status"
	fi
	if ! restore_android_files; then
		reset_log "stage=restore-android failed preserved=$PRESERVATION_ROOT"
	fi
	restore_readonly
	return "$exit_status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "$(id -un)" != deck ]]; then
	printf 'error: run this script as the deck user, not as root\n' >&2
	exit 1
fi

if [[ ! -r /etc/os-release ]] || ! grep -q '^ID=steamos$' /etc/os-release; then
	printf 'error: this reset script may only be run on SteamOS\n' >&2
	exit 1
fi

mkdir -p -- "$STATE_ROOT"
chmod 0700 "$STATE_ROOT"
RESET_LOG="$STATE_ROOT/reset-$(date -u +%Y%m%dT%H%M%SZ)-$$.log"
: >"$RESET_LOG"
chmod 0600 "$RESET_LOG"
reset_log "stage=preflight start mode=${1:---purge-android}"

if [[ "$KEEP_ANDROID_STATE" == true ]]; then
	if [[ -e "$PRESERVATION_CANDIDATE" || -L "$PRESERVATION_CANDIDATE" ]]; then
		stage_start recover-interrupted-reset
		if [[ ! -d "$PRESERVATION_CANDIDATE" || -L "$PRESERVATION_CANDIDATE" ]]; then
			printf 'error: preservation staging path is not a real directory: %s\n' \
				"$PRESERVATION_CANDIDATE" >&2
			exit 1
		fi
		shopt -s nullglob dotglob
		interrupted_files=("$PRESERVATION_CANDIDATE"/*)
		shopt -u nullglob dotglob
		if ((${#interrupted_files[@]} == 0)); then
			printf 'error: empty preservation staging directory requires manual inspection: %s\n' \
				"$PRESERVATION_CANDIDATE" >&2
			exit 1
		fi
		for preserved_file in "${interrupted_files[@]}"; do
			case "$(basename -- "$preserved_file")" in
			waydroid.img | waydroid.img.pre-reinstall-* | waydroid.img.failed-reinstall-*) ;;
			*)
				printf 'error: unexpected file in preservation staging directory: %s\n' \
					"$preserved_file" >&2
				exit 1
				;;
			esac
			if [[ ! -f "$preserved_file" || -L "$preserved_file" ]]; then
				printf 'error: preserved Android state is not a regular file: %s\n' \
					"$preserved_file" >&2
				exit 1
			fi
			destination_file="$ANDROID_HOME/$(basename -- "$preserved_file")"
			if [[ -e "$destination_file" || -L "$destination_file" ]]; then
				printf 'error: both active and preserved Android state exist; refusing to overwrite either:\n' >&2
				printf '  active:    %s\n  preserved: %s\n' \
					"$destination_file" "$preserved_file" >&2
				exit 1
			fi
		done
		mkdir -p -- "$ANDROID_HOME"
		for preserved_file in "${interrupted_files[@]}"; do
			destination_file="$ANDROID_HOME/$(basename -- "$preserved_file")"
			move_android_state "$preserved_file" "$destination_file"
		done
		rmdir -- "$PRESERVATION_CANDIDATE"
		stage_complete recover-interrupted-reset
	fi

	if [[ (-e "$ANDROID_IMAGE" || -L "$ANDROID_IMAGE") &&
		(! -f "$ANDROID_IMAGE" || -L "$ANDROID_IMAGE") ]]; then
		printf 'error: preservation requires a regular Android image: %s\n' \
			"$ANDROID_IMAGE" >&2
		exit 1
	fi
	shopt -s nullglob
	for android_state_file in \
		"$ANDROID_IMAGE" \
		"$ANDROID_HOME"/waydroid.img.pre-reinstall-* \
		"$ANDROID_HOME"/waydroid.img.failed-reinstall-*; do
		if [[ -L "$android_state_file" ]]; then
			printf 'error: preservation refuses a symlinked Android state file: %s\n' \
				"$android_state_file" >&2
			exit 1
		fi
		if [[ -f "$android_state_file" ]]; then
			ANDROID_STATE_FILES+=("$android_state_file")
		fi
	done
	shopt -u nullglob
	if ((${#ANDROID_STATE_FILES[@]} > 0)); then
		preservation_candidate="$PRESERVATION_CANDIDATE"
		if [[ -e "$preservation_candidate" || -L "$preservation_candidate" ]]; then
			printf 'error: preservation staging path already exists: %s\n' \
				"$preservation_candidate" >&2
			printf 'Inspect or recover it before retrying this reset.\n' >&2
			exit 1
		fi
	fi
	for user_state_path in "$WAYDROID_USER_STATE" "$WAYDROID_LEGACY_USER_STATE"; do
		if [[ -e "$user_state_path" || -L "$user_state_path" ]]; then
			if [[ ! -d "$user_state_path" ]]; then
				printf 'error: Android user state is not a directory: %s\n' \
					"$user_state_path" >&2
				exit 1
			fi
			PRESENT_ANDROID_USER_STATE+=("$user_state_path")
		fi
	done
	if [[ -f "$ANDROID_IMAGE" && ${#PRESENT_ANDROID_USER_STATE[@]} -eq 0 ]]; then
		printf 'error: Android image exists without its matching user-data directory.\n' >&2
		printf 'Refusing to preserve only the image; restore Android user data before retrying.\n' >&2
		exit 1
	fi
	if [[ ! -f "$ANDROID_IMAGE" && ${#PRESENT_ANDROID_USER_STATE[@]} -gt 0 ]]; then
		printf 'error: Android user data exists without its matching persistent image.\n' >&2
		printf 'Restore the Android image before retrying this reset.\n' >&2
		exit 1
	fi
	cat <<'EOF'
This removes installed SteamOS host integration while preserving:
EOF
	if [[ -f "$ANDROID_IMAGE" ]]; then
		printf '  - %s\n' "$ANDROID_IMAGE"
	fi
	printf '  - %s (Android applications, settings and logins)\n' \
		"$WAYDROID_USER_STATE"
	printf '  - %s when present (legacy Android user state)\n' \
		"$WAYDROID_LEGACY_USER_STATE"
	cat <<'EOF'
  - this Git checkout

It removes Android launchers and per-user host integration, Waydroid packages,
and installer-owned system integration. Steam shortcuts are removed when Steam
is closed; otherwise they are left for safe manual removal. The next normal
installer run reuses the preserved Android state, applications and logins.
EOF
	if [[ "$RESET_ARTIFACT_STATE" == true ]]; then
		cat <<'EOF'
Clean host-reset mode also removes installed Cage/wlroots bundles, artifact
configuration, and compatibility reports so artifact setup is exercised again.
EOF
	else
		cat <<'EOF'
The verified target-built bundles and artifact configuration are retained.
EOF
	fi
else
	cat <<'EOF'
This permanently deletes this installer's Waydroid instance, including:
  - Android applications, settings and files
  - Waydroid packages and installer-owned system integration
  - Waydroid and nested-desktop Steam shortcuts and local artwork when Steam
    is closed; otherwise remove them manually afterward

By default it intentionally keeps:
  - this Git checkout
  - ~/.local/opt/steamos-waydroid (the verified target-built bundles)
  - a separately installed Waydroid Test image and user data

These retained prerequisites are required to run the installer again.
EOF
fi

if [[ "$FULL_PROCESS_RESET" == true ]]; then
	cat <<'EOF'

Full-process mode also deletes the Git checkout and target-built bundles so the
Deck-side clone, artifact pull, verification and activation can all be tested.
SSH keys and SSH host configuration are retained.
EOF
fi

expected_confirmation="DELETE ANDROID DATA"
if [[ "$FULL_PROCESS_RESET" == true ]]; then
	expected_confirmation="DELETE EVERYTHING"
elif [[ "$RESET_ARTIFACT_STATE" == true ]]; then
	expected_confirmation="RESET HOST KEEP ANDROID"
elif [[ "$KEEP_ANDROID_STATE" == true ]]; then
	expected_confirmation="UNINSTALL HOST KEEP ANDROID"
fi
read -r -p "Type $expected_confirmation to continue: " confirmation
if [[ "$confirmation" != "$expected_confirmation" ]]; then
	printf 'Reset cancelled.\n'
	exit 0
fi

sudo -v

stage_complete preflight

stage_start stop-waydroid
printf 'Stopping Waydroid and detaching its private image...\n'
if [[ -x /usr/bin/waydroid-controller-hotplug ]]; then
	sudo /usr/bin/waydroid-controller-hotplug --stop main || true
	sudo /usr/bin/waydroid-controller-hotplug --stop test || true
fi
if ! unit_load_state="$(
	systemctl show -p LoadState --value waydroid-container.service 2>/dev/null
)"; then
	printf 'error: could not determine the state of waydroid-container.service\n' >&2
	exit 1
fi
if [[ -n "$unit_load_state" && "$unit_load_state" != not-found ]]; then
	if ! sudo systemctl stop waydroid-container.service; then
		printf 'error: failed to stop waydroid-container.service\n' >&2
		exit 1
	fi
	if systemctl is-active --quiet waydroid-container.service; then
		printf 'error: waydroid-container.service is still active\n' >&2
		exit 1
	fi
fi

remaining_waydroid_processes="$(
	pgrep -ax waydroid 2>/dev/null || true
	pgrep -ax waydroid-container 2>/dev/null || true
	pgrep -af '(^|/)(waydroid|waydroid-container)([[:space:]]|$)' 2>/dev/null || true
)"
if [[ -n "$remaining_waydroid_processes" ]]; then
	printf 'error: Waydroid processes remain after service shutdown:\n%s\n' \
		"$remaining_waydroid_processes" >&2
	exit 1
fi

# Unmount this explicitly before any Android-state cleanup. Otherwise a purge
# could traverse the bind target and delete files from ~/Waydroid Share.
if findmnt --mountpoint "$WAYDROID_SHARE_TARGET" >/dev/null 2>&1; then
	sudo umount "$WAYDROID_SHARE_TARGET"
fi
if findmnt --mountpoint "$WAYDROID_SHARE_TARGET" >/dev/null 2>&1; then
	printf 'error: Waydroid shared folder is still mounted; reset stopped: %s\n' \
		"$WAYDROID_SHARE_TARGET" >&2
	exit 1
fi

if findmnt -rn -o TARGET | grep -Eq '^/var/lib/waydroid(/|$)'; then
	sudo umount -R /var/lib/waydroid
fi
if [[ -f "$ANDROID_IMAGE" ]]; then
	while IFS=: read -r loop_device _; do
		if [[ "$loop_device" == /dev/loop* ]]; then
			sudo losetup -d "$loop_device"
		fi
	done < <(sudo losetup -j "$ANDROID_IMAGE")
fi

# Waydroid normally bind-mounts the host-side Android data directory below
# /var/lib/waydroid/data. Never let the later directory cleanup traverse that
# data if container shutdown left a nested mount behind.
if findmnt -rn -o TARGET | grep -Eq '^/var/lib/waydroid(/|$)'; then
	printf 'error: a Waydroid mount is still active below /var/lib/waydroid; reset stopped\n' >&2
	findmnt -R /var/lib/waydroid >&2 || true
	exit 1
fi

if [[ "$KEEP_ANDROID_STATE" == true && ${#ANDROID_STATE_FILES[@]} -gt 0 ]]; then
	for android_state_file in "${ANDROID_STATE_FILES[@]}"; do
		if sudo losetup -j "$android_state_file" | grep -q .; then
			printf 'error: Android state is still attached; preservation stopped: %s\n' \
				"$android_state_file" >&2
			exit 1
		fi
	done
	stage_complete stop-waydroid

	stage_start preserve-image
	printf 'Moving Android image state aside during host cleanup...\n'
	PRESERVATION_ROOT="$PRESERVATION_CANDIDATE"
	mkdir -p -- "$(dirname -- "$PRESERVATION_ROOT")"
	mkdir -m 0700 -- "$PRESERVATION_ROOT"
	for android_state_file in "${ANDROID_STATE_FILES[@]}"; do
		preserved_file="$PRESERVATION_ROOT/$(basename -- "$android_state_file")"
		move_android_state "$android_state_file" "$preserved_file"
		PRESERVED_ANDROID_FILES+=("$preserved_file")
	done
	stage_complete preserve-image
else
	stage_complete stop-waydroid
fi

if pgrep -x steam >/dev/null; then
	MANUAL_SHORTCUT_REMOVAL=true
	cat >&2 <<'EOF'
WARNING: Steam is running, so its shortcuts database will not be modified.
The Waydroid or Nested Desktop shortcut and artwork may remain after cleanup.
Remove any remaining entry manually from Steam in Gaming Mode.
EOF
else
	printf 'Removing Steam shortcuts and their local artwork...\n'
	shortcut_cleanup_failed=false
	/usr/bin/python3 "$SHORTCUT_MANAGER" remove waydroid || shortcut_cleanup_failed=true
	/usr/bin/python3 "$SHORTCUT_MANAGER" remove nested-desktop || shortcut_cleanup_failed=true
	if [[ "$shortcut_cleanup_failed" == true ]]; then
		MANUAL_SHORTCUT_REMOVAL=true
		cat >&2 <<'EOF'
WARNING: Steam shortcut cleanup was incomplete, but uninstall will continue.
Remove any remaining Waydroid or Nested Desktop entry manually from Steam.
EOF
	fi
fi

stage_start firewall-cleanup
printf 'Removing firewall settings proven to be owned by this installer...\n'
if systemctl is-active --quiet firewalld.service; then
	firewall_mode=active
	firewall_command=(sudo firewall-cmd)
else
	firewall_mode=inactive
	firewall_command=(sudo firewall-offline-cmd)
fi
if ! "${firewall_command[@]}" --check-config; then
	printf 'error: permanent firewalld configuration is invalid; refusing to modify it\n' >&2
	exit 1
fi

if load_firewall_ownership "$FIREWALL_OWNERSHIP_FILE"; then
	for firewall_rule in "${FIREWALL_RULE_KEYS[@]}"; do
		if [[ "$firewall_mode" == active ]] &&
			firewall_rule_is_owned runtime "$firewall_rule"; then
			if firewall_rule_command query "$firewall_rule" \
				"${firewall_command[@]}" >/dev/null 2>&1; then
				firewall_rule_command remove "$firewall_rule" \
					"${firewall_command[@]}"
			else
				firewall_query_status=$?
				if ((firewall_query_status != 1)); then
					printf 'error: could not query runtime firewall rule: %s\n' \
						"$firewall_rule" >&2
					exit 1
				fi
			fi
		fi

		firewall_rule_is_owned permanent "$firewall_rule" || continue
		if [[ "$firewall_mode" == active ]]; then
			permanent_command=(sudo firewall-cmd --permanent)
		else
			permanent_command=("${firewall_command[@]}")
		fi

		if firewall_rule_command query "$firewall_rule" \
			"${permanent_command[@]}" >/dev/null 2>&1; then
			firewall_rule_command remove "$firewall_rule" \
				"${permanent_command[@]}"
		else
			firewall_query_status=$?
			if ((firewall_query_status != 1)); then
				printf 'error: could not query permanent firewall rule: %s\n' \
					"$firewall_rule" >&2
				exit 1
			fi
		fi
	done

	if ! "${firewall_command[@]}" --check-config; then
		printf 'error: firewalld configuration failed validation after targeted cleanup\n' >&2
		exit 1
	fi
	rm -f -- "$FIREWALL_OWNERSHIP_FILE"
	stage_complete firewall-cleanup "service=$firewall_mode"
else
	ownership_status=$?
	if ((ownership_status == 2)); then
		printf 'error: invalid firewall ownership record; refusing firewall cleanup: %s\n' \
			"$FIREWALL_OWNERSHIP_FILE" >&2
		exit 1
	fi
	printf 'WARNING: no firewall ownership record exists; leaving trusted-zone settings unchanged.\n' >&2
	reset_log "stage=firewall-cleanup skipped reason=ownership-unknown service=$firewall_mode"
fi

printf 'Unlocking SteamOS for package and system-file cleanup...\n'
stage_start readonly-disable
sudo steamos-readonly disable
READONLY_DISABLED=true
usr_mount_options="$(findmnt -rn -T /usr -o OPTIONS)"
if [[ ",$usr_mount_options," != *,rw,* ]] || ! sudo test -w /usr; then
	printf 'error: SteamOS /usr is not writable after steamos-readonly disable\n' >&2
	exit 1
fi
stage_complete readonly-disable

# Remove both the current prebuilt Binder package and the legacy DKMS package.
# The kernel module itself is named binder_linux. Older SteamOS targets with
# Binder built into the kernel do not install either of these packages.
binder_package_installed=false
for binder_package in steamos-waydroid-binder binder_linux-dkms; do
	if pacman -Qq "$binder_package" >/dev/null 2>&1; then
		binder_package_installed=true
		break
	fi
done

# Do not unload binder_linux from the running kernel during reset. The module
# remains resident safely after its on-disk package is removed and disappears
# at the next ordinary boot. Live unloading adds kernel risk and is unnecessary
# for host cleanup.
if [[ "$binder_package_installed" == true ]] && lsmod | awk '$1 == "binder_linux" {found=1} END {exit !found}'; then
	printf 'Leaving binder_linux loaded in the running kernel until the next ordinary boot.\n'
	reset_log "stage=binder-live-state retained"
fi

for package in waydroid python-gbinder libgbinder libglibutil steamos-waydroid-binder binder_linux-dkms; do
	if pacman -Qq "$package" >/dev/null 2>&1; then
		stage_start remove-package "package=$package"
		# These are the installer-owned packages, listed in dependency-safe order.
		# Do not use -s: a targeted reset must not remove unrelated dependencies
		# merely because pacman now considers them unneeded.
		if ! sudo pacman -R --noconfirm "$package"; then
			printf 'error: package removal failed: %s\n' "$package" >&2
			exit 1
		fi
		if pacman -Qq "$package" >/dev/null 2>&1; then
			printf 'error: package remains installed after removal: %s\n' "$package" >&2
			exit 1
		fi
		stage_complete remove-package "package=$package"
	fi
done

# Refresh the module dependency/index files after removing an out-of-tree
# Binder package so modprobe cannot resolve a stale binder_linux entry.
if [[ "$binder_package_installed" == true ]]; then
	stage_start refresh-module-index
	printf 'Refreshing kernel module indexes...\n'
	sudo depmod -a "$(uname -r)"
	stage_complete refresh-module-index
fi

stage_start remove-system-files
sudo rm -f -- \
	/etc/sudoers.d/zzzzzzzz-waydroid \
	/etc/modules-load.d/waydroid.conf \
	/etc/modules-load.d/waydroid_binder.conf \
	/etc/modprobe.d/waydroid_binder.conf \
	/usr/bin/waydroid-startup-scripts \
	/usr/bin/waydroid-shutdown-scripts \
	/usr/bin/waydroid-controller-hotplug \
	/usr/bin/waydroid-mount \
	/usr/bin/waydroid-firewall
sudo rm -rf -- \
	/var/lib/waydroid \
	/usr/lib/waydroid \
	/usr/lib/steamos-waydroid \
	/etc/waydroid-extra
stage_complete remove-system-files

if [[ "$KEEP_ANDROID_STATE" == true ]]; then
	printf 'Removing per-user host integration while retaining Android user data...\n'
else
	printf 'Removing Android data and per-user integration...\n'
fi
rm -f -- \
	"$HOME/Desktop/Waydroid-Toolbox" \
	"$HOME/Desktop/Waydroid-Updater" \
	"$HOME/.local/share/kio/servicemenus/open_as_root.desktop" \
	"$PROJECT_ROOT/extras/waydroid.img" \
	"$PROJECT_ROOT/logfile"
# Waydroid and its privileged helpers can leave root-owned files below these
# user directories. Remove main integration and image files while explicitly
# preserving the separately managed test directory.
if [[ "$WAYDROID_TEST_HOME" != "$ANDROID_HOME/test" ]]; then
	printf 'error: unsafe Waydroid Test directory resolution: %s\n' \
		"$WAYDROID_TEST_HOME" >&2
	exit 1
fi
if [[ -d "$ANDROID_HOME" ]]; then
	sudo find "$ANDROID_HOME" -mindepth 1 -maxdepth 1 \
		! -path "$WAYDROID_TEST_HOME" -exec rm -rf -- {} +
	sudo rmdir "$ANDROID_HOME" 2>/dev/null || true
fi
if [[ "$KEEP_ANDROID_STATE" != true ]]; then
	sudo rm -rf -- \
		"$WAYDROID_LEGACY_USER_STATE" \
		"$WAYDROID_USER_STATE"
	if [[ -d "$HOME/.local/share" ]]; then
		sudo find "$HOME/.local/share" -mindepth 1 -maxdepth 1 \
			\( -name 'waydroid.pre-reinstall-*' -o \
			-name 'waydroid.failed-reinstall-*' \) \
			-exec rm -rf -- {} +
	fi
	sudo find "$HOME" -mindepth 1 -maxdepth 1 \
		\( -name 'waydroid.pre-reinstall-*' -o \
		-name 'waydroid.failed-reinstall-*' \) \
		-exec rm -rf -- {} +
fi

applications="$HOME/.local/share/applications"
if [[ -d "$applications" ]]; then
	find "$applications" -maxdepth 1 -type f -name 'waydroid*.desktop' -delete
fi

stage_start readonly-enable
sudo steamos-readonly enable
READONLY_DISABLED=false
stage_complete readonly-enable

if [[ "$KEEP_ANDROID_STATE" == true ]]; then
	printf 'Restoring the preserved Android image...\n'
	restore_android_files

	for user_state_path in "${PRESENT_ANDROID_USER_STATE[@]}"; do
		if [[ ! -e "$user_state_path" && ! -L "$user_state_path" ]]; then
			printf 'error: preserved Android user state disappeared during reset: %s\n' \
				"$user_state_path" >&2
			exit 1
		fi
	done

	if [[ "$RESET_ARTIFACT_STATE" == true ]]; then
		printf 'Removing target-built bundles and machine-local artifact state...\n'
		rm -rf -- \
			"$HOME/.local/opt/steamos-waydroid" \
			"$HOME/.local/share/steamos-waydroid-installer" \
			"$STATE_ROOT/reports"
		rm -f -- "$PROJECT_ROOT/.deck-config.env"
	fi
fi

trap - EXIT HUP INT TERM

if [[ "$FULL_PROCESS_RESET" == true ]]; then
	printf 'Removing Deck-side bootstrap prerequisites...\n'
	rm -rf -- \
		"$HOME/.local/opt/steamos-waydroid" \
		"$HOME/.local/share/steamos-waydroid-installer"
	case "$PROJECT_ROOT" in
	"$HOME"/*)
		if [[ -d "$PROJECT_ROOT/.git" && -f "$PROJECT_ROOT/steamos-waydroid-installer.sh" ]]; then
			sudo rm -rf -- "$PROJECT_ROOT"
		else
			printf 'Checkout retained because it could not be identified safely: %s\n' \
				"$PROJECT_ROOT" >&2
		fi
		;;
	*)
		printf 'Checkout retained because it is outside the deck home: %s\n' \
			"$PROJECT_ROOT" >&2
		;;
	esac
fi

cat <<'EOF'

Reset complete.

IMPORTANT: fully restart SteamOS before doing anything else. Do not launch
Waydroid, reinstall, repair, or run another reset in this boot. A restart lets
the running kernel discard any retained Binder module and establishes a clean
post-uninstall system state.

After the restart, run the installer locally from Desktop Mode when you are
ready to reinstall.
EOF

if [[ "$MANUAL_SHORTCUT_REMOVAL" == true ]]; then
	cat >&2 <<'EOF'

Reminder: shortcut cleanup was skipped or incomplete. Remove any remaining
Waydroid or Nested Desktop entry manually from Steam in Gaming Mode.
EOF
fi

if [[ "$FULL_PROCESS_RESET" == true ]]; then
	printf 'Clone the Git repository again, then pull and install the published bundle.\n'
elif [[ "$KEEP_ANDROID_STATE" == true ]]; then
	if [[ -f "$ANDROID_IMAGE" ]]; then
		printf 'Android image was preserved at: %s\n' "$ANDROID_IMAGE"
	else
		printf 'No Android image was present; existing host-side Android user data was retained.\n'
	fi
	printf 'Android applications, settings and logins were preserved at: %s\n' \
		"$WAYDROID_USER_STATE"
	if [[ "$RESET_ARTIFACT_STATE" == true ]]; then
		printf 'After restarting, configure artifacts, then run the normal installer to test first-time host setup.\n'
	else
		printf 'After restarting, run the normal installer from this checkout to restore host integration.\n'
	fi
else
	printf 'Android data was deleted. The Git checkout and verified target-built bundles were retained.\n'
fi

reset_log "stage=reset complete"
