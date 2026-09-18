#!/usr/bin/env bash
# Powers PoE back on for all cluster switch ports (counterpart to cluster_shutdown.sh).
# Nodes boot on their own once power is restored; this script does not wait for or
# verify SSH availability.
#
# Usage: ./scripts/cluster_powerup.sh

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

phase "Phase 1: PoE power on all nodes"
ansible-playbook -i "$INVENTORY" playbooks/netgear_gs305ep.yml \
  -e nodes="$ALL_NODES" -e poe_action=enable -e debug=yes

phase "Done."
