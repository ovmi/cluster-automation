# Architecture

## Software layers

| Layer | Role | Description |
|-------|------|-------------|
| **Provisioning** | `rpi_nvme_provision` | Creates partitions, flashes OS images, updates `cmdline.txt` and `fstab`. |
| **Network Boot** | `rpi_pxe_server` | Configures dnsmasq + TFTP + NFS exports for PXE boot of worker nodes. |
| **Access Control** | `ssh_config` | Generates SSH keys, pushes them via sshpass, populates known_hosts. |
| **System Config** | `cluster_update` | Hostname, hosts file, packages, and dist-upgrade (or a read-only update check). |
| **Networking** | `lte_gateway` | NAT, routing tables, LTE failover on node3. |
| **Storage** | `glusterfs_setup` | Creates distributed volume between node2 and node3. |
| **Container Runtime** | `docker_setup` | Installs Docker CE, adds users to group, enables service. |
| **Orchestration** | `k3s_setup` | Installs K3s control plane and joins workers. |
| **Monitoring** | `k3s_monitoring_stack` | Deploys Prometheus + Grafana via Helm — see [monitoring.md](monitoring.md). |
| **Custom Metrics** | `rpi_cpu_temp_mon_kube` / `rpi_cpu_temp_mon_bare` | Publishes CPU temperature metrics through Node Exporter (K3s DaemonSet or native systemd). |
| **Maintenance** | `cluster_power_manager` | Sequential shutdown (workers → control) or rolling reboot. |

## Inventory and variables

- `inventories/rpi_linux/hosts` — static inventory with node IPs, MACs, users, and switch ports.
- `inventories/rpi_linux/group_vars/all/main.yml` — shared variables: `nvme_map` (A/B partition layout per node), `hostname_map` (logical node IDs → hostnames), `k3s_control`/`k3s_workers`, `gluster_bricks`, `lte_bridge_node`, Helm settings.
- `inventories/rpi_linux/group_vars/all/vault.yml` — encrypted secrets. See [vault.md](vault.md).
- `inventories/rpi_linux/host_vars/` — per-host overrides.
- `inventories/x86_linux/` — second target: a four-node x86 Linux cluster (pre-provisioned VMs or containers — Proxmox LXC, KVM, cloud instances, etc.), same shape as `inventories/rpi_linux/` minus the Pi-only vars (no `nvme_map`, `tftp_server`, `nfs_server`, or `lte_bridge_node`). See [x86_linux.md](x86_linux.md).

## Playbook pattern

Most playbooks follow a two-play structure:

1. **Localhost play** — resolves the `nodes` extra-var through `common/tasks/node_check.yml`, which validates node names against `hostname_map` and sets `resolved_hosts`. Adds resolved hostnames into a dynamic group (e.g. `k3s_targets`, `nwk_group`).
2. **Cluster play** — targets the dynamic group, imports facts derived by the localhost play via `set_fact`, then applies the role.

This means `nodes=node0,node1` is a comma-separated string of *logical* node IDs (e.g. `node0`), not Ansible hostnames. The common role translates them to actual hostnames (`rpi-node0`).

Facts set on `localhost` in the first play are **not** automatically visible in the second play's task files — they're per-host in Ansible. The convention here is to re-import them explicitly in the second play's `pre_tasks` via `hostvars['localhost'].some_var`, so role task files can just reference the plain variable name without knowing about the play topology (see `playbooks/k3s_setup.yml`, `playbooks/glusterfs_setup.yml`, `playbooks/lte_gateway.yml`, `playbooks/cluster_monitoring.yml` for the pattern).

**Exception:** `playbooks/cluster_power_manager.yml` re-imports the localhost facts under a `pm_`-prefixed alias (`pm_resolved_hosts`, `pm_nodes_list`, `pm_node_host_map`) instead of the plain names, and its sub-roles (`cluster_shutdown`, `cluster_reboot`) must reference the prefixed versions, not `resolved_hosts`/`nodes_list`/`node_host_map` directly.

## common role (`roles/common/tasks/`)

Shared pre-task utilities used by most playbooks:

- `node_check.yml` — normalises `nodes` var, validates against `hostname_map`, sets `resolved_hosts` and `node_host_map`.
- `slot_check.yml` — validates NVMe A/B slot parameter.
- `bootmode_check.yml` / `ansible_check.yml` — additional precondition checks.

## NVMe A/B partition layout

`nvme_map` in `group_vars/all/main.yml` maps each node to two boot slots (A/B), each with a boot and root partition number on the single NVMe drive in node0. PXE workers boot over NFS from these partitions. Only node0 has a real NVMe drive; `roles/rpi_pxe_server` mounts each other node's slot partitions into `/srv/nfs/<hostname>` and `/srv/tftp/<hostname>` and exports them.

## Network / LTE

`lte_gateway` role targets only the `lte_bridge_host` (node3 by default). It supports two LTE modem modes (`lte_mode: ecm | qmi`) configured in `roles/lte_gateway/defaults/main.yml`. Policy-based routing (LAN priority 100, LTE priority 200) provides failover.

## Monitoring stack

See [monitoring.md](monitoring.md) for the full Prometheus/Grafana/CPU-temperature architecture.

## ansible-lint configuration

`.ansible-lint` uses `profile: production`, skips `yaml[line-length]`, enables `fqcn[canonical]` (all module calls must use fully-qualified collection names), and warns on `no-changed-when` and `jinja[spacing]`. CI runs `ansible-lint` on every push/PR via `.github/workflows/lint.yml`.

## Repository layout

```
cluster-automation/
├── playbooks/          # entry points — one per operational concern
├── roles/              # reusable task logic, one directory per role
├── inventories/         # per-target inventories (rpi_linux, x86_linux), group_vars, host_vars, vault
├── scripts/             # operational wrapper scripts (rebuild, recovery, status)
│   └── rebuild_debug/   # isolated rebuild-monitoring tooling (see scripts/rebuild_debug/rebuild_monitoring.md)
└── docs/                # this documentation
```
