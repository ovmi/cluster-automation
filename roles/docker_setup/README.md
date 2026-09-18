# Role: docker_setup

Installs or removes Docker CE on cluster nodes using the official Docker apt repository. Architecture-aware via `arch_mapping` (`ansible_architecture` → Docker's `arm64`/`amd64` naming), so it works unmodified on both Raspberry Pi (aarch64) and x86_64 hosts (e.g. the x86 Linux VM/container target).

## Task flow

`docker_mode` must be passed explicitly; the role fails if it is `none`.

| Task file | Runs when | Description |
|-----------|-----------|-------------|
| `pre_install.yml` | `install` | Removes conflicting packages, adds Docker GPG key and apt repository; dist-upgrades (skipped on NFS-root, see below) |
| `docker_install.yml` | `install` | Installs `docker-ce`, `docker-ce-cli`, `containerd.io`, enables and starts the service; dist-upgrades again first (skipped on NFS-root, see below) |
| `post_install.yml` | `install` | Adds `ansible_user` to the `docker` group; reboots the control node and waits for it, then reboots the worker nodes (see below) |
| `docker_uninstall.yml` | `remove` | Removes Docker packages and purges `/var/lib/docker` |

### `dist-upgrade` is skipped on NFS-root nodes

Same reasoning as `roles/cluster_update` (see that role's README): on NFS-root worker nodes, `/boot/firmware` is reached over an async NFS `crossmnt` bind-mount from node0, and a kernel/firmware package postinst writing into it during dist-upgrade has repeatedly wedged nodes off the network hard enough to need a physical PoE cycle. Both `pre_install.yml` and `docker_install.yml` detect NFS-root (`findmnt -no FSTYPE /`) and skip their dist-upgrade step there.

### Control node reboots before workers

`post_install.yml` reboots the `control` group host (node0) and waits for it to come back before rebooting the `workers` group. Node0 hosts the PXE/NFS/TFTP server the NFS-root workers boot from; rebooting it at the same time as the workers races their netboot against node0's own service restart and can strand workers well past `reboot_timeout` even though they eventually come back (see `docs/provisioning.md`'s Phase 0/4/5 ordering for the same constraint applied elsewhere).

## Key variables

| Variable | Default | Description |
|----------|---------|-------------|
| `docker_mode` | `none` | Required: `install` or `remove` |
| `docker_user` | `{{ ansible_user }}` | User added to the docker group after install |
| `docker_gpg_key_url` | Docker CDN | Resolved from `ansible_os_family` |
| `docker_repo_url` | Docker CDN | Resolved from `ansible_os_family` |
| `arch_mapping` | `{x86_64: amd64, aarch64: arm64}` | Maps `ansible_architecture` to Docker's apt `arch=` naming, used by `docker_install.yml` |

## Usage

```bash
ansible-playbook playbooks/docker_setup.yml -e nodes=node0,node1 -e docker_mode=install
ansible-playbook playbooks/docker_setup.yml -e nodes=node1 -e docker_mode=remove
```
