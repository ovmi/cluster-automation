#!/usr/bin/env bash
# Read-only snapshot of current cluster state: SSH reachability for each node,
# then each reachable node's active boot device (nvme, nfs, or sdcard), read
# live from its mounted root filesystem via ad-hoc `ansible` commands.
#
# This is independent of the EEPROM BOOT_ORDER preference set by rpi_bootmode
# (see roles/rpi_bootmode/README.md) — BOOT_ORDER says what should happen on
# the *next* boot, not what a node is actually running on right now.
#
# Usage: ./scripts/cluster_status.sh

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Classifies a "findmnt -no SOURCE,FSTYPE /" result, e.g. "/dev/nvme0n1p2 ext4"
# or "192.168.100.10:/srv/nfs/rpi-node1 nfs4".
classify_boot() {
  local src="${1%% *}" fstype="${1##* }"
  case "$src" in
    /dev/nvme*) echo "nvme" ;;
    /dev/mmcblk*) echo "sdcard" ;;
    *) [[ "$fstype" == nfs* ]] && echo "nfs" || echo "unknown ($1)" ;;
  esac
}

phase "SSH connectivity"
reachable=()
unreachable=()
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  host="$(cut -d'|' -f1 <<<"$line" | xargs)"
  if [[ "$line" == *"SUCCESS"* ]]; then
    reachable+=("$host")
    printf '  %-14s reachable\n' "$host"
  else
    unreachable+=("$host")
    printf '  %-14s UNREACHABLE\n' "$host"
  fi
done < <(ansible cluster -i "$INVENTORY" -m ansible.builtin.ping -o 2>&1 || true)

phase "Active boot device"
if [ ${#reachable[@]} -eq 0 ]; then
  echo "  no reachable nodes"
else
  targets="$(IFS=,; echo "${reachable[*]}")"
  printf '  %-14s %s\n' "HOST" "BOOT"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    host="$(cut -d'|' -f1 <<<"$line" | xargs)"
    stdout_content="$(grep -oP '(?<=\(stdout\) ).*' <<<"$line" || true)"
    if [[ -z "$stdout_content" ]]; then
      printf '  %-14s error: %s\n' "$host" "$line"
      continue
    fi
    printf '  %-14s %s\n' "$host" "$(classify_boot "$stdout_content")"
  done < <(ansible "$targets" -i "$INVENTORY" -m ansible.builtin.command -a "findmnt -no SOURCE,FSTYPE /" -o 2>&1 || true)
fi

if [ ${#unreachable[@]} -gt 0 ]; then
  phase "Done. ${#unreachable[@]} node(s) unreachable: ${unreachable[*]}"
else
  phase "Done. All nodes reachable."
fi
