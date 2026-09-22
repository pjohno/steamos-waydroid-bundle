#!/bin/bash

# define functions here
restore_decky_loader() {
	if [ "${DECKY_LOADER_STOPPED:-false}" = true ]; then
		echo Re-enabling the Decky Loader plugin service.
		# current_password is supplied by steamos-waydroid-installer.sh.
		# shellcheck disable=SC2154
		if printf '%s\n' "$current_password" |
			sudo -S systemctl start plugin_loader.service; then
			DECKY_LOADER_STOPPED=false
		else
			echo Warning: Decky Loader could not be restarted. >&2
			return 1
		fi
	fi
}

prompt_restore_decky_loader() {
	local prompt_status

	if [ "${DECKY_LOADER_STOPPED:-false}" != true ]; then
		return 0
	fi

	zenity --question \
		--title "SteamOS Waydroid Installer" \
		--text "Decky Loader was running before installation and was stopped temporarily.\n\nRestart Decky Loader now?" \
		--width 500 --height 75
	prompt_status=$?
	case "$prompt_status" in
	0)
		restore_decky_loader
		;;
	1)
		printf 'Decky Loader will remain stopped at the user\047s request.\n'
		# The EXIT trap restores Decky after failures. Clear ownership here so an
		# explicit choice to leave it stopped is respected on successful exit.
		DECKY_LOADER_STOPPED=false
		;;
	*)
		echo Warning: the Decky Loader restart prompt failed. >&2
		return 1
		;;
	esac
}

confirm_android_reinstall() {
	local confirmation

	cat <<EOF

Existing Android state was found:
EOF
	for existing_path in \
		"$WAYDROID_IMAGE" \
		"$WAYDROID_USER_STATE" \
		"$HOME/waydroid"; do
		if [ -e "$existing_path" ] || [ -L "$existing_path" ]; then
			printf '  %s\n' "$existing_path"
		fi
	done
	cat <<EOF

Android reinstallation creates a new Android instance. The current image and
host-side Android user data will be renamed in place instead of deleted. Its
applications, settings and logins will not appear in the new instance, but the
complete previous state will remain available as timestamped archives.
EOF
	IFS= read -r -p "Type REINSTALL ANDROID to continue: " confirmation
	if [ "$confirmation" != "REINSTALL ANDROID" ]; then
		echo Android reinstallation cancelled.
		return 1
	fi
}

detach_android_image() {
	local image_path=$1 loop_device

	sudo systemctl stop waydroid-container.service 2>/dev/null || true
	if findmnt --mountpoint /var/lib/waydroid >/dev/null 2>&1; then
		sudo umount /var/lib/waydroid
	fi
	while IFS=: read -r loop_device _; do
		if [[ "$loop_device" == /dev/loop* ]]; then
			sudo losetup -d "$loop_device"
		fi
	done < <(sudo losetup -j "$image_path")
}

waydroid_mounts_are_active() {
	findmnt -rn -o TARGET | grep -Eq '^/var/lib/waydroid(/|$)'
}

test_environment_install_allowed() {
	if [[ "${WAYDROID_PROFILE:-}" != test ]]; then
		printf 'error: test-environment installation requires the test profile\n' >&2
		return 1
	fi
	if [[ -e "$WAYDROID_IMAGE" || -L "$WAYDROID_IMAGE" ]]; then
		printf 'Waydroid Test is already installed.\n' >&2
		return 1
	fi
	if [[ -e "$WAYDROID_USER_STATE" || -L "$WAYDROID_USER_STATE" ]]; then
		printf 'error: Waydroid Test user state already exists without its image: %s\n' \
			"$WAYDROID_USER_STATE" >&2
		printf 'Refusing to overwrite or remove existing test data.\n' >&2
		return 1
	fi
}

ensure_waydroid_runtime_inactive_for_test_operation() {
	local operation=${1:-using Waydroid Test}

	if systemctl is-active --quiet waydroid-container.service; then
		printf 'error: Waydroid is currently active; shut it down before %s\n' "$operation" >&2
		return 1
	fi
	if waydroid_mounts_are_active; then
		printf 'error: /var/lib/waydroid is already mounted; shut down Waydroid before %s\n' "$operation" >&2
		return 1
	fi
	if pgrep -x waydroid >/dev/null 2>&1 ||
		pgrep -x waydroid-container >/dev/null 2>&1; then
		printf 'error: a Waydroid process is still running; shut down Waydroid before %s\n' "$operation" >&2
		return 1
	fi
}

ensure_waydroid_runtime_inactive_for_test_install() {
	ensure_waydroid_runtime_inactive_for_test_operation "installing Waydroid Test"
}

commit_new_android_image() {
	local staged_image=$1

	[[ -f "$staged_image" && ! -L "$staged_image" ]] || {
		printf 'error: completed Android image is missing or unsafe: %s\n' \
			"$staged_image" >&2
		return 1
	}
	[[ ! -e "$WAYDROID_IMAGE" && ! -L "$WAYDROID_IMAGE" ]] || {
		printf 'error: refusing to overwrite the profile image: %s\n' \
			"$WAYDROID_IMAGE" >&2
		return 1
	}
	mkdir -p -- "${WAYDROID_IMAGE%/*}" || return 1
	mv -- "$staged_image" "$WAYDROID_IMAGE"
}

binder_package_kernel_release() {
	local package=$1
	local archive_listing
	local -a releases=()

	if [[ ! -f "$package" ]]; then
		printf 'Binder package is missing: %s\n' "$package" >&2
		return 1
	fi

	if ! archive_listing=$(bsdtar -tf "$package"); then
		printf 'Could not inspect Binder package: %s\n' "$package" >&2
		return 1
	fi

	mapfile -t releases < <(
		awk '
			{
				path = $0
				sub(/^\.\//, "", path)
				count = split(path, part, "/")

				if (count < 5)
					next
				if (part[1] != "usr")
					next
				if (part[2] != "lib")
					next
				if (part[3] != "modules")
					next
				if (part[count] !~ /^binder_linux\.ko(\.(zst|xz|gz|lz4))?$/)
					next

				print part[4]
			}
			' <<<"$archive_listing" |
			sort -u
	)

	case "${#releases[@]}" in
	1)
		printf '%s\n' "${releases[0]}"
		;;
	0)
		printf \
			'Binder package does not contain binder_linux under usr/lib/modules/<kernel>: %s\n' \
			"$package" >&2
		return 1
		;;
	*)
		printf 'Binder package contains modules for multiple kernel releases:\n' >&2
		printf '  %s\n' "${releases[@]}" >&2
		return 1
		;;
	esac
}

validate_binder_kernel_match() {
	local binder_package_kernel=$1
	local running_kernel_release=$2

	if [ "$binder_package_kernel" != "$running_kernel_release" ]; then
		printf 'Bundled Binder module targets kernel %s.\n' \
			"$binder_package_kernel" >&2
		printf 'Running kernel is %s.\n' \
			"$running_kernel_release" >&2
		printf '%s\n' \
			'Refusing to install a Binder module built for a different kernel.' >&2
		return 1
	fi
}

verify_pacman_transaction_dependencies() {
	local package_file metadata_name planned_name planned_repository planned_version
	local transaction_output
	local -a missing_targets=() repository_dependencies=() invalid_sources=()
	local -A bundled_package_names=()
	local -A planned_package_names=()

	(($# > 0)) || {
		printf 'No bundled packages were supplied for transaction validation.\n' >&2
		return 1
	}

	for package_file in "$@"; do
		[[ -f "$package_file" ]] || {
			printf 'Bundled package is missing: %s\n' "$package_file" >&2
			return 1
		}
		metadata_name="$(
			bsdtar -xOf "$package_file" .PKGINFO |
				awk -F' = ' '$1 == "pkgname" {print $2; exit}'
		)"
		[[ "$metadata_name" =~ ^[A-Za-z0-9@._+-]+$ ]] || {
			printf 'Bundled package has an invalid package name: %s\n' "$package_file" >&2
			return 1
		}
		bundled_package_names["$metadata_name"]=true
	done

	if ! transaction_output="$(
		LC_ALL=C pacman -U --print --print-format '%n|%r|%v' "$@"
	)"; then
		printf 'Pacman could not resolve the bundled package transaction.\n' >&2
		return 1
	fi

	while IFS='|' read -r planned_name planned_repository planned_version; do
		[[ -n "$planned_name" ]] || continue
		planned_package_names["$planned_name"]=true
		if [[ ${bundled_package_names[$planned_name]:-false} != true ]]; then
			if [[ ! "$planned_repository" =~ ^[A-Za-z0-9@._+-]+$ ]] ||
				[[ -z "$planned_version" ]]; then
				invalid_sources+=("$planned_name")
			else
				repository_dependencies+=(
					"$planned_repository/$planned_name $planned_version"
				)
			fi
		fi
	done <<<"$transaction_output"
	for metadata_name in "${!bundled_package_names[@]}"; do
		if [[ ${planned_package_names[$metadata_name]:-false} != true ]]; then
			missing_targets+=("$metadata_name")
		fi
	done

	if ((${#missing_targets[@]} > 0)); then
		printf 'Pacman transaction preview omitted bundled targets:\n' >&2
		printf '  %s\n' "${missing_targets[@]}" >&2
		return 1
	fi
	if ((${#invalid_sources[@]} > 0)); then
		printf 'Pacman preview included dependencies without a valid sync-repository source:\n' >&2
		printf '  %s\n' "${invalid_sources[@]}" >&2
		return 1
	fi

	if ((${#repository_dependencies[@]} > 0)); then
		printf 'Pacman resolved these additional dependencies from the configured SteamOS repositories:\n'
		printf '  %s\n' "${repository_dependencies[@]}"
	else
		printf 'All package dependencies are already installed or supplied by the bundle.\n'
	fi
}

validate_existing_android_image() {
	local filesystem_type check_mount loop_device validation_failed

	if [ ! -f "$WAYDROID_IMAGE" ] || [ -L "$WAYDROID_IMAGE" ]; then
		echo "Existing Android image is not a regular file: $WAYDROID_IMAGE" >&2
		return 1
	fi

	detach_android_image "$WAYDROID_IMAGE" || return 1
	filesystem_type=$(sudo blkid -p -s TYPE -o value -- "$WAYDROID_IMAGE" 2>/dev/null || true)
	if [ "$filesystem_type" != ext4 ]; then
		echo "Existing Android image is not a recognisable ext4 filesystem: $WAYDROID_IMAGE" >&2
		return 1
	fi

	check_mount=$(sudo mktemp -d /run/steamos-waydroid-image-check.XXXXXX) || return 1
	loop_device=$(sudo losetup --find --show "$WAYDROID_IMAGE") || {
		sudo rmdir "$check_mount" 2>/dev/null || true
		return 1
	}
	if ! sudo mount -o ro,noload "$loop_device" "$check_mount"; then
		sudo losetup -d "$loop_device" 2>/dev/null || true
		sudo rmdir "$check_mount" 2>/dev/null || true
		return 1
	fi

	validation_failed=false
	for required_path in \
		waydroid_base.prop \
		waydroid.cfg \
		lxc/waydroid/config \
		rootfs; do
		if ! sudo test -e "$check_mount/$required_path"; then
			echo "Existing Android image is missing: $required_path" >&2
			validation_failed=true
		fi
	done
	if ! sudo test -s "$check_mount/waydroid_base.prop" ||
		! sudo test -s "$check_mount/waydroid.cfg"; then
		echo Existing Android image has empty Waydroid configuration files. >&2
		validation_failed=true
	fi

	sudo umount "$check_mount" || validation_failed=true
	sudo losetup -d "$loop_device" 2>/dev/null || validation_failed=true
	sudo rmdir "$check_mount" 2>/dev/null || true

	if [ "$validation_failed" = true ]; then
		echo Existing Android state could not be validated and was not modified. >&2
		return 1
	fi
	printf 'Existing Android image passed read-only structural validation.\n'
}

archive_existing_android_state() {
	local timestamp archive_path source_path

	ANDROID_REINSTALL_ARCHIVE_READY=false
	if [ -f "$WAYDROID_IMAGE" ]; then
		detach_android_image "$WAYDROID_IMAGE" || return 1
	else
		sudo systemctl stop waydroid-container.service 2>/dev/null || true
	fi
	if waydroid_mounts_are_active; then
		echo Android reinstallation stopped because a Waydroid mount is still active. >&2
		findmnt -R /var/lib/waydroid >&2 || true
		return 1
	fi

	timestamp=$(date -u +%Y%m%dT%H%M%SZ)
	# Read by the calling installer.
	# shellcheck disable=SC2034
	ANDROID_REINSTALL_TIMESTAMP=$timestamp
	ARCHIVED_ANDROID_IMAGE="$ANDROID_HOME/waydroid.img.pre-reinstall-$timestamp"
	ARCHIVED_ANDROID_USER_STATE="$WAYDROID_USER_STATE.pre-reinstall-$timestamp"
	ARCHIVED_ANDROID_LEGACY_USER_STATE="$HOME/waydroid.pre-reinstall-$timestamp"
	FAILED_ANDROID_IMAGE="$ANDROID_HOME/waydroid.img.failed-reinstall-$timestamp"
	FAILED_ANDROID_USER_STATE="$WAYDROID_USER_STATE.failed-reinstall-$timestamp"
	FAILED_ANDROID_LEGACY_USER_STATE="$HOME/waydroid.failed-reinstall-$timestamp"

	for archive_path in \
		"$ARCHIVED_ANDROID_IMAGE" \
		"$ARCHIVED_ANDROID_USER_STATE" \
		"$ARCHIVED_ANDROID_LEGACY_USER_STATE" \
		"$FAILED_ANDROID_IMAGE" \
		"$FAILED_ANDROID_USER_STATE" \
		"$FAILED_ANDROID_LEGACY_USER_STATE"; do
		if [ -e "$archive_path" ] || [ -L "$archive_path" ]; then
			echo "Refusing to overwrite an existing Android state path: $archive_path" >&2
			return 1
		fi
	done

	if [ -f "$WAYDROID_IMAGE" ]; then
		if ! sudo mv -- "$WAYDROID_IMAGE" "$ARCHIVED_ANDROID_IMAGE"; then
			return 1
		fi
	fi
	for source_path in "$WAYDROID_USER_STATE" "$HOME/waydroid"; do
		if [ ! -e "$source_path" ] && [ ! -L "$source_path" ]; then
			continue
		fi
		if [ "$source_path" = "$WAYDROID_USER_STATE" ]; then
			archive_path=$ARCHIVED_ANDROID_USER_STATE
		else
			archive_path=$ARCHIVED_ANDROID_LEGACY_USER_STATE
		fi
		if ! sudo mv -- "$source_path" "$archive_path"; then
			restore_archived_android_state_after_failure
			return 1
		fi
	done
	ANDROID_REINSTALL_ARCHIVE_READY=true

	if [ -f "$ARCHIVED_ANDROID_IMAGE" ]; then
		printf 'Previous Android image archived at: %s\n' "$ARCHIVED_ANDROID_IMAGE"
	fi
	if [ -e "$ARCHIVED_ANDROID_USER_STATE" ] || [ -L "$ARCHIVED_ANDROID_USER_STATE" ]; then
		printf 'Previous Android user data archived at: %s\n' "$ARCHIVED_ANDROID_USER_STATE"
	fi
	if [ -e "$ARCHIVED_ANDROID_LEGACY_USER_STATE" ] || [ -L "$ARCHIVED_ANDROID_LEGACY_USER_STATE" ]; then
		printf 'Previous legacy Android user data archived at: %s\n' "$ARCHIVED_ANDROID_LEGACY_USER_STATE"
	fi
}

move_failed_android_state_aside() {
	local source_path=$1 failed_path=$2

	if [ ! -e "$source_path" ] && [ ! -L "$source_path" ]; then
		return 0
	fi
	if [ -e "$failed_path" ] || [ -L "$failed_path" ]; then
		echo "Cannot move failed replacement state aside; destination exists: $failed_path" >&2
		return 1
	fi
	sudo mv -- "$source_path" "$failed_path"
	printf 'Incomplete replacement state retained at: %s\n' "$failed_path"
}

restore_archived_android_state_after_failure() {
	local restore_failed=false image_path loop_device

	[ -n "${ARCHIVED_ANDROID_IMAGE:-}" ] || return 0
	[ "${ANDROID_REINSTALL_COMMITTED:-false}" != true ] || return 0

	printf 'Restoring the complete previous Android state after installation failure.\n'
	if [ "${ANDROID_REINSTALL_ARCHIVE_READY:-false}" != true ]; then
		if [ -f "$ARCHIVED_ANDROID_IMAGE" ] && [ ! -e "$WAYDROID_IMAGE" ]; then
			sudo mv -- "$ARCHIVED_ANDROID_IMAGE" "$WAYDROID_IMAGE" || restore_failed=true
		fi
		if { [ -e "$ARCHIVED_ANDROID_USER_STATE" ] || [ -L "$ARCHIVED_ANDROID_USER_STATE" ]; } &&
			[ ! -e "$WAYDROID_USER_STATE" ] && [ ! -L "$WAYDROID_USER_STATE" ]; then
			sudo mv -- "$ARCHIVED_ANDROID_USER_STATE" "$WAYDROID_USER_STATE" || restore_failed=true
		fi
		if { [ -e "$ARCHIVED_ANDROID_LEGACY_USER_STATE" ] || [ -L "$ARCHIVED_ANDROID_LEGACY_USER_STATE" ]; } &&
			[ ! -e "$HOME/waydroid" ] && [ ! -L "$HOME/waydroid" ]; then
			sudo mv -- "$ARCHIVED_ANDROID_LEGACY_USER_STATE" "$HOME/waydroid" || restore_failed=true
		fi
		[ "$restore_failed" = false ] || return 1
		ARCHIVED_ANDROID_IMAGE=""
		ARCHIVED_ANDROID_USER_STATE=""
		ARCHIVED_ANDROID_LEGACY_USER_STATE=""
		return 0
	fi

	sudo systemctl stop waydroid-container.service 2>/dev/null || true
	if findmnt --mountpoint /var/lib/waydroid >/dev/null 2>&1; then
		sudo umount /var/lib/waydroid || restore_failed=true
	fi
	if waydroid_mounts_are_active; then
		echo Cannot restore previous Android state while Waydroid mounts remain active. >&2
		return 1
	fi
	for image_path in "$WAYDROID_IMAGE" "${WORKING_DIR:-}/extras/waydroid.img"; do
		[ -n "$image_path" ] && [ -f "$image_path" ] || continue
		while IFS=: read -r loop_device _; do
			if [[ "$loop_device" == /dev/loop* ]]; then
				sudo losetup -d "$loop_device" || restore_failed=true
			fi
		done < <(sudo losetup -j "$image_path")
	done

	if ! move_failed_android_state_aside "$WAYDROID_IMAGE" "$FAILED_ANDROID_IMAGE"; then
		restore_failed=true
	fi
	if ! move_failed_android_state_aside "$WAYDROID_USER_STATE" "$FAILED_ANDROID_USER_STATE"; then
		restore_failed=true
	fi
	if ! move_failed_android_state_aside "$HOME/waydroid" "$FAILED_ANDROID_LEGACY_USER_STATE"; then
		restore_failed=true
	fi
	if [ "$restore_failed" = true ]; then
		echo Previous Android archives were left untouched because replacement state could not be moved safely. >&2
		return 1
	fi

	mkdir -p -- "$ANDROID_HOME" "${WAYDROID_USER_STATE%/*}"
	if [ -f "$ARCHIVED_ANDROID_IMAGE" ]; then
		sudo mv -- "$ARCHIVED_ANDROID_IMAGE" "$WAYDROID_IMAGE" || restore_failed=true
	fi
	if [ -e "$ARCHIVED_ANDROID_USER_STATE" ] || [ -L "$ARCHIVED_ANDROID_USER_STATE" ]; then
		sudo mv -- "$ARCHIVED_ANDROID_USER_STATE" "$WAYDROID_USER_STATE" || restore_failed=true
	fi
	if [ -e "$ARCHIVED_ANDROID_LEGACY_USER_STATE" ] || [ -L "$ARCHIVED_ANDROID_LEGACY_USER_STATE" ]; then
		sudo mv -- "$ARCHIVED_ANDROID_LEGACY_USER_STATE" "$HOME/waydroid" || restore_failed=true
	fi
	if [ "$restore_failed" = true ]; then
		printf '%s\n' \
			'Automatic restoration was incomplete; inspect the timestamped archives before retrying.' >&2
		return 1
	fi

	ARCHIVED_ANDROID_IMAGE=""
	ARCHIVED_ANDROID_USER_STATE=""
	ARCHIVED_ANDROID_LEGACY_USER_STATE=""
	printf 'Previous Android image and user data were restored.\n'
}

mount_waydroid_var() {
	local loop_device

	# this will initialize and configure custom /var/lib/waydroid
	# first make sure /var/lib/waydroid is not mounted
	# current_password is supplied by steamos-waydroid-installer.sh.
	# shellcheck disable=SC2154
	echo -e "$current_password\n" | sudo -S umount /var/lib/waydroid &>/dev/null
	while IFS=: read -r loop_device _; do
		if [[ "$loop_device" == /dev/loop* ]]; then
			# shellcheck disable=SC2154
			echo -e "$current_password\n" | sudo -S losetup -d "$loop_device" &>/dev/null || true
		fi
	done < <(sudo losetup -j "$WORKING_DIR/extras/waydroid.img" 2>/dev/null)

	# prepare the custom /var/lib/waydroid
	# shellcheck disable=SC2154
	gunzip -k -f extras/waydroid.img.gz &&
		mkfs.ext4 -F extras/waydroid.img &&
		ROOTDEV=$(sudo losetup --find --show extras/waydroid.img) &&
		echo -e "$current_password\n" | sudo -S mount "$ROOTDEV" /var/lib/waydroid
}

unmount_waydroid_var() {
	# this will unmount the custom /var/lib/waydroid
	# shellcheck disable=SC2154
	echo -e "$current_password\n" | sudo -S umount /var/lib/waydroid &>/dev/null
	local image_path="${1:-}"
	local loop_device
	if [ -n "$image_path" ] && [ -f "$image_path" ]; then
		while IFS=: read -r loop_device _; do
			if [[ "$loop_device" == /dev/loop* ]]; then
				echo -e "$current_password\n" | sudo -S losetup -d "$loop_device" &>/dev/null || true
			fi
		done < <(echo -e "$current_password\n" | sudo -S losetup -j "$image_path" 2>/dev/null)
	else
		image_path="$WORKING_DIR/extras/waydroid.img"
		while IFS=: read -r loop_device _; do
			if [[ "$loop_device" == /dev/loop* ]]; then
				echo -e "$current_password\n" | sudo -S losetup -d "$loop_device" &>/dev/null || true
			fi
		done < <(echo -e "$current_password\n" | sudo -S losetup -j "$image_path" 2>/dev/null)
	fi
}

cleanup_failed_test_environment() {
	[[ "${TEST_INSTALL_CLEANUP_DONE:-false}" != true ]] || return 0
	if [[ "${WAYDROID_PROFILE:-}" != test ]]; then
		printf 'error: refusing test cleanup outside the test profile\n' >&2
		return 1
	fi
	TEST_INSTALL_CLEANUP_DONE=true

	printf 'Cleaning up the incomplete Waydroid Test installation.\n' >&2
	printf '%s\n' "$current_password" |
		sudo -S systemctl stop waydroid-container.service &>/dev/null || true
	unmount_waydroid_var "$WORKING_DIR/extras/waydroid.img"
	printf '%s\n' "$current_password" |
		sudo -S rm -f -- "$WORKING_DIR/extras/waydroid.img" &>/dev/null || true
	printf '%s\n' "$current_password" |
		sudo -S rm -rf -- "$WAYDROID_XDG_DATA_HOME" "${WAYDROID_IMAGE%/*}" &>/dev/null || true
	printf '%s\n' "$current_password" |
		sudo -S steamos-readonly enable &>/dev/null || true
	restore_decky_loader || true
	printf 'The normal Waydroid image and user data were not modified.\n' >&2
	printf 'Test installation diagnostics remain at: %s\n' "$LOGFILE" >&2
}

cleanup_exit() {
	local binder_package_was_installed=false
	local binder_module_unload_failed=false
	local package
	local -a cleanup_packages=()

	# Call this function to clean up after a host-installation failure.

	echo Something went wrong! Performing cleanup. Run the script again to install waydroid.

	# Stop Waydroid before unloading its optional out-of-tree Binder module.
	# shellcheck disable=SC2154
	printf '%s\n' "$current_password" |
		sudo -S systemctl stop waydroid-container.service &>/dev/null || true

	if pacman -Qq steamos-waydroid-binder >/dev/null 2>&1; then
		binder_package_was_installed=true
		if lsmod | awk '$1 == "binder_linux" {found=1} END {exit !found}'; then
			echo Unloading the bundled Binder kernel module.
			if ! printf '%s\n' "$current_password" |
				sudo -S modprobe -r binder_linux &>/dev/null; then
				binder_module_unload_failed=true
				echo Warning: binder_linux could not be unloaded and will remain active until reboot. >&2
			fi
		fi
	fi

	# A failed pacman transaction may have installed only part of the package
	# set. Remove exactly the packages which are present so one missing package
	# cannot make the entire cleanup transaction fail.
	for package in \
		waydroid \
		python-gbinder \
		libgbinder \
		libglibutil \
		steamos-waydroid-binder; do
		if pacman -Qq "$package" >/dev/null 2>&1; then
			cleanup_packages+=("$package")
		fi
	done
	if [ "${#cleanup_packages[@]}" -gt 0 ]; then
		# shellcheck disable=SC2154
		if ! printf '%s\n' "$current_password" |
			sudo -S pacman -Rns --noconfirm "${cleanup_packages[@]}" &>/dev/null; then
			echo Warning: one or more Waydroid packages could not be removed. >&2
		fi
	fi

	if [ "$binder_package_was_installed" = true ]; then
		# Drop the removed module from modprobe's dependency index even when it
		# could not be unloaded from the running kernel.
		# shellcheck disable=SC2154
		printf '%s\n' "$current_password" |
			sudo -S depmod -a "$(uname -r)" &>/dev/null ||
			echo Warning: kernel module indexes could not be refreshed. >&2
	fi
	if pacman -Qq steamos-waydroid-binder >/dev/null 2>&1; then
		if [ "$binder_module_unload_failed" = true ]; then
			echo "Warning: steamos-waydroid-binder is still installed; reboot, then remove it manually." >&2
		else
			echo "Warning: steamos-waydroid-binder is still installed; remove it manually before retrying." >&2
		fi
	elif [ "$binder_module_unload_failed" = true ]; then
		echo The Binder package was removed, but reboot before retrying the installer. >&2
	fi

	# unmount the custom /var/lib/waydroid
	# shellcheck disable=SC2154
	echo -e "$current_password\n" | sudo -S umount /var/lib/waydroid &>/dev/null
	# shellcheck disable=SC2154
	echo -e "$current_password\n" | sudo -S losetup -d "$(losetup | grep waydroid.img | cut -d ' ' -f1)" &>/dev/null

	# delete the waydroid directories
	# shellcheck disable=SC2154
	echo -e "$current_password\n" | sudo -S rm -rf /var/lib/waydroid &>/dev/null
	# shellcheck disable=SC2154
	echo -e "$current_password\n" | sudo -S rm -rf /usr/lib/steamos-waydroid &>/dev/null

	# delete waydroid config and scripts
	# shellcheck disable=SC2154
	echo -e "$current_password\n" | sudo -S rm /etc/sudoers.d/zzzzzzzz-waydroid /usr/bin/waydroid* &>/dev/null

	# delete Waydroid Toolbox and Waydroid Update symlinks
	rm ~/Desktop/Waydroid-Updater &>/dev/null
	rm ~/Desktop/Waydroid-Toolbox &>/dev/null

	# delete Android_Waydroid folder and enable the readonly
	# shellcheck disable=SC2154
	echo -e "$current_password\n" | sudo -S rm -rf ~/Android_Waydroid/*.sh ~/Android_Waydroid/config &>/dev/null
	# shellcheck disable=SC2154
	echo -e "$current_password\n" | sudo -S steamos-readonly enable &>/dev/null

	# Re-enable Decky if this installer stopped it during preflight.
	restore_decky_loader || true
	restore_archived_android_state_after_failure || true

	echo Cleanup completed. Please open an issue at https://github.com/pjohno/steamos-waydroid-bundle/issues.
	exit 1
}

# Apply the version-independent controller/root properties, then only the
# fingerprint spoof which is known to match the selected Android 13 image.
apply_android_custom_config() {

	# waydroid_base.prop - controller config and disable root
	echo "" | sudo tee -a /var/lib/waydroid/waydroid_base.prop >/dev/null
	cat extras/props/waydroid_base.prop | sudo tee -a /var/lib/waydroid/waydroid_base.prop >/dev/null

	# waydroid_base.prop fingerprint spoof
	# shellcheck disable=SC2154
	if [ "$Android_Choice" == "A13_NO_GAPPS" ] || [ "$Android_Choice" == "A13_GAPPS" ]; then
		echo "" | sudo tee -a /var/lib/waydroid/waydroid_base.prop >/dev/null
		cat extras/props/android_spoof.prop | sudo tee -a /var/lib/waydroid/waydroid_base.prop >/dev/null
	elif [ "$Android_Choice" == "TV13_NO_GAPPS" ] || [ "$Android_Choice" == "TV13_GAPPS" ]; then
		echo TV13.
		echo "" | sudo tee -a /var/lib/waydroid/waydroid_base.prop >/dev/null
		cat extras/props/androidtv_spoof.prop | sudo tee -a /var/lib/waydroid/waydroid_base.prop
	else
		printf 'Skipping the Android-13-specific fingerprint spoof for Android %s.\n' \
			"${ANDROID_VERSION:-unknown}"
	fi
}

# install arm translation layer from casualsnek / aleasto waydroid_script
install_android_extras() {
	# casualsnek / aleasto waydroid_script - install libndk / libhoudini and widevine
	echo "*** create waydroid_script virtual environment ***" >>"$LOGFILE"
	if ! python3 -m venv "$WAYDROID_SCRIPT_DIR"/venv >>"$LOGFILE" 2>&1; then
		echo "Error: could not create the waydroid_script Python environment." >&2
		echo "Details were saved to: $LOGFILE" >&2
		rm -rf -- "$WAYDROID_SCRIPT_DIR"
		return 1
	fi

	echo "*** install waydroid_script Python requirements ***" >>"$LOGFILE"
	if ! "$WAYDROID_SCRIPT_DIR"/venv/bin/pip install \
		-r "$WAYDROID_SCRIPT_DIR"/requirements.txt >>"$LOGFILE" 2>&1; then
		echo "Error: waydroid_script Python requirements could not be installed." >&2
		echo "Details were saved to: $LOGFILE" >&2
		rm -rf -- "$WAYDROID_SCRIPT_DIR"
		return 1
	fi

	# shellcheck disable=SC2154
	echo "$ARM_Choice and Widevine installation started."
	echo "*** install $ARM_Choice and Widevine ***" >>"$LOGFILE"
	# shellcheck disable=SC2154
	if ! { printf '%s\n' "$current_password" |
		run_profile_sudo "$WAYDROID_SCRIPT_DIR"/venv/bin/python3 \
			"$WAYDROID_SCRIPT_DIR"/main.py -a13 install "$ARM_Choice" widevine; } \
		>>"$LOGFILE" 2>&1; then
		echo "Error: $ARM_Choice or Widevine installation failed." >&2
		echo "Details were saved to: $LOGFILE" >&2
		# The external tool may have created root-owned files in its checkout.
		printf '%s\n' "$current_password" |
			sudo -S rm -rf -- "$WAYDROID_SCRIPT_DIR" &>/dev/null || true
		return 1
	fi

	echo "waydroid_script completed successfully. $ARM_Choice and Widevine were installed."
	# shellcheck disable=SC2154
	if ! printf '%s\n' "$current_password" |
		sudo -S rm -rf -- "$WAYDROID_SCRIPT_DIR"; then
		echo "Warning: temporary waydroid_script files could not be removed: $WAYDROID_SCRIPT_DIR" >&2
	fi
	return 0
}

check_waydroid_init() {
	# check if waydroid initialization completed without errors
	if [ $? -eq 0 ]; then
		echo Waydroid initialization completed without errors!

	else
		echo Waydroid did not initialize correctly.
		echo This could be a hash mismatch / corrupted download.
		echo This could also be a python issue. Attach this screenshot when filing a bug report!
		echo Output of whereis python - "$(whereis python)"
		echo Output of which python - "$(which python)"
		echo Output of python version - "$(python -V)"

		abort_run
	fi
}
