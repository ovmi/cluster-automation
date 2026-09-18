# Role: rpi_bootmode

Configures the Raspberry Pi EEPROM boot order on targeted nodes using `rpi-eeprom-config`. Supports three named boot sequences that map to `BOOT_ORDER` values. If the EEPROM is changed, the node is rebooted; after reboot, the role optionally verifies the root device matches the expected pattern.

## Boot modes

| `boot_mode` | BOOT_ORDER | Description |
|-------------|-----------|-------------|
| `nvme_prio` | NVMe → SD → USB → restart | node0 — boots from NVMe SSD |
| `sdcard_prio` | SD → NVMe → USB → restart | node0 — fallback/recovery mode (has NVMe) |
| `sdcard_prio_workers` | SD → Network → USB → restart | node1/node2/node3 — fallback/recovery mode (no NVMe; falls back to PXE instead) |
| `net_prio` | Network (PXE) → SD → USB → restart | node1/node2/node3 — boots over NFS |

`net_prio` also sets TFTP parameters: `TFTP_SERVER`, `TFTP_PREFIX=1`, `TFTP_PREFIX_STR=node`, `NET_INSTALL_AT_POWER_ON=1`.

## Task flow

| Task file | Description |
|-----------|-------------|
| `bootmode_check.yml` | Pre-task, not part of `main.yml`'s own flow — called directly from `playbooks/rpi_bootmode.yml`'s `pre_tasks` via `tasks_from:`. Validates the `boot_mode` extra-var against `boot_sequences` and builds the `BOOT_ORDER` hex string from `boot_devices`/`boot_sequences` (both in `defaults/main.yml`). Previously lived in `roles/common` even though it depended entirely on this role's own defaults — moved here since it's the only caller. |
| `eeprom_config.yml` | Reads current EEPROM, computes the target `BOOT_ORDER` string, writes new config via `rpi-eeprom-config --apply`, sets `reboot_required` if changed |
| `reboot.yml` | Reboots the node and waits for SSH if `reboot_required` is true |
| `eeprom_verify.yml` | Re-reads the EEPROM config after reboot and asserts `BOOT_ORDER` matches the value that was applied |

### Confirming the reboot actually started

`reboot.yml` waits for SSH to go down (`bootmode_reboot_down_timeout`) before waiting for it to come back. Without that first check, a `shutdown -r now` that silently failed to fire (bad sudo state, command queued but never executed) looks identical to a node that's just slow to boot — both just show as "not reachable yet" — so this turns that ambiguity into a distinct, fast failure instead of burning the full `bootmode_reboot_up_timeout` waiting for a reboot that never happened.

### EEPROM updates on NFS-root worker nodes

`rpi-eeprom-config --apply` stages its pending update (`pieeprom.upd`/`recovery.bin`) into whatever it detects as the boot filesystem — normally `/boot/firmware`, the vfat partition the SPI bootloader reads at power-on. On worker nodes that partition isn't local: it's bind-mounted on node0 and reached over NFS. That bind mount only became visible to the worker as an NFS client once `rpi_pxe_server` started exporting each per-node tree with `crossmnt` (see `roles/rpi_pxe_server/README.md`) — without it, `/boot/firmware` looked like an empty directory to the worker, `rpi-eeprom-config` silently fell back to writing the update into the worker's plain `/boot` (part of the NFS-mounted ext4 root, never read by the bootloader), and `eeprom_verify.yml` would correctly report `BOOT_ORDER` as unchanged after the reboot. If EEPROM changes on a worker node stop taking effect again, check that the node's export in `/etc/exports.d/cluster.exports` still has `crossmnt` before assuming the role itself regressed.

### Stale staged updates block the next apply

`rpi-eeprom-update` (invoked internally by `--apply`) stages its pending update by `cp`-ing into `/boot/firmware` without `-f`, and never cleans up its own staged files (`pieeprom.upd`/`.sig`/`.bin`, `recovery.bin`, `vl805.bin`/`.sig`) after a successful flash. If a node runs through this role again before those files get overwritten -- or a prior run's staged update was consumed but left the files in place -- the next `--apply` fails outright with `cp: cannot create regular file '/boot/firmware/pieeprom.upd': File exists` instead of just restaging. `eeprom_config.yml` clears any leftover staged files immediately before applying, since a fresh apply always supersedes whatever was staged before.

Worker nodes can also hit a subtler variant of this: after enough churn on `/boot/firmware` within one boot session (repeated stage/reboot cycles, an abrupt PoE power cycle mid-write), the worker's kernel can end up with a stale NFS dentry for a file that's already gone server-side -- it still shows up in `ls` but `stat`/`find` on it fails with ENOENT. `rpi-eeprom-update`'s own internal cleanup uses `find -follow` and dies outright the first time it hits one of these instead of just skipping a missing file (`Failed to remove previous update files`, with `find: '<path>': No such file or directory` in the output). `eeprom_config.yml` drops the node's dentry/inode caches (`echo 2 > /proc/sys/vm/drop_caches`) before touching `/boot/firmware` to force a fresh NFS lookup. If this recurs even after a cache drop, compare the file's state from node0 directly (it hosts the real vfat partition) to rule out actual on-disk corruption before assuming it's just a caching artifact.

### A single node's BOOT_ORDER never changes despite a clean apply

If `eeprom_verify.yml` keeps failing on one specific node across repeated
attempts -- with `eeprom_config.yml`'s apply step reporting a clean
`CREATED UPDATE` / `EEPROM updates pending` (visible with `-e debug=true`),
the staged files (`pieeprom.upd`, `recovery.bin`, etc.) actually disappearing
from `/boot/firmware` after reboot (proving the pre-boot flash stage ran),
and yet `rpi-eeprom-config` still reads back the *old* `BOOT_ORDER` every
time regardless of what was requested -- this isn't the role or the NFS/TFTP
path (rule those out first: same crossmnt/stale-file checks as above). It's
the physical **EEPROM write-protect (WP) header** on the Pi 4B: a small
unpopulated 2-pin pad set near the USB-C power connector that, if bridged
(jumper, solder blob, or incidental contact from mounting hardware),
hardware-blocks writes to the SPI EEPROM while the board keeps booting fine
off whatever was already flashed. The low-level flasher still consumes the
staged files whether or not the write actually stuck, so nothing in the
Ansible-visible logs distinguishes this from a normal successful apply until
the post-reboot verify re-reads the chip. Fix requires physically inspecting
that node's WP pads -- there's nothing to change in software.

### A real EEPROM change takes much longer to come back than a normal reboot

When `eeprom_config.yml` actually changes `BOOT_ORDER` (as opposed to a no-op re-run where it's already correct), the *next* boot isn't a normal one: the bootloader has to flash the staged update into the SPI EEPROM chip itself, then reboots a second time before Linux even starts. On a node also booting off SD card for the first time on a freshly written image, that's stacked on top of the usual first-boot filesystem resize. Both together routinely take several minutes -- `reboot.yml`'s `wait_for` timeout is set to 600s (not the ~60-90s a warm reboot would need) to cover it. If a node still hasn't come back within that window, don't assume it's stuck and PoE-cycle it reflexively -- in practice nodes observed sitting well past their EEPROM apply came back on their own given enough time, and a power cycle mid-flash risks doing real damage to the SPI EEPROM. Check the switch's PoE/link status first (`ansible-playbook playbooks/netgear_gs305ep.yml -e debug=true`) -- if it shows the port link up and power still being drawn, the node is alive and probably still working through this sequence.

## Key variables

| Variable | Default | Description |
|----------|---------|-------------|
| `boot_mode` | (required) | One of `nvme_prio`, `sdcard_prio`, `sdcard_prio_workers`, `net_prio` |
| `bootmode_reboot` | `true` | Reboot node if EEPROM was changed |
| `bootmode_verify_root` | `true` | Verify root device after reboot |
| `bootmode_reboot_down_timeout` | `90` | Seconds to wait for SSH to drop after issuing the reboot, confirming it actually started |
| `bootmode_reboot_up_timeout` | `600` | Seconds to wait for SSH to come back -- sized for the EEPROM recovery-flash + second reboot a real change triggers, not a normal warm reboot |
| `tftp_server` | `{{ hostvars['rpi-node0'].ansible_host }}` | TFTP server IP injected into net_prio EEPROM config |
| `debug` | `false` | Print EEPROM diff before/after |

## Usage

```bash
# Set NVMe boot priority on node0
ansible-playbook playbooks/rpi_bootmode.yml -e nodes=node0 -e boot_mode=nvme_prio

# Set PXE network boot on worker nodes
ansible-playbook playbooks/rpi_bootmode.yml -e nodes=node1,node2,node3 -e boot_mode=net_prio

# Reset to SD card for recovery -- workers first (no NVMe, falls back to
# PXE), then node0 (has NVMe, falls back to it)
ansible-playbook playbooks/rpi_bootmode.yml -e nodes=node1,node2,node3 -e boot_mode=sdcard_prio_workers
ansible-playbook playbooks/rpi_bootmode.yml -e nodes=node0 -e boot_mode=sdcard_prio
```
