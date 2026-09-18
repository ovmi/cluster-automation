# Role: rpi_nvme_provision

Partitions the NVMe drive on node0 and flashes OS images into the A/B slot layout used for PXE boot. Each node gets two slots (A and B), each with a boot and root partition. The partition numbering is defined by `nvme_map` in `group_vars/all/main.yml`.

## Task flow

Tasks run on node0 only (the NVMe host). Services that depend on the NVMe partitions are stopped before provisioning and restarted after.

| Task file | Description |
|-----------|-------------|
| `stop_services.yml` | Stops NFS, dnsmasq, and tftpd-hpa if `nfs_active`, `dnsmasq_active`, or `tftpd_hpa_active` are true; unmounts `/srv/tftp/*` and `/srv/nfs/rpi-*` so the partitions are free for `nvme_format.sh` to repartition |
| `nvme_format.yml` | Wipes and repartitions `nvme_device` only if `nvme_format: true` |
| `nvme_provision.yml` | Mounts each target slot's boot and root partitions and copies the OS image from `image_cache_dir`; updates `cmdline.txt` with the correct NFS root, updates `fstab` |
| `start_services.yml` | Restarts the services stopped before provisioning |

## Key variables

| Variable | Default | Description |
|----------|---------|-------------|
| `nvme_format` | `false` | Set to `true` to wipe and repartition the NVMe — destructive |
| `nvme_slot` | `a` | A/B slot to provision (`a` or `b`) |
| `image_cache_dir` | `/mnt/downloads/os_images` | Directory on node0 where OS images are pre-downloaded |
| `nfs_active` | `false` | Whether NFS is running and needs to be stopped before provisioning |
| `dnsmasq_active` | `false` | Whether dnsmasq is running |
| `tftpd_hpa_active` | `false` | Whether tftpd-hpa is running |

The per-node partition numbers come from `nvme_map` in `group_vars/all/main.yml`:

```yaml
nvme_map:
  node0: { a: { boot: 1, root: 2 }, b: { boot: 3, root: 4 } }
  node1: { a: { boot: 5, root: 6 }, b: { boot: 7, root: 8 } }
  ...
```

## Usage

```bash
# Provision slot A for node1 with NVMe format (wipes the whole drive)
ansible-playbook playbooks/rpi_nvme_provision.yml -e nodes=node1 -e slot=a -e nvme_format=true

# Re-flash slot A for node1 without re-partitioning
ansible-playbook playbooks/rpi_nvme_provision.yml -e nodes=node1 -e slot=a -e nvme_format=false
```

The `slot` parameter is validated by `common/tasks/slot_check.yml` before the role runs.
