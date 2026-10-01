#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_non_root
require_command curl
require_command jq
require_command zstd
require_command losetup
require_command lsblk
require_command mount
require_command umount
require_command mountpoint
require_command rsync
require_command sudo
require_command sha256sum

META_BASE="${STEAMOS_ATOMUPD_META_BASE:-https://steamdeck-atomupd.steamos.cloud/meta/steamos/amd64/3.5.6}"
IMAGE_BASE="${STEAMOS_IMAGE_BASE:-https://steamdeck-images.steamos.cloud}"
IMAGE_CACHE_ROOT="${STEAMOS_IMAGE_CACHE_ROOT:-$BUILD_WORK_ROOT/images}"

declare -a CHANNEL_NAMES=(Stable Beta Preview Main)
declare -a CHANNEL_FILES=(
	steamdeck.json
	steamdeck-beta.json
	steamdeck-preview.json
	steamdeck-main.json
)
#declare -a CHANNEL_JSON=()
declare -a CHANNEL_VERSIONS=()
declare -a CHANNEL_BUILDIDS=()
declare -a CHANNEL_VARIANTS=()
declare -a CHANNEL_UPDATE_PATHS=()

LOOP_DEVICE=""
IMAGE_MOUNT=""
VAR_MOUNTED=false
CHROOT_API_MOUNTS=()

cleanup() {
	local status=$?
	set +e

	if [[ -n "$IMAGE_MOUNT" ]]; then
		local i
		for ((i = ${#CHROOT_API_MOUNTS[@]} - 1; i >= 0; i--)); do
			if mountpoint -q "${CHROOT_API_MOUNTS[$i]}"; then
				sudo umount -R "${CHROOT_API_MOUNTS[$i]}" 2>/dev/null || sudo umount -l "${CHROOT_API_MOUNTS[$i]}" 2>/dev/null || true
			fi
		done

		if $VAR_MOUNTED && mountpoint -q "$IMAGE_MOUNT/var"; then
			sudo umount "$IMAGE_MOUNT/var"
		fi
		if mountpoint -q "$IMAGE_MOUNT"; then
			sudo umount "$IMAGE_MOUNT"
		fi
		rmdir "$IMAGE_MOUNT" 2>/dev/null || true
	fi

	if [[ -n "$LOOP_DEVICE" ]]; then
		sudo losetup -d "$LOOP_DEVICE" 2>/dev/null || true
	fi

	exit "$status"
}
trap cleanup EXIT INT TERM

fetch_channel_metadata() {
	local i json version buildid variant update_path

	printf 'Querying current SteamOS channels...\n'
	for i in "${!CHANNEL_FILES[@]}"; do
		json="$(curl -fsSL --retry 3 \
			"$META_BASE/${CHANNEL_FILES[$i]}")" ||
			die "failed to query ${CHANNEL_NAMES[$i]} metadata"

		version="$(jq -er '.minor.candidates[0].image.version' <<<"$json")" ||
			die "could not read ${CHANNEL_NAMES[$i]} version from Valve metadata"
		buildid="$(jq -er '.minor.candidates[0].image.buildid' <<<"$json")" ||
			die "could not read ${CHANNEL_NAMES[$i]} build ID from Valve metadata"
		variant="$(jq -er '.minor.candidates[0].image.variant' <<<"$json")" ||
			die "could not read ${CHANNEL_NAMES[$i]} variant from Valve metadata"
		update_path="$(jq -er '.minor.candidates[0].update_path' <<<"$json")" ||
			die "could not read ${CHANNEL_NAMES[$i]} update path from Valve metadata"

		#        CHANNEL_JSON[$i]="$json"
		CHANNEL_VERSIONS[$i]="$version"
		CHANNEL_BUILDIDS[$i]="$buildid"
		CHANNEL_VARIANTS[$i]="$variant"
		CHANNEL_UPDATE_PATHS[$i]="$update_path"
	done
}

select_channel() {
	local choice

	printf '\nSelect which version to download:\n'
	for i in "${!CHANNEL_NAMES[@]}"; do
		printf '[%d] %-8s %s  (build %s)\n' \
			"$((i + 1))" \
			"${CHANNEL_NAMES[$i]}:" \
			"${CHANNEL_VERSIONS[$i]}" \
			"${CHANNEL_BUILDIDS[$i]}"
	done
	printf '\n'

	while true; do
		read -r -p 'Selection [1-4]: ' choice
		case "$choice" in
		1 | 2 | 3 | 4)
			SELECTED_INDEX=$((choice - 1))
			return
			;;
		*)
			printf 'Please enter 1, 2, 3 or 4.\n' >&2
			;;
		esac
	done
}

resolve_image_url() {
	local update_path update_dir

	SELECTED_CHANNEL="${CHANNEL_NAMES[$SELECTED_INDEX]}"
	SELECTED_VERSION="${CHANNEL_VERSIONS[$SELECTED_INDEX]}"
	SELECTED_BUILDID="${CHANNEL_BUILDIDS[$SELECTED_INDEX]}"
	SELECTED_VARIANT="${CHANNEL_VARIANTS[$SELECTED_INDEX]}"
	update_path="${CHANNEL_UPDATE_PATHS[$SELECTED_INDEX]}"
	update_dir="${update_path%/*}"

	IMAGE_FILENAME="${SELECTED_VARIANT}-${SELECTED_BUILDID}-${SELECTED_VERSION}.img.zst"
	IMAGE_URL="$IMAGE_BASE/$update_dir/$IMAGE_FILENAME"
	IMAGE_DIR="$IMAGE_CACHE_ROOT/$SELECTED_BUILDID"
	COMPRESSED_IMAGE="$IMAGE_DIR/$IMAGE_FILENAME"
	RAW_IMAGE="${COMPRESSED_IMAGE%.zst}"

	printf '\nSelected %s %s (build %s)\n' \
		"$SELECTED_CHANNEL" "$SELECTED_VERSION" "$SELECTED_BUILDID"
	printf 'Image URL:\n  %s\n' "$IMAGE_URL"

	# atomupd points at the .raucb. Full .img.zst images normally use the same
	# build directory and versioned basename, but not every development build
	# is guaranteed to publish one. Fail clearly before doing any large work.
	curl -fsSIL --retry 3 "$IMAGE_URL" >/dev/null ||
		die "Valve does not appear to publish a full .img.zst for this build: $IMAGE_URL"
}

download_and_decompress_image() {
	mkdir -p "$IMAGE_DIR"

	if [[ -s "$COMPRESSED_IMAGE" ]]; then
		printf 'Using cached compressed image:\n  %s\n' "$COMPRESSED_IMAGE"
	else
		printf 'Downloading SteamOS image...\n'
		curl -fL --retry 3 --continue-at - \
			--output "$COMPRESSED_IMAGE" \
			"$IMAGE_URL"
	fi

	printf 'Compressed image SHA-256:\n'
	sha256sum "$COMPRESSED_IMAGE"

	if [[ -s "$RAW_IMAGE" && "$RAW_IMAGE" -nt "$COMPRESSED_IMAGE" ]]; then
		printf 'Using cached decompressed image:\n  %s\n' "$RAW_IMAGE"
	else
		printf 'Decompressing image...\n'
		zstd -d -f --keep "$COMPRESSED_IMAGE" -o "$RAW_IMAGE"
	fi
}

attach_and_mount_image() {
	local root_part var_part

	printf 'Attaching image read-only...\n'
	LOOP_DEVICE="$(sudo losetup --find --show --partscan --read-only "$RAW_IMAGE")"
	[[ -n "$LOOP_DEVICE" ]] || die "losetup did not return a loop device"

	# Wait for partition probing and udev metadata before reading PARTLABELs.
	sudo partprobe "$LOOP_DEVICE" 2>/dev/null || true
	sudo udevadm settle

	root_part="$(
		lsblk -nrpo NAME,PARTLABEL "$LOOP_DEVICE" |
			awk '$2 == "rootfs-A" {print $1; exit}'
	)"
	[[ -n "$root_part" ]] || {
		lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTLABEL "$LOOP_DEVICE" >&2
		die "could not find the rootfs-A partition"
	}

	var_part="$(
		lsblk -nrpo NAME,PARTLABEL "$LOOP_DEVICE" |
			awk '$2 == "var-A" {print $1; exit}'
	)"

	IMAGE_MOUNT="$(mktemp -d "$BUILD_WORK_ROOT/.steamos-image-mount.XXXXXX")"
	sudo mount -o ro "$root_part" "$IMAGE_MOUNT"

	if [[ -n "$var_part" ]]; then
		sudo mkdir -p "$IMAGE_MOUNT/var"
		sudo mount -o ro "$var_part" "$IMAGE_MOUNT/var"
		VAR_MOUNTED=true
	fi

	[[ -x "$IMAGE_MOUNT/usr/bin/bash" ]] ||
		die "mounted image does not contain /usr/bin/bash"
	[[ -r "$IMAGE_MOUNT/etc/os-release" ]] ||
		die "mounted image does not contain /etc/os-release"
}

mount_chroot_api_filesystems() {
	local fs target

	printf 'Mounting temporary chroot API filesystems...\n'

	# The SteamOS root partitions stay read-only. These are separate bind
	# mounts layered over the image's empty/static mount points so programs
	# inside chroot have working /dev/null, /dev/stdout, /proc, etc.
	for fs in dev proc sys run; do
		target="$IMAGE_MOUNT/$fs"
		sudo mkdir -p "$target"
		sudo mount --rbind "/$fs" "$target"
		sudo mount --make-rslave "$target"
		CHROOT_API_MOUNTS+=("$target")
	done
}

capture_target_fingerprint() {
	local fingerprint_capture suggested_bundle_version target_environment_id
	local image_kernel

	printf 'Capturing SteamOS userspace ABI fingerprint from the image...\n'
	fingerprint_capture="$(mktemp "$BUILD_WORK_ROOT/.target-fingerprint.XXXXXX")"

	# This is deliberately the same fingerprint collector used by the SSH sync.
	# pacman and /etc/os-release are therefore read from the image itself.
	# Input/output redirection is intentionally handled by the invoking shell.
	# shellcheck disable=SC2024
	sudo chroot "$IMAGE_MOUNT" \
		/usr/bin/env \
		FINGERPRINT_RUN_MAIN=1 \
		WLROOTS_VERSION="$WLROOTS_VERSION" \
		BUNDLE_REVISION="$BUNDLE_REVISION" \
		/usr/bin/bash -s -- collect \
		<"$REPO_ROOT/libexec/steamos-waydroid/lib/target-fingerprint.sh" \
		>"$fingerprint_capture"

	# uname(2) is not namespaced by chroot, so the collector above sees the
	# Fedora host kernel. Replace only the informational KERNEL_RELEASE field
	# with the kernel shipped in the image when it can be identified.
	image_kernel="$(
		find "$IMAGE_MOUNT/usr/lib/modules" \
			-mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null |
			sort -V |
			tail -n 1
	)"
	if [[ -n "$image_kernel" ]]; then
		sed -i "s/^KERNEL_RELEASE=.*/KERNEL_RELEASE=$image_kernel/" \
			"$fingerprint_capture"
	fi

	suggested_bundle_version="$(
		awk -F= '$1 == "SUGGESTED_BUNDLE_VERSION" {print $2; exit}' \
			"$fingerprint_capture"
	)"
	[[ -n "$suggested_bundle_version" ]] ||
		die "captured target fingerprint is incomplete"

	target_environment_id="$(
		awk -F= '$1 == "TARGET_ENVIRONMENT_ID" {print $2; exit}' \
			"$fingerprint_capture"
	)"
	[[ -n "$target_environment_id" ]] ||
		die "captured target environment ID is missing"

	install -m 0644 "$fingerprint_capture" "$TARGET_FINGERPRINT_FILE"
	rm -f -- "$fingerprint_capture"

	TARGET_WORK_ROOT="$TARGETS_ROOT/$target_environment_id"
	SNAPSHOT_ROOT="$TARGET_WORK_ROOT/snapshot"
	ROOTFS_ROOT="$TARGET_WORK_ROOT/rootfs"
	TARGET_VERSION_FINGERPRINT="$TARGET_WORK_ROOT/target-fingerprint.env"

	mkdir -p "$TARGET_WORK_ROOT"
	install -m 0644 "$TARGET_FINGERPRINT_FILE" "$TARGET_VERSION_FINGERPRINT"

	printf 'Target bundle version: %s\n' "$suggested_bundle_version"
	printf 'Target environment: %s\n' "$target_environment_id"
}

detect_pacman_db_path() {
	printf 'Detecting the SteamOS pacman database path inside the image...\n'
	PACMAN_DB_PATH="$(
		sudo chroot "$IMAGE_MOUNT" /usr/bin/pacman-conf DBPath |
			head -n 1
	)"
	PACMAN_DB_PATH="${PACMAN_DB_PATH%/}"

	case "$PACMAN_DB_PATH" in
	/var/* | /usr/*) ;;
	*) die "image returned an unsafe or unsupported pacman DBPath: $PACMAN_DB_PATH" ;;
	esac
	if [[ "$PACMAN_DB_PATH" == *'/../'* || "$PACMAN_DB_PATH" == */.. ]]; then
		die "image returned an unsafe pacman DBPath: $PACMAN_DB_PATH"
	fi
	[[ -d "$IMAGE_MOUNT$PACMAN_DB_PATH" ]] ||
		die "pacman DBPath is missing from mounted image: $PACMAN_DB_PATH"

	printf 'Pacman database: %s\n' "$PACMAN_DB_PATH"
}

create_snapshot_and_rootfs() {
	printf 'Creating image-derived SteamOS snapshot...\n'

	# The target environment ID constrains these paths beneath TARGETS_ROOT.
	sudo rm -rf -- "$SNAPSHOT_ROOT" "$ROOTFS_ROOT"
	sudo mkdir -p \
		"$SNAPSHOT_ROOT/usr" \
		"$SNAPSHOT_ROOT/etc" \
		"$SNAPSHOT_ROOT$PACMAN_DB_PATH" \
		"$ROOTFS_ROOT"

	printf 'Copying /usr from the mounted Valve image...\n'
	sudo rsync -aH --info=progress2 \
		--exclude='/bin/cupsd' \
		--exclude='/bin/groupmems' \
		--exclude='/bin/mount.nfs' \
		--exclude='/lib/dbus-daemon-launch-helper' \
		--exclude='/lib/cups/backend/cups-pdf' \
		--exclude='/lib/ssh/ssh-keysign' \
		--exclude='/share/ModemManager/' \
		--exclude='/share/factory/' \
		"$IMAGE_MOUNT/usr/" \
		"$SNAPSHOT_ROOT/usr/"

	printf 'Copying the pacman database from the image...\n'
	sudo rsync -aH --info=progress2 \
		"$IMAGE_MOUNT$PACMAN_DB_PATH/" \
		"$SNAPSHOT_ROOT$PACMAN_DB_PATH/"

	printf 'Copying build-relevant /etc configuration from the image...\n'
	sudo rsync -aH --info=progress2 \
		--exclude='/pacman.d/gnupg/' \
		--include='/os-release' \
		--include='/arch-release' \
		--include='/passwd' \
		--include='/group' \
		--include='/nsswitch.conf' \
		--include='/hosts' \
		--include='/hostname' \
		--include='/resolv.conf' \
		--include='/localtime' \
		--include='/mtab' \
		--include='/pacman.conf' \
		--include='/pacman.d/***' \
		--include='/makepkg.conf' \
		--include='/makepkg.conf.d/***' \
		--include='/ld.so.conf' \
		--include='/ld.so.conf.d/***' \
		--include='/ssl/' \
		--include='/ssl/cert.pem' \
		--include='/ssl/certs/' \
		--include='/ssl/certs/ca-bundle.crt' \
		--include='/ssl/certs/ca-certificates.crt' \
		--include='/ssl/certs/java/' \
		--include='/ssl/certs/java/README' \
		--include='/ca-certificates/' \
		--include='/ca-certificates/***' \
		--exclude='*' \
		"$IMAGE_MOUNT/etc/" \
		"$SNAPSHOT_ROOT/etc/"

	printf 'Materialising the rootfs with root ownership...\n'
	sudo rsync -aH "$SNAPSHOT_ROOT/" "$ROOTFS_ROOT/"
	sudo chown -R root:root "$ROOTFS_ROOT"

	printf '%s\n' 'STEAMOS_WAYDROID_COPIED_BUILD_ROOT=1' |
		sudo tee "$ROOTFS_ROOT/.steamos-waydroid-copied-build-root" >/dev/null
	sudo chmod 0644 "$ROOTFS_ROOT/.steamos-waydroid-copied-build-root"

	sudo install -d -m 0755 \
		"$ROOTFS_ROOT/dev" \
		"$ROOTFS_ROOT/proc" \
		"$ROOTFS_ROOT/sys" \
		"$ROOTFS_ROOT/run" \
		"$ROOTFS_ROOT/home" \
		"$ROOTFS_ROOT/root" \
		"$ROOTFS_ROOT/opt"
	sudo install -d -m 1777 "$ROOTFS_ROOT/tmp"

	sudo ln -sfn usr/bin "$ROOTFS_ROOT/bin"
	sudo ln -sfn usr/bin "$ROOTFS_ROOT/sbin"
	sudo ln -sfn usr/lib "$ROOTFS_ROOT/lib"
	sudo ln -sfn usr/lib "$ROOTFS_ROOT/lib64"
}

main() {
	mkdir -p "$BUILD_WORK_ROOT" "$TARGETS_ROOT" "$IMAGE_CACHE_ROOT"

	fetch_channel_metadata
	select_channel
	resolve_image_url
	download_and_decompress_image
	attach_and_mount_image
	mount_chroot_api_filesystems
	capture_target_fingerprint
	detect_pacman_db_path
	create_snapshot_and_rootfs

	printf '\nSteamOS image cached at:\n  %s\n' "$COMPRESSED_IMAGE"
	printf 'Decompressed image cached at:\n  %s\n' "$RAW_IMAGE"
	printf 'SteamOS build root created at:\n  %s\n' "$ROOTFS_ROOT"
	printf 'Target fingerprint created at:\n  %s\n' "$TARGET_FINGERPRINT_FILE"
	printf 'Versioned target environment:\n  %s\n' "$TARGET_WORK_ROOT"
	printf '\nNext:\n'
	printf '  %s/enter-build-rootfs.sh\n' "$SCRIPT_DIR"
}

main "$@"
