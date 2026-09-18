#!/usr/bin/env bash
set -euo pipefail

log() {
	local RED='\033[0;31m'
	local YELLOW='\033[0;33m'
	local GREEN='\033[0;32m'
	local NC='\033[0m'  # reset color
	local level=${1^^}  # upper case the log level

	case "$level" in
		ERROR) echo -e "${RED}$2${NC}" >&2;;
		WARN)  echo -e "${YELLOW}$2${NC}" >&2;;
		INFO)  echo -e "${GREEN}$2${NC}" >&2;;
		DEBUG) echo -e "${GREEN}$2${NC}" >&2;;
		*)     echo -e "${GREEN}$2${NC}" >&2;; # default to INFO
	esac
}

check_status() {
	local ret=$?

	if [ $ret -ne 0 ]; then
		log ERROR "Command failed (rc=$ret)"
		exit $ret
	fi
}

usage() {
	cat >&2 <<EOF
Usage:
	$0 --node 0|1|2|3 --slot a|b --image <URL|/path/to.img[.xz|.gz]> [--cache <dir>] [--no-shared]

Options:
	--node      Node index (0..3)
	--slot      Boot slot (a|b)
	--image     OS image to flash (URL or local path, .img or .img.xz)
	--cache     Directory to cache images (default: /mnt/downloads/images)
	--help      Show this help message

Examples:
	$0 --node 0 --slot a --image /srv/images/ubuntu-24.04.img.xz
	$0 --node 1 --slot b --image https://example/imgs/raspios.img.xz --cache /srv/images

Notes:
	- The script expects the NVMe drive to have 17 partitions as per the provisioning scheme.
	- The shared partition (p17) is mounted at /mnt/downloads and used to cache images.
	- The image can be a direct URL or a local path. Supported formats are .img and .img.xz.
	- The script will extract .xz images if needed and flash the appropriate partitions.
	- Valid URLs for Raspberry Pi OS and Ubuntu can be used directly.
		https://old-releases.ubuntu.com/releases/24.04/ubuntu-24.04-preinstalled-server-arm64+raspi.img.xz
		https://downloads.raspberrypi.com/raspios_full_arm64/images/raspios_full_arm64-2024-11-19/2024-11-19-raspios-bookworm-arm64-full.img.xz
EOF
	exit 2
}

DEFAULT_URL="https://downloads.raspberrypi.com/raspios_full_arm64/images/raspios_full_arm64-2024-11-19/2024-11-19-raspios-bookworm-arm64-full.img.xz"

mount_shared_partition() {
	local DEVICE="$1"
	local MOUNTPOINT="$2"
	local PART="${DEVICE}p17"

	if [ ! -b "$PART" ]; then
		log ERROR "Shared partition $PART not found."
		exit 1
	fi

	if [ ! -d "$MOUNTPOINT" ]; then
		mkdir -p "$MOUNTPOINT"
	fi

	if mountpoint -q "$MOUNTPOINT"; then
		log INFO "$PART already mounted at $MOUNTPOINT"
		return 0
	fi

	if ! mount "$PART" "$MOUNTPOINT"; then
		log ERROR "Failed to mount $PART at $MOUNTPOINT"
		return 1
	fi

	return 0
}

umount_shared_partition() {
	local MOUNTPOINT="$1"

	if [ ! -d "$MOUNTPOINT" ]; then
		log ERROR "$MOUNTPOINT not a directory"
        fi

	if mountpoint -q "$MOUNTPOINT"; then
		umount "$MOUNTPOINT" || check_status
	fi

	return 0
}

is_url() {
	local URL_PATH="$1"

	case "$URL_PATH" in
		http://*|https://*|ftp://*) return 0 ;;
		*) return 1 ;;
	esac
}

get_os_image() {
	local IMAGE_PARAM="$1"
	local IMAGE_DIR="$2"
	local base_img=""
	local src_is_url=0

	if is_url "$IMAGE_PARAM"; then
		src_is_url=1
	fi

	base_img="$(basename -- "$IMAGE_PARAM")"
	case "$base_img" in
		*.img.xz) ;;					# ok
		*.img) base_img="${base_img%.img}.img.xz" ;;	# enforce xz
		*) : ;;						# allow raw names like 2024-...-img.xz
	esac

	xz_image="${IMAGE_DIR%/}/$base_img"
	local RAW_IMG="${xz_image%.xz}"

	# If image already in the download directory -> use it
	if [ -f "$xz_image" ]; then
		log INFO "$(basename -- "$xz_image") image already in the download directory"
	else
		# If IMAGE_PARAM is a local path to existing file, copy into download directory
		if [ $src_is_url -eq 0 ] && [ -f "$IMAGE_PARAM" ]; then
			cp -f -- "$IMAGE_PARAM" "$xz_image"
		else
			# Use IMAGE_PARAM if URL is valid else DEFAULT_URL
			local url=""
			if [ $src_is_url -eq 1 ]; then
				url="$IMAGE_PARAM"
			else
				url="$DEFAULT_URL"
			fi

			# If even DEFAULT not cached, download it
			if [ ! -f "$xz_image" ]; then
				# If using DEFAULT_URL but name mismatches, correct filenames
				if [ "$url" = "$DEFAULT_URL" ] && [ "$(basename -- "$url")" != "$(basename -- "$xz_image")" ]; then
					xz_image="${IMAGE_DIR%/}/$(basename -- "$url")"
					RAW_IMG="${xz_image%.xz}"
				fi

				log INFO "Downloading $url -> $xz_image"
				if ! curl -L --fail --continue-at - -o "${xz_image}.part" "$url"; then
					rm -f "${xz_image}.part"
					if ! wget -O "${xz_image}.part" "$url"; then
						log ERROR "Download failed: $url"
						exit 1
					fi
				fi
				mv "${xz_image}.part" "$xz_image"
			fi
		fi
	fi

	case "$xz_image" in
		*.img.xz) ;;
		*) log ERROR "Only .img.xz supported. Got: $xz_image"; exit 1 ;;
	esac

	# Extract to RAW_IMG if missing
	if [ ! -f "$RAW_IMG" ]; then
		log INFO "Extracting $(basename -- "$xz_image")..."
		if ! xz -T0 -vdk -- "$xz_image"; then
			log ERROR "Extraction failed: $xz_image"
			exit 1
		fi
	fi

	# Emit RAW .img for caller
	printf '%s\n' "$RAW_IMG"
}

flash_os_image() {
	local DEVICE="$1"
	local RAW_IMG="$2"
	local NODE="$3"
	local SLOT="$4"

	# Map boot and rootfs partitions
	case "$NODE:$SLOT" in
		0:a) BOOT_DEV="${DEVICE}p1";  ROOT_DEV="${DEVICE}p2"  ;;
		0:b) BOOT_DEV="${DEVICE}p3";  ROOT_DEV="${DEVICE}p4"  ;;
		1:a) BOOT_DEV="${DEVICE}p5";  ROOT_DEV="${DEVICE}p6"  ;;
		1:b) BOOT_DEV="${DEVICE}p7";  ROOT_DEV="${DEVICE}p8"  ;;
		2:a) BOOT_DEV="${DEVICE}p9";  ROOT_DEV="${DEVICE}p10" ;;
		2:b) BOOT_DEV="${DEVICE}p11"; ROOT_DEV="${DEVICE}p12" ;;
		3:a) BOOT_DEV="${DEVICE}p13"; ROOT_DEV="${DEVICE}p14" ;;
		3:b) BOOT_DEV="${DEVICE}p15"; ROOT_DEV="${DEVICE}p16" ;;
		*) log ERROR "Invalid node/slot mapping"; exit 5 ;;
	esac

	if [[ ! -b "$BOOT_DEV" || ! -b "$ROOT_DEV" ]]; then
		log ERROR "Target partitions not present.";
		exit 5;
	fi

	# Trim out all CRLF and white spaces characters
	RAW_IMG=$(printf '%s' "$RAW_IMG" | tr -d '\r\n' | xargs)

	# Setup loop device from raw image installation
	LOOP="$(losetup -Pf --show "$RAW_IMG")"; check_status
	log INFO "Loop device $LOOP created for image: $RAW_IMG"

	SRC_BOOT="${LOOP}p1"
	SRC_ROOT="${LOOP}p2"
	if [ ! -b "$SRC_BOOT" ] || [ ! -b "$SRC_ROOT" ]; then
		log ERROR "Image must have boot and root partitions";
		exit 6;
	fi

	log INFO "Flashing boot partition ($SRC_BOOT → $BOOT_DEV)..."
	dd if="$SRC_BOOT" of="$BOOT_DEV" bs=4M conv=fsync status=progress; check_status

	log INFO "Flashing rootfs partition ($SRC_ROOT → $ROOT_DEV)..."
	dd if="$SRC_ROOT" of="$ROOT_DEV" bs=4M conv=fsync status=progress; check_status

	# Cleanup
	losetup -d "$LOOP"

	# Before resizing, unmount rootfs if mounted
	if mount | grep -q "$ROOT_DEV"; then
		echo "Unmounting $ROOT_DEV before resize..."
		umount "$ROOT_DEV" || umount -l "$ROOT_DEV"
	fi

	# Resize rootfs
	log INFO "Resizing rootfs on $ROOT_DEV..."
	e2fsck -fy "$ROOT_DEV" || true
	resize2fs "$ROOT_DEV"; check_status

	# Assign new UUID to avoid NFS filehandle collisions
	log INFO "Assigning unique filesystem UUID to $ROOT_DEV..."
	tune2fs -U random "$ROOT_DEV"

	log INFO "Image successfully flashed to node$NODE, boot slot [$SLOT]."
}

cleanup_raw_image() {
	local os_raw_image="$1"

	if [ -n "$os_raw_image" ] && [ -f "$os_raw_image" ]; then
		log INFO "Removing raw image to save space: $os_raw_image"
		rm -f -- "$os_raw_image"
	fi
}

NODE=""                         # 0..3
SLOT=""                         # a|b
IMAGE=""                        # URL or local path (.img or .img.{xz,gz})
CACHE="/mnt/downloads"		# images container on shared p17 partition
NVME_DEV="/dev/nvme0n1"		# NVMe device to provision

while [[ $# -gt 0 ]]; do
	case "$1" in
		--node)  NODE="$2"; shift 2 ;;
		--slot)  SLOT="$2"; shift 2 ;;
		--image) IMAGE="$2"; shift 2 ;;
		--cache) CACHE="$2"; shift 2 ;;
		--device) NVME_DEV="$2"; shift 2 ;;
		-h|--help) usage ;;
		*) log ERROR "Unknown arg: $1"; usage ;;
	esac
done

case "$NODE" in
	node[0-3])      NODE="${NODE#node}" ;;
	rpi-node[0-3])  NODE="${NODE#rpi-node}" ;;
esac
if [[ ! "$NODE" =~ ^[0-3]$ ]]; then
	log ERROR "--node must be 0..3";
	usage;
fi

if [[ ! "$SLOT" =~ ^[ab]$ ]]; then
	log ERROR "--slot must be a|b";
	usage;
fi

if [ -z "$IMAGE" ]; then
	log ERROR "--image is required";
	usage;
fi

if [[ ! "$IMAGE" =~ \.img(\.xz)?$ ]]; then
	log ERROR "--image must end in .img or .img.xz"
	usage
fi

if [ ! -b "$NVME_DEV" ]; then
	log ERROR "Device $NVME_DEV not found or not a block device"
	usage
fi

mount_shared_partition "$NVME_DEV" "$CACHE"

# Obtain the image to be flashed
OS_RAW_IMAGE=$(get_os_image "$IMAGE" "$CACHE")
if [[ -z "$OS_RAW_IMAGE" ]]; then
	log ERROR "No valid image to flash"
	exit 1
fi

# Flash the NVMe partition giving the parameters
flash_os_image "$NVME_DEV" "$OS_RAW_IMAGE" "$NODE" "$SLOT"
log INFO "Flashing "$(basename "${OS_RAW_IMAGE}")" on node${NODE}, boot slot $SLOT done"

#log INFO "Cleaning $(basename "${OS_RAW_IMAGE}") image"
cleanup_raw_image "$OS_RAW_IMAGE"

umount_shared_partition "$CACHE"