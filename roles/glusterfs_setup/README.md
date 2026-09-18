# Role: glusterfs_setup

Installs, configures, and removes a GlusterFS distributed volume across designated brick nodes. The control node (node0) probes peers and creates the volume; brick nodes format and mount their local device; all targeted nodes mount the final GlusterFS volume.

## Task flow

`glusterfs_mode` must be passed explicitly; the role fails if it is `none`.

| Task file | Runs when / on | Description |
|-----------|----------------|-------------|
| `setup.yml` | `install` / all | Installs `glusterfs-server` and `glusterfs-client`, enables `glusterd` service |
| `brick_node.yml` | `install` / brick hosts only | Optionally formats `gluster_brick_device` (only if `allow_format: true`), creates brick directory |
| `control_node.yml` | `install` / control host only (`run_once`) | Probes all brick peers, creates and starts the GlusterFS volume |
| `mount_volume.yml` | `install` / all | Mounts the GlusterFS volume at `gluster_volume_mountpoint` and adds `/etc/fstab` entry |
| `remove_volume.yml` | `remove` / all | Unmounts volume, stops and deletes it on control, detaches peers, optionally purges packages and data directories |

## Key variables

| Variable | Default | Description |
|----------|---------|-------------|
| `glusterfs_mode` | `none` | Required: `install` or `remove` |
| `gluster_volume_name` | `gv0` | Name of the GlusterFS volume |
| `gluster_brick_device` | `/dev/sda` | Block device on brick nodes (USB SSD on node2/node3) |
| `gluster_brick_path` | `/mnt/glusterfs-brick` | Mount point for the raw brick on each brick node |
| `gluster_volume_mountpoint` | `/mnt/glusterfs-volume` | Where the final volume is mounted on all nodes |
| `gluster_pkg_version` | `11.1` | GlusterFS package version to install |
| `allow_format` | `false` | Set to `true` to format `gluster_brick_device` before use — destructive |
| `gluster_purge` | `false` | Set to `true` to remove packages and wipe `gluster_cleanup_paths` on removal |

## Topology

Brick nodes are defined by `gluster_bricks` in `group_vars/all/main.yml` (default: `[node3]`). The control node is `gluster_control` (default: `node0`). The playbook resolves these logical IDs to hostnames and passes `gluster_brick_hosts` and `gluster_control_host` into the role.

## Usage

```bash
# Install GlusterFS on brick and control nodes
ansible-playbook playbooks/glusterfs_setup.yml -e nodes=node0,node3 -e glusterfs_mode=install

# Remove volume and detach peers (brick nodes)
ansible-playbook playbooks/glusterfs_setup.yml -e nodes=node3 -e glusterfs_mode=remove

# Remove on control node (stops and deletes volume, uninstalls on control)
ansible-playbook playbooks/glusterfs_setup.yml -e nodes=node0 -e glusterfs_mode=remove
```
