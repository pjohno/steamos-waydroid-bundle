#!/bin/bash

find_waydroid_installer() {
	local installer_root installer_path

	if [ -r "$HOME/Android_Waydroid/installer-root" ]; then
		IFS= read -r installer_root <"$HOME/Android_Waydroid/installer-root"
		installer_path="$installer_root/steamos-waydroid-installer.sh"
		if [ -x "$installer_path" ] &&
			[ -x "$installer_root/libexec/steamos-waydroid/uninstall.sh" ]; then
			printf '%s\n' "$installer_path"
			return 0
		fi
	fi

	# Compatibility with installations created before installer-root was
	# recorded. This is the checkout location documented in README.md.
	installer_path="$HOME/steamos-waydroid-bundle/steamos-waydroid-installer.sh"
	if [ -x "$installer_path" ] &&
		[ -x "$HOME/steamos-waydroid-bundle/libexec/steamos-waydroid/uninstall.sh" ]; then
		printf '%s\n' "$installer_path"
		return 0
	fi

	return 1
}

PASSWORD=$(zenity --password --title "sudo Password Authentication")
echo -e "$PASSWORD\n" | sudo -S ls &>/dev/null
if [ $? -ne 0 ]; then
	echo sudo password is wrong! |
		zenity --text-info --title "Waydroid Toolbox" --width 400 --height 200
	exit
fi

while true; do
	Choice=$(zenity --width 850 --height 400 --list --radiolist --multiple --title "Waydroid Toolbox  - https://github.com/pjohno/steamos-waydroid-bundle" \
		--column "Select One" \
		--column "Option" \
		--column="Description - Read this carefully!" \
		FALSE ADBLOCK "Disable or update the custom adblock hosts file." \
		FALSE AUDIO "Enable or disable the custom audio fixes." \
		FALSE SERVICE "Start or Stop the Waydroid container service." \
		FALSE GPU "Change the GPU config - GBM or MINIGBM." \
		FALSE LAUNCHER "Add Android Waydroid Cage launcher to Game Mode." \
		FALSE TEST_ENV "Install a separate experimental Waydroid Test Android environment." \
		FALSE NETWORK "Reinitialize firewall configuration - use this when WIFI is not working." \
		FALSE UNINSTALL "Choose this to uninstall Waydroid and revert any changes made." \
		TRUE EXIT "***** Exit the Waydroid Toolbox *****")

	if [ $? -eq 1 ] || [ "$Choice" == "EXIT" ]; then
		echo User pressed CANCEL / EXIT.
		exit

	elif [ "$Choice" == "TEST_ENV" ]; then
		profile_lib=/usr/lib/steamos-waydroid/waydroid-profile.sh
		if [ ! -r "$profile_lib" ]; then
			zenity --error --title "Waydroid Toolbox" \
				--text "The Waydroid profile helper is missing. Run the normal installer repair first."
			continue
		fi
		# shellcheck source=../../libexec/steamos-waydroid/waydroid-profile.sh
		source "$profile_lib"
		if ! resolve_waydroid_profile test; then
			zenity --error --title "Waydroid Toolbox" \
				--text "The Waydroid Test paths could not be resolved safely."
			continue
		fi
		if [ -f "$WAYDROID_IMAGE" ]; then
			zenity --info --title "Waydroid Toolbox" \
				--text "Waydroid Test is already installed."
			continue
		fi
		if ! installer_path="$(find_waydroid_installer)"; then
			zenity --error --title "Waydroid Toolbox" \
				--text "The installer checkout could not be found; Waydroid Test was not installed."
			continue
		fi
		if ! zenity --question --title "Install Waydroid Test" --width 650 --height 140 \
			--text "Install an additional experimental Android environment?\n\nThe normal Waydroid image and applications will remain unchanged. Only one environment can run at a time."; then
			continue
		fi
		if [ -t 0 ] && [ -t 1 ]; then
			exec "$installer_path" --install-test
		elif command -v konsole >/dev/null 2>&1; then
			konsole --hold -e "$installer_path" --install-test &
			exit 0
		else
			zenity --error --title "Install Waydroid Test" --width 650 --height 120 \
				--text "Konsole is unavailable. Open a terminal and run:\n\n$installer_path --install-test"
		fi

	elif [ "$Choice" == "NETWORK" ]; then
		if ! installer_path="$(find_waydroid_installer)"; then
			zenity --error --title "Waydroid Toolbox" \
				--text "The installer checkout could not be found; firewall configuration was not changed."
			continue
		fi
		installer_root="$(dirname -- "$installer_path")"
		# shellcheck source=/dev/null
		source "$installer_root/libexec/steamos-waydroid/firewall-rules.sh"
		firewall_ownership_file="$HOME/.local/share/steamos-waydroid-installer/firewall-ownership.env"
		toolbox_firewall_sudo() {
			printf '%s\n' "$PASSWORD" | sudo -S "$@"
		}

		firewalld_was_active=false
		if systemctl is-active --quiet firewalld.service; then
			firewalld_was_active=true
			firewall_validation_command=(toolbox_firewall_sudo firewall-cmd)
		else
			firewall_validation_command=(toolbox_firewall_sudo firewall-offline-cmd)
		fi
		network_failed=false
		firewalld_started_by_toolbox=false
		if ! "${firewall_validation_command[@]}" --check-config; then
			network_failed=true
		elif load_firewall_ownership "$firewall_ownership_file"; then
			:
		elif [ $? -eq 2 ]; then
			network_failed=true
		fi
		if [ "$network_failed" != true ] &&
			! toolbox_firewall_sudo systemctl start firewalld; then
			network_failed=true
		elif [ "$network_failed" != true ]; then
			firewalld_started_by_toolbox=true
		fi
		if [ "$network_failed" != true ]; then
			for firewall_rule in "${FIREWALL_RULE_KEYS[@]}"; do
				if firewall_rule_command query "$firewall_rule" \
					toolbox_firewall_sudo firewall-cmd --permanent >/dev/null 2>&1; then
					:
				else
					firewall_query_status=$?
					if [ "$firewall_query_status" -ne 1 ] ||
						! firewall_rule_command add "$firewall_rule" \
							toolbox_firewall_sudo firewall-cmd --permanent; then
						network_failed=true
						break
					fi
					firewall_mark_rule_owned "$firewall_rule"
				fi
				if firewall_rule_command query "$firewall_rule" \
					toolbox_firewall_sudo firewall-cmd >/dev/null 2>&1; then
					:
				else
					firewall_query_status=$?
					if [ "$firewall_query_status" -ne 1 ] ||
						! firewall_rule_command add "$firewall_rule" \
							toolbox_firewall_sudo firewall-cmd; then
						network_failed=true
						break
					fi
				fi
			done
		fi
		if [ "$network_failed" != true ] &&
			! toolbox_firewall_sudo firewall-cmd --check-config; then
			network_failed=true
		fi
		if [ "$network_failed" != true ] &&
			! write_firewall_ownership "$firewall_ownership_file"; then
			network_failed=true
		fi
		if [ "$firewalld_was_active" != true ] &&
			[ "$firewalld_started_by_toolbox" = true ]; then
			toolbox_firewall_sudo systemctl stop firewalld || network_failed=true
		fi
		unset -f toolbox_firewall_sudo
		if [ "$network_failed" = true ]; then
			zenity --error --title "Waydroid Toolbox" \
				--text "Firewalld validation or targeted Waydroid rule setup failed. No broad firewall save was attempted."
			continue
		fi

		zenity --warning --title "Waydroid Toolbox" --text "Waydroid network configuration completed!" --width 350 --height 75

	elif [ "$Choice" == "ADBLOCK" ]; then
		ADBLOCK_Choice=$(zenity --width 600 --height 250 --list --radiolist --multiple --title "Waydroid Toolbox" --column "Select One" \
			--column "Option" --column="Description - Read this carefully!" \
			FALSE DISABLE "Disable the custom adblock hosts file." \
			FALSE ENABLE "Disable the custom adblock hosts file." \
			FALSE UPDATE "Update and enable the custom adblock hosts file." \
			TRUE MENU "***** Go back to Waydroid Toolbox Main Menu *****")

		if [ $? -eq 1 ] || [ "$ADBLOCK_Choice" == "MENU" ]; then
			echo User pressed CANCEL. Going back to main menu.

		elif [ "$ADBLOCK_Choice" == "DISABLE" ]; then
			# Disable the custom adblock hosts file
			echo -e "$PASSWORD\n" | sudo -S mv /var/lib/waydroid/overlay/system/etc/hosts /var/lib/waydroid/overlay/system/etc/hosts.disable &>/dev/null

			zenity --warning --title "Waydroid Toolbox" --text "Custom adblock hosts file has been disabled!" --width 350 --height 75

		elif [ "$ADBLOCK_Choice" == "ENABLE" ]; then
			# Enable the custom adblock hosts file
			echo -e "$PASSWORD\n" | sudo -S mv /var/lib/waydroid/overlay/system/etc/hosts.disable /var/lib/waydroid/overlay/system/etc/hosts &>/dev/null

			zenity --warning --title "Waydroid Toolbox" --text "Custom adblock hosts file has been enabled!" --width 350 --height 75

		elif [ "$ADBLOCK_Choice" == "UPDATE" ]; then
			# get the latest custom adblock hosts file from steven black github
			echo -e "$PASSWORD\n" | sudo -S rm /var/lib/waydroid/overlay/system/etc/hosts.disable &>/dev/null
			echo -e "$PASSWORD\n" | sudo -S wget https://raw.githubusercontent.com/StevenBlack/hosts/master/alternates/fakenews-gambling-porn/hosts \
				-O /var/lib/waydroid/overlay/system/etc/hosts

			zenity --warning --title "Waydroid Toolbox" --text "Custom adblock hosts file has been updated!" --width 350 --height 75
		fi

	elif [ "$Choice" == "GPU" ]; then
		GPU_Choice=$(zenity --width 600 --height 220 --list --radiolist --multiple --title "Waydroid Toolbox" --column "Select One" --column "Option" --column="Description - Read this carefully!" \
			FALSE GBM "Use gbm config for GPU." \
			FALSE MINIGBM "Use minigbm_gbm_mesa for GPU (default)." \
			TRUE MENU "***** Go back to Waydroid Toolbox Main Menu *****")
		if [ $? -eq 1 ] || [ "$GPU_Choice" == "MENU" ]; then
			echo User pressed CANCEL. Going back to main menu.

		elif [ "$GPU_Choice" == "GBM" ]; then
			# Edit waydroid prop file to use gbm
			echo -e "$PASSWORD\n" | sudo -S sed -i "s/ro.hardware.gralloc=.*/ro.hardware.gralloc=gbm/g" \
				/var/lib/waydroid/waydroid_base.prop

			zenity --warning --title "Waydroid Toolbox" --text "gbm is now in use!" --width 350 --height 75

		elif [ "$GPU_Choice" == "MINIGBM" ]; then
			# Edit waydroid prop file to use minigbm_gbm_mesa
			echo -e "$PASSWORD\n" | sudo -S sed -i "s/ro.hardware.gralloc=.*/ro.hardware.gralloc=minigbm_gbm_mesa/g" \
				/var/lib/waydroid/waydroid_base.prop

			zenity --warning --title "Waydroid Toolbox" --text "minigbm_gbm_mesa is now in use!" --width 350 --height 75
		fi

	elif [ "$Choice" == "AUDIO" ]; then
		AUDIO_Choice=$(zenity --width 600 --height 220 --list --radiolist --multiple --title "Waydroid Toolbox" --column "Select One" --column "Option" --column="Description - Read this carefully!" \
			FALSE DISABLE "Disable the custom audio config." \
			FALSE ENABLE "Enable the custom audio config to lower audio latency." \
			TRUE MENU "***** Go back to Waydroid Toolbox Main Menu *****")
		if [ $? -eq 1 ] || [ "$AUDIO_Choice" == "MENU" ]; then
			echo User pressed CANCEL. Going back to main menu.

		elif [ "$AUDIO_Choice" == "DISABLE" ]; then
			# Disable the custom audio config
			echo -e "$PASSWORD\n" | sudo -S mv /var/lib/waydroid/overlay/system/etc/init/audio.rc \
				/var/lib/waydroid/overlay/system/etc/init/audio.rc.disable &>/dev/null

			zenity --warning --title "Waydroid Toolbox" --text "Custom audio config has been disabled!" --width 350 --height 75

		elif [ "$AUDIO_Choice" == "ENABLE" ]; then
			# Enable the custom audio config
			echo -e "$PASSWORD\n" | sudo -S mv /var/lib/waydroid/overlay/system/etc/init/audio.rc.disable \
				/var/lib/waydroid/overlay/system/etc/init/audio.rc &>/dev/null

			zenity --warning --title "Waydroid Toolbox" --text "Custom audio config has been enabled!" --width 350 --height 75
		fi

	elif [ "$Choice" == "SERVICE" ]; then
		SERVICE_Choice=$(zenity --width 600 --height 220 --list --radiolist --multiple --title "Waydroid Toolbox" --column "Select One" --column "Option" --column="Description - Read this carefully!" \
			FALSE START "Start the Waydroid container service." \
			FALSE STOP "Stop the Waydroid container service." \
			TRUE MENU "***** Go back to Waydroid Toolbox Main Menu *****")
		if [ $? -eq 1 ] || [ "$SERVICE_Choice" == "MENU" ]; then
			echo User pressed CANCEL. Going back to main menu.

		elif [ "$SERVICE_Choice" == "START" ]; then
			# start the waydroid container service
			echo -e "$PASSWORD\n" | sudo -S waydroid-container-start
			waydroid session start &
			sleep 5

			zenity --warning --title "Waydroid Toolbox" --text "Waydroid container service has been started!" --width 350 --height 75

		elif [ "$SERVICE_Choice" == "STOP" ]; then
			# stop the waydroid container service
			waydroid session stop
			echo -e "$PASSWORD\n" | sudo -S waydroid-container-stop
			pkill kwallet

			zenity --warning --title "Waydroid Toolbox" --text "Waydroid container service has been stopped!" --width 350 --height 75
		fi

	elif [ "$Choice" == "LAUNCHER" ]; then
		SHORTCUT_MANAGER="$HOME/Android_Waydroid/steam-shortcuts.py"
		if /usr/bin/python3 "$SHORTCUT_MANAGER" has waydroid; then
			echo Existing Waydroid shortcut found. It will be updated.
		else
			steamos-add-to-steam "$HOME/Android_Waydroid/Android_Waydroid_Cage.sh"
			sleep 5
		fi
		/usr/bin/python3 "$SHORTCUT_MANAGER" reconcile waydroid \
			--artwork-dir "$HOME/Android_Waydroid/icons/waydroid"
		zenity --warning --title "Waydroid Toolbox" --text "One Android Waydroid launcher and its local artwork are ready in Game Mode!" --width 500 --height 75

	elif [ "$Choice" == "UNINSTALL" ]; then
		UNINSTALL_Choice=$(zenity --width 600 --height 220 --list --radiolist --multiple --title "Waydroid Toolbox" --column "Select One" --column "Option" --column="Description - Read this carefully!" \
			FALSE WAYDROID "Remove host integration but preserve the Android image, applications, settings and logins." \
			FALSE PURGE "Remove host integration and permanently delete all Android data." \
			TRUE MENU "***** Go back to Waydroid Toolbox Main Menu *****")
		if [ $? -eq 1 ] || [ "$UNINSTALL_Choice" == "MENU" ]; then
			echo User pressed CANCEL. Going back to main menu.

		elif [ "$UNINSTALL_Choice" == "WAYDROID" ] || [ "$UNINSTALL_Choice" == "PURGE" ]; then
			if ! WAYDROID_INSTALLER=$(find_waydroid_installer); then
				zenity --error --title "Waydroid Toolbox" --width 650 --height 120 \
					--text "The SteamOS Waydroid installer checkout could not be found.\n\nOpen Konsole in the installer checkout and run ./steamos-waydroid-installer.sh --uninstall to preserve Android, or --purge-android to delete it."
				continue
			fi

			if [ "$UNINSTALL_Choice" == "WAYDROID" ]; then
				UNINSTALL_OPTION=--uninstall
				UNINSTALL_DESCRIPTION="Android applications, settings and logins will be preserved."
			else
				UNINSTALL_OPTION=--purge-android
				UNINSTALL_DESCRIPTION="All Android applications, settings and files will be permanently deleted."
			fi

			if ! zenity --question --title "Waydroid Toolbox" --width 650 --height 120 \
				--text "$UNINSTALL_DESCRIPTION\n\nThe protected uninstaller will open in Konsole and require an exact typed confirmation. Continue?"; then
				continue
			fi

			if [ -t 0 ] && [ -t 1 ]; then
				exec "$WAYDROID_INSTALLER" "$UNINSTALL_OPTION"
			elif command -v konsole >/dev/null 2>&1; then
				konsole --hold -e "$WAYDROID_INSTALLER" "$UNINSTALL_OPTION" &
				exit 0
			else
				zenity --error --title "Waydroid Toolbox" --width 650 --height 120 \
					--text "Konsole is unavailable. Open a terminal and run:\n\n$WAYDROID_INSTALLER $UNINSTALL_OPTION"
			fi
		fi
	fi
done
