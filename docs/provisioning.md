# From-Scratch Provisioning Sequence

This is the Raspberry Pi bare-metal target (NVMe/PXE/EEPROM). For the x86 Linux (VM/container) target, see [x86_linux.md](x86_linux.md) instead — its hosts are pre-provisioned, so none of the phases below apply.

All nodes must be reachable over SSH with password authentication (booted from SD card) before starting. Install required Ansible collections once on the control machine:

```bash
ansible-galaxy collection install -r ansible/collections/requirements.yml
```

Set up [vault.md](vault.md) before running anything that touches encrypted vars.

---

### Resetting an already-provisioned cluster

If nodes are already running from NVMe/network boot (not fresh SD cards), reset them to SD card first so the phases below have a known starting point. **Reset the workers before node0, not all at once**: node0's PXE/NFS/TFTP stack only exists on its NVMe OS instance. If node0 switches to SD card while workers are still running NFS-root off that instance, their root filesystem's server vanishes mid-session — a running node doesn't gracefully fall back to SD card (that only happens at its own next boot attempt), it just hangs unreachable.

```bash
ansible-playbook playbooks/rpi_bootmode.yml \
  -e nodes=node1,node2,node3 -e boot_mode=sdcard_prio_workers

ansible-playbook playbooks/rpi_bootmode.yml \
  -e nodes=node0 -e boot_mode=sdcard_prio
```

Workers use `sdcard_prio_workers` (falls back to network/PXE, since they have no NVMe); node0 uses `sdcard_prio` (falls back to NVMe).

Then continue from Phase 1.

---

### Phase 1 — Bootstrap SSH access

Generate the cluster SSH key pair and distribute it to all nodes using inventory passwords. Requires `sshpass` on the control machine.

```bash
ansible-playbook playbooks/ssh_config.yml \
  -e nodes=node0,node1,node2,node3 \
  -e ssh_mode=bootstrap
```

---

### Phase 2 — System baseline

Run `apt dist-upgrade`, install essential packages. Nodes are updated one at a time (`serial: 1`). If the upgrade touched the kernel or firmware (`/var/run/reboot-required` present — common here, since `dist-upgrade` regularly pulls in a new `linux-image-raspi` alongside `rpi-eeprom`/`flash-kernel`), the node is rebooted and reconnected before moving to the next one.

```bash
ansible-playbook playbooks/cluster_update.yml \
  -e nodes=node0,node1,node2,node3 \
  -e mode=apply
```

---

### Phase 3 — NVMe provisioning

Flash OS images into slot-A partitions on node0's NVMe drive for all nodes. This runs entirely on node0 (the NVMe host). Enable `nvme_format=true` on first run to partition the drive.

```bash
ansible-playbook playbooks/rpi_nvme_provision.yml \
  -e nodes=node0,node1,node2,node3 \
  -e slot=a \
  -e nvme_format=true
```

> Image URLs per node are defined in the `images` var block inside `playbooks/rpi_nvme_provision.yml`. Edit them before running.

---

### Phase 4 — Control node boot mode

Switch node0 to NVMe priority and reboot it into the OS image flashed in Phase 3. The playbook automatically re-runs SSH key bootstrap and verifies the EEPROM after reboot.

```bash
ansible-playbook playbooks/rpi_bootmode.yml \
  -e nodes=node0 \
  -e boot_mode=nvme_prio
```

> `rpi_pxe_server` installs NFS, dnsmasq, and TFTP on whatever operating system node0 is currently running. If you execute it while node0 is still booted from the SD card, and then later switch node0 to the NVMe drive (which contains a completely different OS image created in Phase 3), all of that PXE configuration disappears. As a result, the worker nodes won’t be able to locate their NFS root in the next phase — leading to the fallback‑to‑SD‑card behavior described in the Recovery section.

---

### Phase 5 — PXE boot server and worker boot mode

Install NFS and dnsmasq/TFTP on node0 (now running its permanent OS), mount the slot-A NVMe partitions into the NFS and TFTP export directories, configure exports for all worker nodes, then switch workers to network boot.

```bash
ansible-playbook playbooks/rpi_pxe_server.yml \
  -e nodes=node1,node2,node3 \
  -e slot=a \
  -e nfs_action=install

ansible-playbook playbooks/rpi_bootmode.yml \
  -e nodes=node1,node2,node3 \
  -e boot_mode=net_prio
```

> `rpi_bootmode` only reboots a node when its EEPROM `BOOT_ORDER` actually changes. If a prior attempt already left `BOOT_ORDER` at `net_prio` (e.g. you're retrying after fixing something in Phase 5's first half), that task is a no-op and a worker sitting on its SD-card fallback never retries network boot. Force it with a PoE power cycle:
>
> ```bash
> ansible-playbook playbooks/netgear_gs305ep.yml -e nodes=node1,node2,node3 -e poe_action=toggle
> ```
>
> Prefer this over `ansible-playbook playbooks/cluster_power_manager.yml -e mode=reboot` here — that command reboots over SSH, which does nothing for a worker that's already unreachable (which is exactly the state this note is about). `scripts/cluster_full_provision.sh` runs this unconditionally as Phase 5c/5d so a full provisioning run never depends on the no-op case not happening.

---

### Phase 6 — System baseline on new OS

Re-run the system update on the freshly booted OS images.

```bash
ansible-playbook playbooks/cluster_update.yml \
  -e nodes=node0,node1,node2,node3 \
  -e mode=apply
```

---

### Phase 7 — Network setup (LTE)

Configure LTE modem connectivity on node3. Set `lte_mode` to `ecm` (default) or `qmi` depending on the modem operating mode.

```bash
ansible-playbook playbooks/lte_gateway.yml \
  -e nodes=node0,node3
```

---

### Phase 8 — Docker

Install Docker CE on all nodes using the official Docker apt repository.

```bash
ansible-playbook playbooks/docker_setup.yml \
  -e nodes=node0,node1,node2,node3 \
  -e docker_mode=install
```

---

### Phase 9 — GlusterFS

Before running, update `gluster_bricks` in `inventories/rpi_linux/group_vars/all/main.yml` to list the intended brick nodes (e.g. `[node2, node3]`). Set `allow_format: true` if the brick devices need to be formatted.

```bash
ansible-playbook playbooks/glusterfs_setup.yml \
  -e nodes=node0,node2,node3 \
  -e glusterfs_mode=install
```

This also applies the `k3s_glusterfs` role, which creates the StorageClass, PersistentVolume, and PersistentVolumeClaim in K3s — run it after Phase 10 if K3s is not yet installed.

---

### Phase 10 — K3s

Before running, set `k3s_workers` in `inventories/rpi_linux/group_vars/all/main.yml` to the list of worker node IDs:

```yaml
k3s_workers: [node1, node2, node3]
```

Then install the cluster:

```bash
ansible-playbook playbooks/k3s_setup.yml \
  -e nodes=node0,node1,node2,node3 \
  -e k3s_mode=install
```

The `k3s_control` variable (default `node0`) determines which targeted node becomes the K3s server; all others become agents.

> **Note:** worker nodes boot with an NFS-mounted root filesystem, which the `overlayfs` containerd snapshotter cannot mount on. `k3s_setup`'s worker install already configures `/etc/rancher/k3s/config.yaml` with `snapshotter: native` to work around this — see `roles/k3s_setup/tasks/workers_install.yml`.

---

### Phase 11 — Monitoring

Deploy Prometheus, Grafana, and Traefik via Helm:

```bash
ansible-playbook playbooks/k3s_monitoring_stack.yml
```

See [monitoring.md](monitoring.md) for the full architecture.

---

### Phase 12 — CPU temperature monitoring

Add Node Exporter textfile collector integration and temperature dashboards to the existing monitoring stack:

```bash
GRAFANA_SMTP_PASSWORD=xxx \
  ansible-playbook playbooks/rpi_cpu_temp_monitor.yml \
  -e temp_monitor_mode=kube
```

---

## Maintenance commands

```bash
# Graceful shutdown — run workers first, then control
ansible-playbook playbooks/cluster_power_manager.yml -e nodes=node1,node2,node3 -e mode=shutdown
ansible-playbook playbooks/cluster_power_manager.yml -e nodes=node0 -e mode=shutdown

# Reboot specific nodes
ansible-playbook playbooks/cluster_power_manager.yml -e nodes=node1 -e mode=reboot

# PoE power cycle a node via the switch
ansible-playbook playbooks/netgear_gs305ep.yml -e nodes=node1 -e poe_action=toggle

# Check for available package updates (read-only) or apply them
ansible-playbook playbooks/cluster_update.yml -e nodes=node0,node1,node2,node3 -e mode=check
ansible-playbook playbooks/cluster_update.yml -e nodes=node0,node1,node2,node3 -e mode=apply

# Cluster health check, or performance/bandwidth check between nodes
ansible-playbook playbooks/cluster_monitoring.yml -e nodes=node0,node1,node2,node3
```

---

## Recovery — NFS worker node re-provisioning

Use this procedure when a worker node fails to boot over NFS (corrupted partition, bad image flash, stale NFS export). The steps unmount the existing NFS export, power-cycle the node, re-flash the slot partition, re-mount the export, and re-apply the boot mode.

> `scripts/cluster_recover_node.sh <node0|node1|node2|node3>` automates this end-to-end for a single node — the worker path below plus SSH hardening, baseline update, and a cluster-wide health check, and it also re-mounts every worker's NFS/TFTP export afterward (not just the target's), since `rpi_nvme_provision`'s own service stop/start unmounts all of them while it runs. For node0 it re-images the control node itself instead (SD card fallback, re-flash, back to NVMe, full PXE/NFS/TFTP server reinstall, worker reboot).

**Step 1 — Remove the stale NFS export for the node**

Unmounts the slot-A NFS and TFTP bind-mounts on node0 and removes the `/etc/exports` entry for node3.

```bash
ansible-playbook playbooks/rpi_pxe_server.yml \
  -e nodes=node3 -e slot=a -e nfs_action=remove -e debug=true
```

> `install`/`add`/`remove` all manage per-node export lines additively (see `roles/rpi_pxe_server/README.md`) — running `install`/`add` scoped to a subset of nodes does **not** drop other nodes' exports; only `remove` deletes entries, and only for the node(s) passed to it. All three still stop and restart the NFS/dnsmasq services unconditionally, though, so any run briefly interrupts every *currently mounted* worker, not just the one(s) targeted by `-e nodes=`.

**Step 2 — Boot node into SD card fallback**

With the NFS export removed, toggling PoE forces node3 to reboot. Because `net_prio` boot order falls back to SD card when the NFS root is unreachable, the node comes up on the SD card image — giving a live SSH target for the re-provisioning steps that follow.

```bash
ansible-playbook playbooks/netgear_gs305ep.yml \
  -e nodes=node3 -e poe_action=toggle
```

**Step 3 — Re-flash the NVMe partition**

Re-writes the slot-A root and boot partitions for node3 on node0's NVMe drive. `nvme_format=false` skips re-partitioning — only the image is re-flashed.

```bash
ansible-playbook playbooks/rpi_nvme_provision.yml \
  -e nodes=node3 -e slot=a -e nvme_format=false -e debug=true
```

**Step 4 — Re-mount the NFS export**

Bind-mounts the freshly written slot-A partitions back into the NFS/TFTP directories and re-exports them.

```bash
ansible-playbook playbooks/rpi_pxe_server.yml \
  -e nodes=node3 -e slot=a -e nfs_action=add -e debug=true
```

**Step 5 — Re-apply boot mode and verify EEPROM**

Sets `net_prio` EEPROM boot order on node3, reboots it, recovers SSH, and verifies the EEPROM configuration.

```bash
ansible-playbook playbooks/rpi_bootmode.yml \
  -e nodes=node3 -e boot_mode=net_prio -e debug=true
```

**Step 6 — Configure SSH key authentication**

Once node3 is running on the new NFS image, replace password authentication with the cluster SSH key.

```bash
ansible-playbook playbooks/ssh_config.yml \
  -e nodes=node3 -e ssh_mode=config
```
