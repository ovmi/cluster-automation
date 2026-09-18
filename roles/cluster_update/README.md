# Role: cluster_update

Applies a baseline system configuration to cluster nodes: removes unwanted packages, installs essential tools, and deploys user dotfiles. The playbook runs with `serial: 1` so nodes are updated one at a time.

## Task flow

| Task file | Description |
|-----------|-------------|
| `purge_packages.yml` | Removes packages that are not needed on a headless cluster node (e.g. GUI tools, `snapd`) |
| `install_packages.yml` | Runs `apt dist-upgrade` (skipped on NFS-root nodes, see below), installs `required_packages`, deploys `.vimrc` from `files/vimrc` to each node user's home directory |

### `dist-upgrade` is skipped on NFS-root nodes

On worker nodes, `/boot/firmware` isn't local storage — it's the vfat boot partition reached over the `crossmnt` NFS bind-mount from node0 (see `roles/rpi_pxe_server` and `roles/rpi_bootmode/README.md`'s "EEPROM updates on NFS-root worker nodes" section for the same path misbehaving with EEPROM writes). A kernel/firmware package's postinst copying files into `/boot/firmware` over that path has twice wedged a node hard enough to drop off the network entirely mid `dist-upgrade`, needing a physical PoE cycle to recover.

Until the underlying NFS write path is made safe, `install_packages.yml` detects NFS-root (`findmnt -no FSTYPE /`, registered in `purge_packages.yml`) and skips `dist-upgrade` there entirely — `required_packages` still get installed via a plain `apt install`, which doesn't touch the kernel. **Kernel/firmware and other package updates for NFS-root workers currently only happen via `rpi_nvme_provision` re-imaging.**

### Persistent DNS for NetworkManager-managed netboot workers

Raspberry Pi OS netboot workers (node2/node3) get their IP from the kernel's early `ip=dhcp` netboot autoconfig before NetworkManager starts, so NM adopts the already-up `eth0` as an "externally" configured device instead of running its own DHCP client — it never learns a DNS server and writes an empty `/etc/resolv.conf` on every boot. The plain fallback-nameserver task above only patches that file until the next reboot wipes it again.

`install_packages.yml` writes a persistent NetworkManager keyfile (`/etc/NetworkManager/system-connections/eth0.nmconnection`) with a static `dns=` entry when `NetworkManager.service` is active **and** the node's root is NFS (`root_fstype.stdout == "nfs"`, the same fact `purge_packages.yml` registers for the dist-upgrade guard). This is a plain file write, not a live `nmcli connection modify` — applying that against the live "externally" connection on node3 once made NetworkManager reapply it immediately with an incomplete runtime config and dropped the interface entirely, needing a PoE cycle to recover. The task does **not** trigger a reboot; a handler just notes that one is needed for the new profile to take effect.

**Both guards are required, not just `NetworkManager.service` running.** The profile sets `autoconnect=false` — safe on node2/node3 only because their `eth0` is already brought up by the kernel's own `ip=dhcp` netboot autoconfig before NetworkManager ever looks at it, so NM just adopts the already-live interface. node0 (and any node not currently NFS-root) has no such kernel-level autoconfig — if this profile is written there, `autoconnect=false` means NetworkManager never brings `eth0` up on its own, and the node goes fully unreachable on its next reboot with no automatic recovery. This happened for real: the `when` originally checked only `NetworkManager.service` running, and node0 picked up the profile during a routine `cluster_update` pass, going dark on its next reboot. Recovery required pulling node0's SD card, mounting it on another machine, and deleting the bad `eth0.nmconnection` file by hand before the node would come back up with networking at all.

## Key variables

| Variable | Default | Description |
|----------|---------|-------------|
| `required_packages` | `[vim, net-tools, python3, python3-pip]` | Packages installed on every node |
| `vimrc_src` | `vimrc` | Source file name under `roles/cluster_update/files/` |
| `vimrc_path` | `/home/{{ ansible_user }}/.vimrc` | Destination path on the node |
| `fallback_nameserver` | `8.8.8.8` | Nameserver used both as the plain `/etc/resolv.conf` fallback line and as the secondary DNS in the NetworkManager keyfile above |

## Usage

```bash
ansible-playbook playbooks/cluster_update.yml -e nodes=node0,node1 [-e debug=true]
```

Omit `-e nodes` to update all cluster nodes sequentially.
