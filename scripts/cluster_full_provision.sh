#!/usr/bin/env bash
# Full cluster provisioning: resets all 4 nodes to SD card, reflashes NVMe
# from the existing slot-A image, reconfigures PXE/NFS boot, and installs
# Docker, K3s, the monitoring stack, and CPU temperature monitoring. See
# docs/provisioning.md for the full narrative and rationale behind each
# phase, and the "Recovery" section for troubleshooting.
#
# Scope: matches the from-scratch flow in docs/provisioning.md EXCEPT GlusterFS
# (Phase 9) is intentionally omitted. SMTP/email alerting for Grafana is left
# disabled — export GRAFANA_SMTP_PASSWORD before running and re-run
# `ansible-playbook playbooks/rpi_cpu_temp_monitor.yml -e temp_monitor_mode=kube`
# afterward to enable it.
#
# Resumable: if a prior run was interrupted by an error, re-running this
# script skips straight past every phase that already completed and picks
# up right after the last one, instead of starting over from Phase 0a --
# see common.sh's resume-support block for how, and RESUME_FROM_SCRATCH=true
# to force a full restart anyway.
#
# Usage: ./scripts/cluster_full_provision.sh

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Workers move to SD card (and reboot off the NFS dependency) first, while
# node0 is still serving PXE/NFS/TFTP off its NVMe OS instance for them to
# fall back from cleanly.
run_phase "Phase 0a: change worker nodes to SD card boot" \
  ansible-playbook -i "$INVENTORY" playbooks/rpi_bootmode.yml \
  -e nodes="$WORKERS" -e boot_mode=sdcard_prio_workers

# Control node moves last, only after the workers are safely off NFS-root:
# node0 serving PXE/NFS/TFTP only exists on its NVMe OS instance, so if it
# switches to SD card while workers are still running NFS-root off that
# instance, their root filesystem's server vanishes out from under them
# mid-session — they don't gracefully fall back (that only happens at their
# own next boot), they just hang unreachable.
run_phase "Phase 0b: change control node to SD card boot" \
  ansible-playbook -i "$INVENTORY" playbooks/rpi_bootmode.yml \
  -e nodes="$CONTROL" -e boot_mode=sdcard_prio

# First-time password-based key deployment: generates an ed25519 key pair if
# absent and pushes it to every node via sshpass, so later phases can use key
# auth instead of the inventory passwords.
run_phase "Phase 1: SSH bootstrap" \
  ansible-playbook -i "$INVENTORY" playbooks/ssh_config.yml \
  -e nodes="$ALL_NODES" -e ssh_mode=bootstrap

# Baseline packages and dist-upgrade on the SD-card OS, before it gets
# replaced by the NVMe/NFS images in the phases below.
run_phase "Phase 2: system update over all nodes" \
  ansible-playbook -i "$INVENTORY" playbooks/cluster_update.yml \
  -e nodes="$ALL_NODES" -e mode=apply

# Partitions and formats node0's NVMe drive, then flashes the slot-A OS image
# for all 4 nodes onto it (node0's own root plus the three workers' future
# NFS-root images).
run_phase "Phase 3: NVMe provisioning" \
  ansible-playbook -i "$INVENTORY" playbooks/rpi_nvme_provision.yml \
  -e nodes="$ALL_NODES" -e slot=a -e nvme_format=false

# Switches node0's EEPROM boot order to prioritize NVMe and reboots it into
# the permanent OS image flashed in Phase 3.
run_phase "Phase 4: control node boot mode (NVMe)" \
  ansible-playbook -i "$INVENTORY" playbooks/rpi_bootmode.yml \
  -e nodes="$CONTROL" -e boot_mode=nvme_prio

# Installs NFS/dnsmasq/TFTP on node0 (now running its permanent OS) and
# mounts each worker's slot-A NVMe partitions into the NFS/TFTP export
# directories so they have something to boot from.
run_phase "Phase 5a: PXE/NFS/TFTP server install for workers" \
  ansible-playbook -i "$INVENTORY" playbooks/rpi_pxe_server.yml \
  -e nodes="$WORKERS" -e slot=a -e nfs_action=install

# Switches each worker's EEPROM boot order to prioritize network boot and
# reboots them to PXE-boot their NFS-root image off node0.
run_phase "Phase 5b: worker boot mode (network)" \
  ansible-playbook -i "$INVENTORY" playbooks/rpi_bootmode.yml \
  -e nodes="$WORKERS" -e boot_mode=net_prio

# Re-runs ssh_config in steady-state mode on the freshly booted OS images,
# verifying key auth and refreshing known_hosts.
run_phase "Phase 6a: SSH hardening on new OS" \
  ansible-playbook -i "$INVENTORY" playbooks/ssh_config.yml \
  -e nodes="$ALL_NODES" -e ssh_mode=config

# Re-applies the cluster_update baseline (packages, hostname, fallback DNS)
# to the new OS images, since Phase 2's baseline only touched the old SD card.
run_phase "Phase 6b: system baseline on new OS" \
  ansible-playbook -i "$INVENTORY" playbooks/cluster_update.yml \
  -e nodes="$ALL_NODES" -e mode=apply

# Configures LTE modem connectivity on node3 (ECM or QMI mode, see lte_mode)
# and cluster-wide LAN/LTE failover routing + monitoring on node0/1/2, so the
# cluster keeps a route out even if the LAN gateway drops.
run_phase "Phase 6c: LTE gateway setup" \
  ansible-playbook -i "$INVENTORY" playbooks/lte_gateway.yml \
  -e nodes="$ALL_NODES"

# Verifies all 4 nodes are reachable and healthy before layering Docker/K3s
# on top -- a good checkpoint to stop at if something upstream is still broken.
run_phase "Phase 7: cluster health sanity check" \
  ansible-playbook -i "$INVENTORY" playbooks/cluster_monitoring.yml \
  -e nodes="$ALL_NODES"

# Installs Docker CE on all 4 nodes and reboots them (control node first,
# then workers, to avoid racing their netboot against node0's own restart).
run_phase "Phase 8: Docker" \
  ansible-playbook -i "$INVENTORY" playbooks/docker_setup.yml \
  -e nodes="$ALL_NODES" -e docker_mode=install

# Installs the K3s server on node0 and joins the workers as agents, enabling
# the memory cgroup and rebooting (control first) where the cmdline changed.
run_phase "Phase 9: K3s" \
  ansible-playbook -i "$INVENTORY" playbooks/k3s_setup.yml \
  -e nodes="$ALL_NODES" -e k3s_mode=install

# Deploys kube-prometheus-stack (Prometheus, Alertmanager, Grafana) via Helm
# and configures Traefik ingress for the Grafana/Prometheus dashboards.
run_phase "Phase 10: monitoring stack (Prometheus, Grafana, Traefik)" \
  ansible-playbook -i "$INVENTORY" playbooks/k3s_monitoring_stack.yml

# Adds a CPU-temperature textfile exporter on every node and upgrades the
# monitoring Helm release to scrape it. SMTP alerting stays disabled here --
# see the header comment above for how to enable it afterward.
run_phase "Phase 11: CPU temperature monitoring (SMTP disabled)" \
  ansible-playbook -i "$INVENTORY" playbooks/rpi_cpu_temp_monitor.yml \
  -e temp_monitor_mode=kube

print_time_table

# Every phase above ran (for real or as a resumed skip), so clear the
# resume marker -- the next invocation of this script is a normal
# from-scratch run again, not a permanent "always resume" mode.
finish_resume_state

phase "Done. Verify with: kubectl get nodes -o wide"
