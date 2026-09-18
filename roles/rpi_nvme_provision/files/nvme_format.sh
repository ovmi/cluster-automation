#!/usr/bin/env bash
set -euo pipefail

# Simple NVMe layout creator for Raspberry Pi cluster (node0..node3, A/B)
# WARNING: This ERASES ALL DATA on the target device.
#
# Layout (GPT):
#  1:  boot-node0-A   (FAT32 512M)
#  2:  root-node0-A   (ext4  28G)
#  3:  boot-node0-B   (FAT32 512M)
#  4:  root-node0-B   (ext4  28G)
#  5:  boot-node1-A   (FAT32 512M)
#  6:  root-node1-A   (ext4  28G)
#  7:  boot-node1-B   (FAT32 512M)
#  8:  root-node1-B   (ext4  28G)
#  9:  boot-node2-A   (FAT32 512M)
# 10:  root-node2-A   (ext4  28G)
# 11:  boot-node2-B   (FAT32 512M)
# 12:  root-node2-B   (ext4  28G)
# 13:  boot-node3-A   (FAT32 512M)
# 14:  root-node3-A   (ext4  28G)
# 15:  boot-node3-B   (FAT32 512M)
# 16:  root-node3-B   (ext4  28G)
# 17:  shared         (ext4  rest of disk, optional)
#
# Usage:
#   nvme_format.sh [/dev/nvme0n1] [--yes]
#
# Notes:
# - Fixed sizes for simplicity: adjust BOOT_SIZE and ROOT_SIZE if needed.
# - Use --yes for non-interactive (Ansible) runs.

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
  cat <<EOF
Usage: $0 [DEVICE] [--yes|--no]

Partition and format an NVMe drive for Raspberry Pi cluster nodes.
WARNING: This will ERASE ALL DATA on the target device!

Arguments:
  DEVICE       NVMe device path (default: /dev/nvme0n1)
  --yes        Proceed with destructive partitioning and formatting
  --no         Do not partition; just show what would be done

Notes:
  - Creates 16 partitions (4 nodes × A/B boot+root)
    ${BOOT_SIZE} vfat  for each boot partition
    ${ROOT_SIZE} ext4  for each root partition
  - Partition 17 (optional) is created with the remaining space as ext4 "shared"
  - Boot partitions are labeled:  boot-node{0..3}-{A|B}
  - Root partitions are labeled:  root-node{0..3}-{A|B}
  - Shared partition is labeled:  shared

Examples:
    $0 --device /dev/nvme0n1 --format no

  Create full layout including shared partition:
    $0 --device /dev/nvme0n1 --format yes

  Create only the 16 node partitions (skip shared):
    $0 --device /dev/nvme0n1 --format yes
EOF
  exit 1
}

NVME_DEV="/dev/nvme0n1"
CONFIRM="no"
BOOT_SIZE="512M"
ROOT_SIZE="28G"

while [[ $# -gt 0 ]]; do
	case "$1" in
		-d|--device) NVME_DEV="$2"; shift 2 ;;
    -f|--format) CONFIRM="$2"; shift 2 ;;
		-h|--help) usage ;;
		*) log ERROR "Unknown arg: $1"; usage ;;
	esac
done

if [ ! -b "$NVME_DEV" ]; then
  log ERROR "Device $NVME_DEV not found or not a block device"
  usage
fi

# Refuse to run unless --yes is provided (safety)
if [[ "${CONFIRM}" != "yes" && "${CONFIRM}" != "y" ]]; then
  echo "Not going to run without --yes (this will destroy data on ${NVME_DEV})."
  exit 0
fi

# Ensure no partitions are mounted
if lsblk -no MOUNTPOINT "${NVME_DEV}"* | grep -q '/'; then
  echo "ERROR: ${NVME_DEV} has mounted partitions. Unmount them first."
  exit 1
fi

echo "Deleting and partitioning ${NVME_DEV}..."
# New GPT to support up to 128 partitions
if ! parted -s "${NVME_DEV}" mklabel gpt; then
  echo "ERROR: Failed to create new partition table on ${NVME_DEV}."
  exit 1
fi

# Create partitions with sgdisk (simple explicit layout)
sgdisk \
  -n 1:0:+${BOOT_SIZE} -t 1:EF00 -c 1:"boot-node0-A" \
  -n 2:0:+${ROOT_SIZE} -t 2:8300 -c 2:"root-node0-A" \
  -n 3:0:+${BOOT_SIZE} -t 3:EF00 -c 3:"boot-node0-B" \
  -n 4:0:+${ROOT_SIZE} -t 4:8300 -c 4:"root-node0-B" \
  -n 5:0:+${BOOT_SIZE} -t 5:EF00 -c 5:"boot-node1-A" \
  -n 6:0:+${ROOT_SIZE} -t 6:8300 -c 6:"root-node1-A" \
  -n 7:0:+${BOOT_SIZE} -t 7:EF00 -c 7:"boot-node1-B" \
  -n 8:0:+${ROOT_SIZE} -t 8:8300 -c 8:"root-node1-B" \
  -n 9:0:+${BOOT_SIZE} -t 9:EF00 -c 9:"boot-node2-A" \
  -n 10:0:+${ROOT_SIZE} -t 10:8300 -c 10:"root-node2-A" \
  -n 11:0:+${BOOT_SIZE} -t 11:EF00 -c 11:"boot-node2-B" \
  -n 12:0:+${ROOT_SIZE} -t 12:8300 -c 12:"root-node2-B" \
  -n 13:0:+${BOOT_SIZE} -t 13:EF00 -c 13:"boot-node3-A" \
  -n 14:0:+${ROOT_SIZE} -t 14:8300 -c 14:"root-node3-A" \
  -n 15:0:+${BOOT_SIZE} -t 15:EF00 -c 15:"boot-node3-B" \
  -n 16:0:+${ROOT_SIZE} -t 16:8300 -c 16:"root-node3-B" \
  -n 17:0:0             -t 17:8300 -c 17:"Shared Storage" \
  "${NVME_DEV}"

echo "Formatting filesystems..."
for i in $(seq 1 16); do
  part="${NVME_DEV}p${i}"
  if (( i % 2 == 1 )); then
    mkfs.vfat -F32 "${part}"
  else
    mkfs.ext4 -F "${part}"
  fi
done
mkfs.ext4 -F -L "shared" "${NVME_DEV}p17"

lsblk -o NAME,SIZE,FSTYPE,LABEL "${NVME_DEV}"

echo "NVMe partitioning complete"
