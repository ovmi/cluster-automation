#!/usr/bin/env bash
# Cleanly shuts down all cluster nodes, then cuts PoE power to their switch ports.
#
# Usage: ./scripts/cluster_shutdown.sh

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

phase "Phase 0: Shutdown all nodes"
ansible-playbook -i "$INVENTORY" playbooks/cluster_power_manager.yml \
  -e nodes="$ALL_NODES" -e mode=shutdown -e debug=true

phase "Phase 1: PoE power off all nodes"
ansible-playbook -i "$INVENTORY" playbooks/netgear_gs305ep.yml \
  -e nodes="$ALL_NODES" -e poe_action=disable -e debug=true

phase "Done."
