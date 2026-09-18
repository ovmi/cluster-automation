#!/usr/bin/env bash
# Recovers a single cluster node by re-flashing its NVMe OS image and restoring it
# to service, without touching the other three nodes' OS images. Automates the
# "Recovery" procedure in docs/provisioning.md — see that section for the manual
# step-by-step version and the rationale behind each step.
#
# node0 (control): switches it to SD card boot, re-flashes its own NVMe slot A image,
# switches back to NVMe boot, then fully reinstalls the NFS/TFTP/dnsmasq PXE server
# stack (the fresh OS image has none of it) and force-reboots the worker nodes so
# they cleanly retry network boot against it. This takes every worker off the
# network while node0 is on SD card and again while they reboot.
#
# node1/node2/node3 (worker): removes just that node's NFS/TFTP export, power-cycles
# it (falls back to SD card once its network root is gone), re-flashes its NVMe slot
# A image, then re-mounts NFS/TFTP for ALL workers. rpi_nvme_provision's own
# stop/start-services step unmounts every worker's export while it runs (not just the
# target's) and only restores the target's TFTP mount afterward, so re-adding all
# workers here also repairs any sibling worker left unmounted by that. Finally
# switches the target back to network boot.
#
# Both paths finish with SSH key hardening + baseline update for the recovered node,
# then a cluster-wide health check.
#
# Usage: ./scripts/cluster_recover_node.sh <node0|node1|node2|node3>

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

NODE="${1:?Usage: $0 <node0|node1|node2|node3>}"

case "$NODE" in
  node0)
    phase "Switch node0 to SD card boot (frees NVMe slot A for re-flashing)"
    ansible-playbook -i "$INVENTORY" playbooks/rpi_bootmode.yml \
      -e nodes=node0 -e boot_mode=sdcard_prio -e debug=true

    phase "Re-flash node0 (NVMe slot a)"
    ansible-playbook -i "$INVENTORY" playbooks/rpi_nvme_provision.yml \
      -e nodes=node0 -e slot=a -e nvme_format=false -e debug=true

    phase "Switch node0 back to NVMe boot"
    ansible-playbook -i "$INVENTORY" playbooks/rpi_bootmode.yml \
      -e nodes=node0 -e boot_mode=nvme_prio -e debug=true

    phase "Reinstall PXE/NFS/TFTP server on node0 for all workers"
    ansible-playbook -i "$INVENTORY" playbooks/rpi_pxe_server.yml \
      -e nodes="$WORKERS" -e slot=a -e nfs_action=install -e debug=true

    phase "Reboot workers to cleanly retry network boot"
    ansible-playbook -i "$INVENTORY" playbooks/cluster_power_manager.yml \
      -e nodes="$WORKERS" -e mode=reboot
    ;;
  node1|node2|node3)
    phase "Remove NFS/TFTP export for $NODE"
    ansible-playbook -i "$INVENTORY" playbooks/rpi_pxe_server.yml \
      -e nodes="$NODE" -e slot=a -e nfs_action=remove -e debug=true

    phase "Power-cycle $NODE (falls back to SD card boot)"
    ansible-playbook -i "$INVENTORY" playbooks/netgear_gs305ep.yml \
      -e nodes="$NODE" -e poe_action=toggle

    phase "Re-flash $NODE (NVMe slot a)"
    ansible-playbook -i "$INVENTORY" playbooks/rpi_nvme_provision.yml \
      -e nodes="$NODE" -e slot=a -e nvme_format=false -e debug=true

    phase "Restore NFS/TFTP mounts for all workers"
    ansible-playbook -i "$INVENTORY" playbooks/rpi_pxe_server.yml \
      -e nodes="$WORKERS" -e slot=a -e nfs_action=add -e debug=true

    phase "Switch $NODE back to network boot"
    ansible-playbook -i "$INVENTORY" playbooks/rpi_bootmode.yml \
      -e nodes="$NODE" -e boot_mode=net_prio -e debug=true
    ;;
  *)
    echo "Unknown node: $NODE (expected node0, node1, node2, or node3)" >&2
    exit 1
    ;;
esac

phase "SSH key hardening on $NODE"
ansible-playbook -i "$INVENTORY" playbooks/ssh_config.yml \
  -e nodes="$NODE" -e ssh_mode=config

phase "System baseline for $NODE"
ansible-playbook -i "$INVENTORY" playbooks/cluster_update.yml \
  -e nodes="$NODE" -e mode=apply

phase "Cluster-wide health check"
ansible-playbook -i "$INVENTORY" playbooks/cluster_monitoring.yml \
  -e nodes="$ALL_NODES"

phase "Done. Verify with: kubectl get nodes -o wide"
