# Role: k3s_setup

Installs or removes K3s (lightweight Kubernetes) on cluster nodes. The control node gets the K3s server; worker nodes join as agents using the token generated on the server.

## Task flow

`k3s_mode` must be passed explicitly; the role fails if it is `none`.

| Task file | Runs when / on | Description |
|-----------|----------------|-------------|
| `pre_install.yml` | `install` / all | Includes `rpi_cgroup_cmdline.yml` (aarch64 hosts only, see below); creates the `k3sadmin` user/group (`control_install.yml` needs it); installs generic apt/pip dependencies |
| `rpi_cgroup_cmdline.yml` | `install` / `ansible_architecture == 'aarch64'` only | Enables cgroups (`cgroup_memory=1 cgroup_enable=memory`) via the Pi bootloader's `cmdline.txt` — a Raspberry Pi–specific mechanism, split out from the otherwise board-agnostic `pre_install.yml`. Skipped on x86_64 hosts (incl. the x86 Linux VM/container target), where cgroups are already enabled/delegated by the host and there's no such cmdline.txt |
| _(inline in `main.yml`)_ | `install` / all whose cmdline changed | Reboots the control node and waits for it, then reboots changed worker nodes (see below) |
| `control_install.yml` | `install` / `k3s_control_node` only | Dist-upgrades (skipped on NFS-root, see below), runs the K3s install script with `--write-kubeconfig-mode 644`, waits for node to be Ready, installs `kubectl` binary, installs `kubernetes` Python client via pip |
| `workers_install.yml` | `install` / all non-control nodes | Dist-upgrades (skipped on NFS-root, see below), reads the K3s token from the control node, runs the agent install script with `K3S_URL` and `K3S_TOKEN` |
| `k3s_remove.yml` | `remove` / all | Runs `/usr/local/bin/k3s-uninstall.sh` (server) or `/usr/local/bin/k3s-agent-uninstall.sh` (agents) |

### `dist-upgrade` is skipped on NFS-root nodes

Same reasoning as `roles/cluster_update` (see that role's README): on NFS-root worker nodes, `/boot/firmware` is reached over an async NFS `crossmnt` bind-mount from node0, and a kernel/firmware package postinst writing into it during dist-upgrade has repeatedly wedged nodes off the network hard enough to need a physical PoE cycle. Both `control_install.yml` and `workers_install.yml` detect NFS-root (`findmnt -no FSTYPE /`) and skip their `upgrade: full` step there — a no-op for `control_install.yml` today since node0 is NVMe-root, kept for consistency.

### Control node reboots before workers

When `pre_install.yml`'s cgroup cmdline change applies to more than one host, `main.yml` reboots `k3s_control_node` and waits for it to come back before rebooting the changed worker nodes. Node0 hosts the PXE/NFS/TFTP server the NFS-root workers boot from; rebooting it at the same time as the workers races their netboot against node0's own service restart and can strand workers well past `reboot_timeout` even though they eventually come back (same fix as `roles/docker_setup`).

## Key variables

| Variable | Default | Description |
|----------|---------|-------------|
| `k3s_mode` | `none` | Required: `install` or `remove` |
| `k3s_control_node` | set by playbook | Ansible hostname of the control node (derived from `k3s_control` in group_vars) |
| `k3s_worker_nodes` | set by playbook | List of Ansible hostnames of worker nodes |
| `kubectl_version` | `v1.29.2` | kubectl binary version to install on the control node |
| `kubectl_arch_mapping` | `{x86_64: amd64, aarch64: arm64}` | Maps `ansible_architecture` to the kubectl release's arch naming, used to build `kubectl_url` |
| `k3s_installer_url` | `https://get.k3s.io` | K3s install script URL |

## Usage

```bash
# Install K3s on control and selected workers
ansible-playbook playbooks/k3s_setup.yml -e nodes=node0,node1,node2 -e k3s_mode=install

# Remove K3s from a worker
ansible-playbook playbooks/k3s_setup.yml -e nodes=node1 -e k3s_mode=remove
```

The `k3s_control` and `k3s_workers` variables in `group_vars/all/k3s.yml` determine which targeted node gets the server role vs the agent role — they are independent of the `nodes` parameter. `k3s_workers` must list every worker node ID (e.g. `[node1, node2, node3]`); if left empty, `workers_install.yml` has nothing to target and no agents get installed.
