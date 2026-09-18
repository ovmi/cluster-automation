# Role: rpi_pxe_server

Configures node0 as a PXE/NFS boot server for the worker nodes. Worker nodes have no local storage; they boot their root filesystem over NFS from the partitions prepared by `rpi_nvme_provision`. The role installs and configures NFS, dnsmasq (as TFTP server), and sets up the per-node TFTP and NFS mount points.

## Task flow

Controlled by `nfs_action`:

| `nfs_action` | Task files executed | Description |
|--------------|--------------------|-|
| `install` | `nfs_install.yml` → `pxe_node_install.yml` → `nfs_post_install.yml` → `dnsmasq_install.yml` → `tftp_config.yml` | Full server setup: install NFS/dnsmasq, mount partitions, export NFS, configure TFTP |
| `add` | `pxe_node_install.yml` | Mount NFS partition directories for additional nodes without reinstalling server software |
| `remove` | `pxe_node_remove.yml` | Unmount and remove NFS entries for specified nodes |

Per-node lines in `/etc/exports.d/cluster.exports` are managed additively (`lineinfile`, one line per node) by `pxe_node_install.yml`, so running `install` or `add` scoped to a subset of nodes never removes export entries for nodes left out of `-e nodes=`. Only `remove` deletes a node's export line, and only for the nodes passed to it.

Each per-node export carries `crossmnt`. `{{ nfs_root_dir }}/<host>/boot/firmware` is a separate vfat filesystem bind-mounted *inside* the exported `{{ nfs_root_dir }}/<host>` tree (the same partition also mounted at `{{ tftp_dir }}/<host>` for TFTP) — without `crossmnt`, NFS doesn't let a client traverse into a different filesystem nested inside an export, so from the worker's own point of view `/boot/firmware` was just an empty directory on its ext4 NFS root, not the real boot partition. That silently broke `rpi_bootmode`'s EEPROM updates on worker nodes: `rpi-eeprom-config` couldn't find a real vfat boot filesystem to write the pending update to, so it fell back to writing `pieeprom.upd`/`recovery.bin` into the worker's plain `/boot` — a location the SPI bootloader (which fetches its boot files via TFTP directly from `{{ tftp_dir }}/<host>`) never reads. The update file existed, "reboot to apply" printed, but nothing was ever actually staged where the hardware could see it, so `BOOT_ORDER` silently stayed unchanged after the reboot.

## Internal data structure

The role builds a `pxe_nodes` list at runtime by combining `nodes_list`, `nvme_map`, `hostname_map`, and `slot_param`. Each entry contains the node name, its Ansible hostname, partition device paths, and mount point paths. This structure is used by all subsequent task files.

## Key variables

| Variable | Default | Description |
|----------|---------|-------------|
| `nfs_action` | `install` | Workflow selector: `install`, `add`, or `remove` |
| `tftp_dir` | `/srv/tftp` | TFTP root; per-node subdirectories hold the boot filesystem |
| `nfs_root_dir` | `/srv/nfs` | NFS root; per-node subdirectories hold the root filesystem |
| `pxe_interface` | `eth0` | Interface dnsmasq listens on for DHCP/TFTP |
| `bootfs_fstype` | `vfat` | Filesystem type for boot partition |
| `rootfs_fstype` | `ext4` | Filesystem type for root partition |
| `pxe_control_node` | `node0` | Logical node ID of the PXE server |
| `debug` | `false` | Print the `pxe_nodes` map and intermediate values |

## Usage

```bash
# Full install: set up PXE server and mount slot-A partitions for node1
ansible-playbook playbooks/rpi_pxe_server.yml -e nodes=node1 -e slot=a -e nfs_action=install

# Add NFS mounts for an additional node after server is already installed
ansible-playbook playbooks/rpi_pxe_server.yml -e nodes=node2 -e slot=a -e nfs_action=add

# Remove NFS mounts for a node
ansible-playbook playbooks/rpi_pxe_server.yml -e nodes=node2 -e slot=a -e nfs_action=remove
```

Both `nodes` and `slot` are validated by `common` pre-tasks before the role runs.
