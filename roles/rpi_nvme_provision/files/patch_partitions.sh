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
  $0 --node 0|1|2|3 --slot a|b --mode nvme|nfs --boot <boot-partition> --root <root-partition>
        [--nfs-server <ip>] [--nfs-base <path>]

Options:
  -n, --node    Node index (0..3)
  -s, --slot    Boot slot (a|b)
  -m, --mode    Operating mode:
                  nvme  -> system boots from NVMe rootfs
                  nfs   -> system boots with rootfs over NFS
  -b, --boot    Path to boot partition device (e.g. /dev/nvme0n1p1)
  -r, --root    Path to rootfs partition device (e.g. /dev/nvme0n1p2)
  -h, --help    Show this help message

What it does:
  • Mounts the given boot and root partitions
  • Patches cmdline.txt (console + root device or NFS root)
  • Patches config.txt (ensures [all], uart0 enabled)
  • Touches 'ssh' in bootfs to enable SSH on first boot
  • Adds node-specific user (nodeX) with sudo privileges
  • Sets hostname (raspi-nodeX)
  • Updates /etc/fstab to match the chosen mode

Examples:
  NVMe boot (node0, slot a):
    $0 --node 0 --slot a --mode nvme --boot /dev/nvme0n1p1 --root /dev/nvme0n1p2

  NFS boot (node1, slot a):
    $0 --node 1 --slot a --mode nfs --boot /dev/nvme0n1p5 --root /dev/nvme0n1p6

Notes:
  - Run as root (mount and chroot required).
  - The partitions must already exist and be formatted.
  - NFS mode will patch cmdline.txt accordingly; fstab entries for NFS
    can be extended in patch_rootfs().
EOF
	exit 2
}

NODE=""                       # 0..3
SLOT=""                       # a|b
MODE=""                       # nvme|nfs
BOOT=""                       # e.g. /dev/nvme0n1pX
ROOT=""                       # e.g. /dev/nvme0n1pX
NFS_SERVER="192.168.100.10"
NFS_EXPORT_BASE="/srv/nfs"    # final path becomes ${NFS_EXPORT_BASE}/node${NODE}

BOOTARGS_RASPBIAN="console=ttyAMA0,115200 console=tty1" # init=/usr/lib/raspberrypi-sys-mods/firstboot
BOOTARGS_UBUNTU="console=ttyAMA0,115200 console=tty1 systemd.gpt_auto=no"
BOOTARGS_EXTRA="rw"

while [[ $# -gt 0 ]]; do
	case "$1" in
		-n|--node)  NODE="$2"; shift 2 ;;
		-s|--slot)  SLOT="$2"; shift 2 ;;
		-m|--mode)  MODE="$2"; shift 2 ;;
		-b|--boot)  BOOT="$2"; shift 2 ;;
    -r|--root)  ROOT="$2"; shift 2 ;;
    --nfs-server) NFS_SERVER="${2:-}"; shift 2;;
    --nfs-base)   NFS_EXPORT_BASE="${2:-}"; shift 2;;
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
if [[ ! "$MODE" =~ ^(nvme|nfs)$ ]]; then
	log ERROR "--mode must be nvme|nfs";
	usage;
fi

detect_os_type() {
  local root_mnt="$1"

  if [[ -f "$root_mnt/etc/lsb-release" ]]; then
    if grep -qi "ubuntu" "$root_mnt/etc/lsb-release"; then
      echo "ubuntu"
      return
    fi
  fi

  if [[ -f "$root_mnt/etc/os-release" ]]; then
    if grep -qi "raspbian" "$root_mnt/etc/os-release"; then
      echo "raspbian"
      return
    fi
    if grep -qi "debian" "$root_mnt/etc/os-release"; then
      echo "debian"
      return
    fi
  fi

  echo "unknown"
}

patch_bootfs() {
  local boot_dev="$1"
  local root_dev="$2"
  local root_mode="$3"
  local os_type="unknown"
  local boot_uuid=$(blkid -s PARTUUID -o value "$boot_dev" 2>/dev/null || true)
  local root_uuid=$(blkid -s PARTUUID -o value "$root_dev" 2>/dev/null || true)
  local tmp_mount=$(mktemp -d)

  if [[ ! -d "$tmp_mount" ]]; then
    log ERROR "Failed to create temporary mount directory: $tmp_mount"
    exit 1
  fi

  echo "Checking root filesystem..."
  e2fsck -fy "$root_dev" || {
    echo "WARNING: e2fsck reported issues on $root_dev"
  }

  # Temporarily mount the root partition
  mount -o rw,nosuid,nodev,noexec "$root_dev" "$tmp_mount"

  log INFO "Detecting OS type from rootfs..."
  os_type=$(detect_os_type "$tmp_mount")
  log INFO "Detected OS: $os_type"

  # Cleanup temporarly mounted rootfs
  umount "$tmp_mount"

  echo "Checking boot filesystem..."
  fsck.vfat -a "$boot_dev" || {
    echo "WARNING: fsck.vfat reported issues on $boot_dev"
  }

  # Patch boot partition
  mount -o rw,nosuid,nodev,noexec "$boot_dev" "$tmp_mount"

  log INFO "Patching boot "$boot_dev" "$tmp_mount"..."
  log INFO "Patching cmdline.txt for node${NODE}"

  # Read existing cmdline (always one line)
  cmdline_file="$tmp_mount/cmdline.txt"
  [[ -f "$cmdline_file" ]] || touch "$cmdline_file"
  cmdline=$(tr -d '\n' < "$cmdline_file")

  # Remove old root= or nfsroot= or custom args to avoid duplicates
  cmdline=$(echo "$cmdline" \
      | sed -E "s|root=[^ ]+||g" \
      | sed -E "s|nfsroot=[^ ]+||g" \
      | sed -E "s|cma=[^ ]+||g" \
      | sed -E "s|ipv6.disable=[^ ]+||g" \
      | sed -E "s|slot=[^ ]+||g" \
  )

  # Pick OS-specific bootargs
  case "$os_type" in
      ubuntu)           BASE_BOOTARGS="$BOOTARGS_UBUNTU";;
      raspbian|debian)  BASE_BOOTARGS="$BOOTARGS_RASPBIAN";;
      *)                BASE_BOOTARGS="$BOOTARGS_RASPBIAN";
                        log WARN "Unknown OS; using RaspbianOS by default";;
  esac

  # Choose rootfs mode
  if [[ "$root_mode" == "nvme" ]]; then
      ROOTARG="root=PARTUUID=${root_uuid}"
  else # root_mode == "nfs"
      ROOTARG="root=/dev/nfs nfsroot=${NFS_SERVER}:${NFS_PATH},vers=3,tcp ip=dhcp rootwait panic=30"
  fi

  # Build the final cmdline
  cmdline_new="$BASE_BOOTARGS $ROOTARG $BOOTARGS_EXTRA"

  # Normalize whitespace
  cmdline_new="$(echo "$cmdline_new" | tr -s ' ' | sed 's/^ //; s/ $//')"

  # Replace "console=serial0" with "ttyAMA0" if present
  cmdline_new="$(echo "$cmdline_new" | sed -E 's/(console=)serial0/\1ttyAMA0/g')"

  # Write back
  echo "$cmdline_new" > "$cmdline_file"
  log INFO "Final cmdline: $cmdline_new"

  # Set the ownership of cmdline.txt to the new user
  #chroot "$tmp_mount" chown -R "$NEW_USER:$NEW_USER" "$tmp_mount/cmdline.txt"

  log INFO "Patching config.txt for node${NODE}"
  if [ -f "$tmp_mount/config.txt" ]; then
    # Append `[all]` in case not found
    if ! grep -q "^\[all\]" "$tmp_mount/config.txt"; then
      echo "[all]" | tee -a "$tmp_mount/config.txt" > /dev/null
    fi

    # Append `dtparam=uart0=on` if it's not already present
    if ! grep -Fxq "dtparam=uart0=on" "$tmp_mount/config.txt"; then
      echo "dtparam=uart0=on" | sudo tee -a "$tmp_mount/config.txt" > /dev/null
    fi
  else
    log ERROR "Missing config.txt on boot partition";
    umount "$tmp_mount"
    rm -rf "$tmp_mount"
    exit 1
  fi

  # Create a new file on boot fs to enable ssh
  touch "$tmp_mount/ssh"

  # Cleanup
  umount "$tmp_mount"
  rm -rf "$tmp_mount"
}

create_user_in_rootfs() {
  local root_mnt="$1"
  local user="$2"
  local uid=$((1000 + NODE))   # node1->1001, node2->1002, ...
  local gid=$uid
  local uid1000
  local existing_user

  # Helpers to query inside the chroot
  in_root() { chroot "$root_mnt" "$@"; }

  # Determine existing UID 1000 (if any)
  uid1000="$(in_root getent passwd 1000 | cut -d: -f1 || true)"

  # Check if UID already exists (e.g. default user = 1000), delete it
  existing_user="$(in_root getent passwd "$uid" | cut -d: -f1 || true)"
  if [[ -n "$existing_user" ]]; then
    in_root userdel -r "$existing_user" 2>/dev/null || true
  fi

  # Ensure the primary group
  in_root groupdel "$user" 2>/dev/null || true
  in_root groupadd -g "$uid" "$user"

  # Create the new user with correct UID/GID
  in_root useradd -m -u "$uid" -g "$user" -s /bin/bash "$user"

  # Ensure home permissions
  in_root chmod 700 "/home/$user" || true
  in_root chown -R "$user:$user" "/home/$user" || true

  # Add user to sudo group (Debian/Ubuntu use 'sudo')
  in_root usermod -aG sudo "$user"

  # Set password = user:user
  echo "${user}:${user}" | in_root chpasswd
  echo "Created user '$user' with UID=$uid in $root_mnt"
}

patch_rootfs() {
  local boot_dev="$1"
  local root_dev="$2"
  local root_mode="$3"
  local boot_uuid=$(blkid -s PARTUUID -o value "$boot_dev")
  local root_uuid=$(blkid -s PARTUUID -o value "$root_dev")
  local home_dir=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)
  local tmp_mount=$(mktemp -d)
  local os_type="unknown"
  local boot_mnt="/boot"

  # Patch rootfs partition
  mount "$root_dev" "$tmp_mount"
  if [[ ! -d "$tmp_mount" ]]; then
    log ERROR "Failed to create temporary mount directory: $tmp_mount"
    exit 1
  fi

  log INFO "Detecting OS type from rootfs..."
  os_type=$(detect_os_type "$tmp_mount")
  log INFO "Detected OS: $os_type"

  # Create/rename user and set auth
  create_user_in_rootfs "$tmp_mount" "$NEW_USER"

  # SSH setup
  if [[ ! -d "$tmp_mount/home/$NEW_USER/.ssh" ]]; then
    mkdir -p "$tmp_mount/home/$NEW_USER/.ssh"
  fi
  chmod 700 "$tmp_mount/home/$NEW_USER/.ssh"
  chroot "$tmp_mount" chown -R "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.ssh"

  chroot "$tmp_mount" /bin/mkdir -p /etc/ssh/sshd_config.d

	# Ensure the main config includes the drop-in directory (append if missing)
	if ! grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' "$tmp_mount/etc/ssh/sshd_config" 2>/dev/null; then
		echo 'Include /etc/ssh/sshd_config.d/*.conf' >> "$tmp_mount/etc/ssh/sshd_config"
	fi

	# Write cluster override rules for SSH. Filename must sort before
	# cloud-init's own drop-in (typically 50-cloud-init.conf on Ubuntu) --
	# sshd_config's Include directive is first-match-wins (sshd_config(5)),
	# not last-wins like systemd unit drop-ins, so a higher number here would
	# lose to cloud-init's PasswordAuthentication no instead of overriding it.
	rm -f "$tmp_mount/etc/ssh/sshd_config.d/99-cluster.conf"
	cat > "$tmp_mount/etc/ssh/sshd_config.d/10-cluster.conf" <<'EOF'
# Cluster override: allow password/KbdInteractive; disable pubkey auth
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication yes
KbdInteractiveAuthentication yes
EOF
	chroot "$tmp_mount" /bin/chmod 0644 /etc/ssh/sshd_config.d/10-cluster.conf

  # Set hostname
  log INFO "Setting hostname ${HOSTNAME}"
  echo "$HOSTNAME" > "$tmp_mount/etc/hostname"
  if grep -qE '^127\.0\.1\.1' "$tmp_mount/etc/hosts"; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$HOSTNAME/g" "$tmp_mount/etc/hosts"
  else
    echo -e "127.0.1.1\t$HOSTNAME" >> "$tmp_mount/etc/hosts"
  fi

  case "$os_type" in
    ubuntu)
      # Ubuntu uses /boot/firmware
      boot_mnt="/boot/firmware";;
    raspbian|debian|unknown|*)
      # Raspberry Pi OS uses /boot/firmware
      boot_mnt="/boot/firmware";;
  esac

  log INFO "Patching /etc/fstab for ${NEW_USER}"
  if [[ $root_mode == "nvme" ]]; then
    tee "$tmp_mount/etc/fstab" > /dev/null <<EOF
PARTUUID=$boot_uuid  $boot_mnt  vfat    defaults            0       2
PARTUUID=$root_uuid  /    ext4    defaults,noatime    0       1
EOF
  else # root_mode == "nfs"
    tee "$tmp_mount/etc/fstab" > /dev/null <<EOF
proc           /proc     proc    defaults            0       0
EOF
  fi

  sync
  umount "$tmp_mount"
  rm -rf "$tmp_mount"
}

NEW_USER="node${NODE}"
HOSTNAME="raspi-node${NODE}"
NFS_PATH="${NFS_EXPORT_BASE}/rpi-node${NODE}"

log INFO "Patching "$BOOT" partition for node${NODE}, slot [$SLOT], mode ${MODE}..."
patch_bootfs "$BOOT" "$ROOT" "$MODE"

log INFO "Patching "$ROOT" partition for node${NODE}, slot [$SLOT], mode ${MODE}..."
patch_rootfs "$BOOT" "$ROOT" "$MODE"

log INFO "Done for node${NODE} (slot ${SLOT}, mode ${MODE})"
