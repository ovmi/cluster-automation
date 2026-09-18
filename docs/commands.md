# Command Reference

## Makefile shortcuts

```bash
make collections # install collections (below)
make lint        # lint (below), plus shellcheck on scripts/*.sh
make status      # scripts/cluster_status.sh -- read-only reachability/boot-device snapshot
make provision   # scripts/cluster_full_provision.sh -- full from-scratch provisioning
make powerup     # scripts/cluster_powerup.sh -- PoE power on all nodes
make shutdown    # scripts/cluster_shutdown.sh -- shutdown all nodes, then PoE power off
```

`powerup`/`shutdown` toggle physical PoE power and `provision` reflashes NVMe from scratch -- confirm with the user before running these (see the root `CLAUDE.md`'s "Confirm before live, hard-to-reverse actions").

## Linting

```bash
ansible-lint                          # lint entire project (uses .ansible-lint profile)
ansible-lint playbooks/<playbook>.yml # lint a single playbook
```

## Connectivity check

```bash
ansible all -i inventories/rpi_linux/hosts -m ping
```

## Install collections

```bash
ansible-galaxy collection install -r ansible/collections/requirements.yml
```

## Full cluster provisioning with reachability monitoring

`scripts/cluster_full_provision.sh` runs the from-scratch flow end-to-end with no per-phase feedback beyond ansible's own output, and is resumable: re-running it after an interruption skips every phase that already completed and picks up right after the last one, instead of restarting from Phase 0a. `scripts/rebuild_debug/cluster_rebuild_monitor.sh` wraps it with two layers of visibility: an SSH-level probe after every phase (not just a bare TCP connect -- classifies *why* a node isn't answering) and an opt-in Ansible callback plugin (`cluster_rebuild_log.py`) that logs every task's per-host result at full task granularity. It stops the run if a node doesn't come back within a grace window (nodes legitimately go dark for several minutes during boot-mode/Docker/K3s phases -- see `roles/rpi_bootmode/README.md`) instead of piling on with a confusing failure several phases later. Full details: [scripts/rebuild_debug/rebuild_monitoring.md](../scripts/rebuild_debug/rebuild_monitoring.md).

```bash
./scripts/rebuild_debug/cluster_rebuild_monitor.sh
# Tunables (seconds), all optional:
RECOVERY_TIMEOUT_SECONDS=900 ./scripts/rebuild_debug/cluster_rebuild_monitor.sh

# Interrupted? Just re-run the same command -- already-completed phases are
# skipped automatically. Force a full restart instead with:
RESUME_FROM_SCRATCH=true ./scripts/rebuild_debug/cluster_rebuild_monitor.sh
```

Logs to `scripts/rebuild_debug/logs/cluster_rebuild_monitor_<run_id>.log` (phase-level) and `scripts/rebuild_debug/logs/cluster_rebuild_tasks_<run_id>.jsonl` (task-level), and prints a final report (last successful phase, failed phase and node, responsible playbook/role, known risks, and next debugging steps) on exit either way.

## Running playbooks

All playbooks accept `-e nodes=node0,node1` to target specific nodes and `-e debug=true` for verbose output. Omitting `nodes` targets all nodes.

```bash
# NVMe provisioning (run on node0 only)
ansible-playbook playbooks/rpi_nvme_provision.yml -e nodes=node0 -e slot=a -e nvme_format=true

# PXE server setup
ansible-playbook playbooks/rpi_pxe_server.yml -e nodes=node0,node1 -e slot=a -e nfs_action=install
ansible-playbook playbooks/rpi_pxe_server.yml -e nodes=node0,node1 -e slot=a -e nfs_action=add
ansible-playbook playbooks/rpi_pxe_server.yml -e nodes=node0,node1 -e slot=a -e nfs_action=remove

# SSH key setup
ansible-playbook playbooks/ssh_config.yml -e nodes=node0,node1 -e ssh_mode=config

# Cluster update (check for available updates, or apply them)
ansible-playbook playbooks/cluster_update.yml -e nodes=node0,node1 -e mode=check
ansible-playbook playbooks/cluster_update.yml -e nodes=node0,node1 -e mode=apply

# Cluster health and performance monitoring
ansible-playbook playbooks/cluster_monitoring.yml -e nodes=node0,node1,node2,node3

# Network / LTE setup
ansible-playbook playbooks/lte_gateway.yml -e nodes=node0,node3
ansible-playbook playbooks/lte_gateway.yml -e nodes=node0,node1,node2,node3  # full cluster
# Tune failover debounce (defaults: fail_threshold=3, recover_threshold=3, route_check_interval=10)
ansible-playbook playbooks/lte_gateway.yml -e nodes=node0,node1,node2,node3 \
  -e fail_threshold=3 \
  -e recover_threshold=3 \
  -e route_check_interval=10

# Docker
ansible-playbook playbooks/docker_setup.yml -e nodes=node0,node1 -e docker_mode=install
ansible-playbook playbooks/docker_setup.yml -e nodes=node1 -e docker_mode=remove

# GlusterFS
ansible-playbook playbooks/glusterfs_setup.yml -e nodes=node2,node3 -e glusterfs_mode=install
ansible-playbook playbooks/glusterfs_setup.yml -e nodes=node2,node3 -e glusterfs_mode=remove

# K3s
ansible-playbook playbooks/k3s_setup.yml -e nodes=node0,node1 -e k3s_mode=install
ansible-playbook playbooks/k3s_setup.yml -e nodes=node1 -e k3s_mode=remove

# K3s monitoring stack (Prometheus, Grafana, Traefik)
ansible-playbook playbooks/k3s_monitoring_stack.yml

# CPU temperature monitoring
GRAFANA_SMTP_PASSWORD=xxx ansible-playbook playbooks/rpi_cpu_temp_monitor.yml -e temp_monitor_mode=kube  # or bare

# RPi boot mode
ansible-playbook playbooks/rpi_bootmode.yml -e boot_mode=nvme_prio -e nodes=node0
ansible-playbook playbooks/rpi_bootmode.yml -e boot_mode=net_prio -e nodes=node1,node2,node3
ansible-playbook playbooks/rpi_bootmode.yml -e boot_mode=sdcard_prio -e nodes=node0
ansible-playbook playbooks/rpi_bootmode.yml -e boot_mode=sdcard_prio_workers -e nodes=node1,node2,node3

# Switch control (Netgear GS305EP)
ansible-playbook playbooks/netgear_gs305ep.yml -e nodes=node1,node2 -e poe_action=enable
ansible-playbook playbooks/netgear_gs305ep.yml -e nodes=node1 -e poe_action=toggle
ansible-playbook playbooks/netgear_gs305ep.yml -e nodes=node1 -e config=true

# Cluster maintenance
ansible-playbook playbooks/cluster_power_manager.yml -e nodes=node0,node1 -e mode=reboot
ansible-playbook playbooks/cluster_power_manager.yml -e nodes=node0,node1 -e mode=shutdown
```

See [provisioning.md](provisioning.md) for the full from-scratch setup walkthrough these commands fit into, and each role's own `README.md` for the complete variable reference.
