# Proxmox homelab target

A third target alongside the Raspberry Pi and x86 ones: the Proxmox VE host and its guests, treated as one small cluster for the **basic tasks only** — SSH access (`ssh_config`) and system update/configuration (`cluster_update`). No Docker, K3s, GlusterFS or monitoring runs against it. The guests themselves (VM/LXC lifecycle, storage mounts, NFS export) are managed by the separate `homelab-orchestrator` repo.

## Nodes

`inventories/pve_linux/hosts`; `nodes=` takes the logical names in `group_vars/all/node_map.yml`.

| Node (`nodes=`) | What | Address | Connection |
|-----------------|------|---------|------------|
| `pve` | Proxmox VE host (also the control machine) | 192.168.100.200 | local, as root, no `become` (no `sudo` installed) |
| `ubuntu` | Ubuntu VM 201 (AI workloads) | 192.168.100.201 | SSH, `ubuntu` + sudo |
| `omv` | OpenMediaVault VM 203 | 192.168.100.203 | SSH, root |
| `jellyfin` | Jellyfin LXC 204 | 192.168.100.204 | SSH, root |
| `win11` | Windows 11 VM 202 | 192.168.100.202 | WinRM — listed only; not in `hostname_map`, so never targeted |

Users and addresses are the ones `homelab-orchestrator` used; confirm them before the first run.

`pve` and `omv` have `cluster_update_manage_hosts=false`: `cluster_update` then leaves their hostname and `/etc/hosts` alone (Proxmox requires the node name to resolve to its LAN address and OMV manages both itself). Every other `cluster_update` step still runs on them.

## Prerequisites

```bash
# Vault passphrase file (ansible.cfg reads it for every command) — docs/vault.md
openssl rand -base64 32 > ~/.vault_pass.txt && chmod 600 ~/.vault_pass.txt

# Password login needs sshpass on the control machine (bootstrap mode only)
apt install sshpass

# The four passwords the inventory references
ansible-vault create inventories/pve_linux/group_vars/all/vault.yml
#   vault_pve_password: ...
#   vault_ubuntu_password: ...
#   vault_omv_password: ...
#   vault_jellyfin_password: ...
```

Each guest needs `openssh-server` and password login for its user until the key is installed (the Jellyfin LXC template may not ship it: `pct exec 204 -- apt-get install -y openssh-server`).

A stock LXC template ships `PermitRootLogin without-password`, so `bootstrap` cannot log in as root with a password (`Permission denied (publickey,password)`). For such a guest, place the controller key from the PVE host with `pct push` / `pct exec` (append `~/.ssh/id_ed25519_cluster.pub` to `/root/.ssh/authorized_keys`), then run `-e ssh_mode=config -e nodes=<guest>` to write the `PermitRootLogin yes` drop-in. This was needed for `jellyfin` (CT 204).

## Playbook sequence

```bash
INV="-i inventories/pve_linux/hosts"

# 1. Key generation + install (first run needs the passwords above)
ansible-playbook $INV playbooks/ssh_config.yml -e ssh_mode=bootstrap
ansible-playbook $INV playbooks/ssh_config.yml -e ssh_mode=config

# 2. Preview, then apply, system update/configuration
ansible-playbook $INV playbooks/cluster_update.yml --check --diff
ansible-playbook $INV playbooks/cluster_update.yml -e nodes=ubuntu,jellyfin   # one or a few nodes first
ansible-playbook $INV playbooks/cluster_update.yml
```

Things to know before running for real:

- `cluster_update` ignores `-e mode=check|apply`; use Ansible's own `--check` for a dry run.
- On `pve` the update is a full `apt dist-upgrade`: it installs new Proxmox kernels and upgrades every `pve-*` package. Reboot the host afterwards (which stops every guest) — schedule it, and run `pve` on its own (`-e nodes=pve`).
- `ssh_config` writes `/etc/ssh/sshd_config.d/10-cluster.conf` on every target with `PasswordAuthentication yes`, `PubkeyAuthentication yes` and `PermitRootLogin yes` (the same policy as the other targets), so password and root login stay enabled on the Proxmox host and guests.
- `ansible_python_interpreter` is pinned to `/usr/bin/python3` in `group_vars/all/main.yml`; without it Ansible 2.19 prints an "interpreter discovery" warning for every host on every run.
- `cluster_update` sets each host's hostname to its inventory name (`ubuntu`, `jellyfin`); check the current names first if that matters.
