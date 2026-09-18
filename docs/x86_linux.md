# x86 Linux Target

A second cluster target alongside the Raspberry Pi bare-metal one described in [provisioning.md](provisioning.md): four x86_64 Linux hosts running the same K3s + GlusterFS + Prometheus/Grafana stack. "Host" here is deliberately generic — a Proxmox LXC container, a KVM/QEMU VM, a cloud instance, or any other x86_64 Linux machine all work the same way, as long as it's reachable over SSH. The hosts are **pre-provisioned** outside this repo — this repo only configures software on top, the same way it does for the Pi nodes once they're up.

## What's excluded, and why

Everything below is Raspberry Pi/physical-hardware-only and never runs against this target — there's no equivalent concept on a generic x86 host:

| Role/playbook | Why it doesn't apply |
|----------------|-----------------------|
| `rpi_nvme_provision` | No NVMe device to partition; the host's storage is owned by whatever provisioned it |
| `rpi_pxe_server` | These hosts don't PXE boot |
| `rpi_bootmode` | No EEPROM/`BOOT_ORDER` — that's Raspberry Pi bootloader firmware |
| `netgear_gs305ep` | No PoE switch port to control |
| `lte_gateway` | No LTE modem attached |
| `rpi_cpu_temp_mon_bare` / `rpi_cpu_temp_mon_kube` | Reads the Pi's own thermal zone; not meaningful on a VM/container |

Everything else (`ssh_config`, `cluster_update`, `docker_setup`, `k3s_setup`, `glusterfs_setup`/`k3s_glusterfs`, `k3s_monitoring_stack`, `cluster_monitoring`, `cluster_power_manager`) is hardware-agnostic and runs unmodified against `inventories/x86_linux`. `docker_setup` and `k3s_setup` are architecture-aware (`ansible_architecture` → `amd64`/`arm64`), so the same roles serve both targets without a fork.

`cluster_power_manager`'s `shutdown` mode stops/shuts down the host rather than powering off real hardware — that's expected, not a bug.

## Prerequisite: container features (LXC hosts only)

Skip this section if your hosts are full VMs (KVM, cloud instances, etc.) — it only applies to **unprivileged LXC containers**, which don't get the cgroup/overlay/FUSE features Docker and K3s need by default. If you're running Proxmox LXC specifically, set these on the Proxmox host before running any playbook here (outside this repo's automation — Ansible only has SSH access *inside* the container, not to the Proxmox host):

- `features: nesting=1` — required for Docker/containerd to manage its own cgroups and mounts inside the container.
- `features: keyctl=1` — required by some container-runtime keyring operations.
- `features: fuse=1` — required for the GlusterFS FUSE client (`glusterfs_setup`/`k3s_glusterfs` mount volumes via FUSE).

Set via `pct set <vmid> -features nesting=1,keyctl=1,fuse=1` or the container's **Options → Features** panel in the Proxmox UI, then restart the container. Other LXC hosting (e.g. plain `lxc`/`incus`) needs the equivalent unprivileged-container features enabled through whatever tool manages it.

## Inventory

`inventories/x86_linux/` mirrors `inventories/rpi_linux/`'s structure (see [architecture.md](architecture.md#inventory-and-variables)) minus the Pi-only vars. It ships with placeholder `CHANGE_ME` hostnames/IPs/credentials in `hosts` and placeholder vault values in `group_vars/all/vault.yml` — fill in the real host details before running anything:

```bash
# Edit hosts: real ansible_host/ansible_user per node (or switch to SSH-key auth
# and drop ansible_password/ansible_become_password entirely)
vim inventories/x86_linux/hosts

# Edit the real per-node passwords (see docs/vault.md for the vault pattern)
ansible-vault edit inventories/x86_linux/group_vars/all/vault.yml

# Confirm connectivity
ansible all -i inventories/x86_linux/hosts -m ping
```

## Playbook sequence

Same playbooks as the Pi target, pointed at the new inventory with `-i`. No `rpi_nvme_provision`/`rpi_pxe_server`/`rpi_bootmode` phase first — the hosts already exist and are reachable.

```bash
ansible-playbook -i inventories/x86_linux/hosts playbooks/ssh_config.yml -e ssh_mode=config
ansible-playbook -i inventories/x86_linux/hosts playbooks/cluster_update.yml -e mode=apply
ansible-playbook -i inventories/x86_linux/hosts playbooks/docker_setup.yml -e docker_mode=install
ansible-playbook -i inventories/x86_linux/hosts playbooks/k3s_setup.yml -e k3s_mode=install
ansible-playbook -i inventories/x86_linux/hosts playbooks/glusterfs_setup.yml -e nodes=node2,node3 -e glusterfs_mode=install
ansible-playbook -i inventories/x86_linux/hosts playbooks/k3s_monitoring_stack.yml
ansible-playbook -i inventories/x86_linux/hosts playbooks/cluster_monitoring.yml
```

See [commands.md](commands.md) for the full flag reference each of these playbooks accepts (`nodes`, `debug`, per-role mode flags) — it applies identically here, just with `-i inventories/x86_linux/hosts` in front.
