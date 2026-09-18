# Role: lte_gateway

Configures LTE modem connectivity, automatic WAN failover, and cluster-wide gateway switching on the designated bridge node (default: `node3`). Supports two modem operating modes — ECM and QMI — for the Quectel EC25/EG25 modem (USB ID `2c7c:0125`).

## Architecture

### Normal operation

```
node0 / node1 / node2
        │  default gw → 192.168.100.1 (LAN router)
        │
   [LAN switch]
        │
      node3 (eth0: 192.168.100.13)
        │  default gw → 192.168.100.1 (LAN router)
        │
   [LAN router 192.168.100.1]
        │
     Internet
```

### LAN upstream failure — failover to LTE

```
node0 / node1 / node2
        │  default gw → 192.168.100.13 (node3)
        │
   [LAN switch]  ← still working locally
        │
      node3 (eth0: 192.168.100.13)
        │  default gw → LTE gateway (192.168.225.1 / wwan0)
        │  IP forwarding + NAT masquerade on LTE interface
        │
   [LTE modem usb0/wwan0]
        │
     Internet
```

Two independent services implement this at two layers:

| Service | Node(s) | Manages |
|---------|---------|---------|
| `route-monitor` | node3 only | node3's own default route in the main table: LAN gateway ↔ LTE gateway |
| `cluster-gw-monitor` | node0 / node1 / node2 | each node's default route: LAN gateway (192.168.100.1) ↔ node3 LAN IP (192.168.100.13) |

Both services run a continuous polling loop. Even while on LTE, the LAN gateway is probed every cycle. A configurable number of consecutive successful probes (`recover_threshold`) is required before switching back — preventing flapping on an unstable link.

### Policy-based routing (node3 only)

Two custom tables registered in `/etc/iproute2/rt_tables`:

| Table ID | Name | Default route |
|----------|------|---------------|
| 200 | `lte` | via `lte_gateway_ip` dev LTE interface |
| 201 | `lan` | via `lan_gateway_ip` dev `eth0` |

Two `ip rule` entries control node3's own outbound traffic:

| Priority | Rule | Effect |
|----------|------|--------|
| 100 | from `<node3-ip>` lookup `lan` | node3's own traffic prefers LAN |
| 200 | from `<node3-ip>` lookup `lte` | LTE fallback for node3's own traffic |

Forwarded traffic from other cluster nodes uses the **main table** default route, which is actively managed by `route-monitor`.

### NAT / forwarding (node3 only)

iptables rules applied and persisted via `iptables-persistent`:

- `FORWARD`: LAN → LTE — `ACCEPT`
- `FORWARD`: LTE → LAN — `ACCEPT` for `RELATED,ESTABLISHED`
- `nat POSTROUTING`: LTE interface — `MASQUERADE`

---

## LTE modes

### ECM mode

The modem exposes a USB-Ethernet interface (`usb0`). The modem acts as a small NAT router; the host receives an IP via DHCP (`192.168.225.x`). The LTE gateway is static and known at Ansible deploy time, so `restore-routes.sh` can restore the LTE routing table entry on every reboot.

### QMI mode

The modem exposes a control device (`/dev/cdc-wdm0`) and a raw-IP data interface (`wwan0`). IP, mask, gateway, DNS, and MTU are parsed from `qmicli` output and configured manually. Provides full visibility into connection parameters. The LTE gateway is dynamic (assigned per session), so `restore-routes.sh` skips the LTE table entry — it is set by `lte_qmi.yml` when the data session is established.

---

## Task flow

| Task file | Runs on | What it does |
|-----------|---------|--------------|
| `common.yml` | node3 | Removes `ModemManager`; installs `usbutils iproute2 iputils-ping iptables`; detects modem USB ID via `lsusb`, sets `lte_modem_present` |
| `lte_ecm.yml` | node3, `lte_mode == ecm`, modem present | Asserts `usb0` is present; pings `lte_test_ip` via the interface |
| `lte_qmi.yml` | node3, `lte_mode == qmi`, modem present | Asserts `/dev/cdc-wdm0` and `wwan0`; sets `raw_ip=Y`; starts QMI session; configures interface and routes; pings to verify |
| `routing_setup.yml` | node3, modem present | Gathers network facts; registers routing tables; enables IP forwarding; adds iptables FORWARD + MASQUERADE rules; adds policy routing rules; installs `iptables-persistent`; persists rules; renders `restore-routes.sh` |
| `route-monitor` deploy | node3, modem present | Renders `switch_routes.sh.j2` → `/usr/local/bin/route-monitor.sh`; installs and enables `route-monitor.service` |
| `cluster_gw_monitor.yml` | node0/1/2, modem present on the bridge host | Renders `cluster-gw-monitor.sh` and its systemd unit; enables and starts `cluster-gw-monitor.service` |
| Fallback DNS deploy | all 4 nodes, `systemd-resolved.service` present | Renders `resolved-fallback.conf.j2` → `/etc/systemd/resolved.conf.d/fallback.conf`; restarts `systemd-resolved` |

### No modem present is a silent skip, not a failure

`common.yml` detects the modem via `lsusb` (matching `lte_modem_usb_id`) and sets `lte_modem_present` instead of hard-failing when it's absent. Every modem-dependent task after it (`lte_ecm.yml`/`lte_qmi.yml`, `routing_setup.yml`, the `route-monitor` deploy) is gated on that fact, so a node3 without a modem plugged in just shows those tasks as `skipping` — the playbook still exits `0`. This matters for `scripts/cluster_full_provision.sh`: a missing modem no longer blocks the rest of a full provisioning run.

Re-running the role once a modem is present picks it up automatically (`lte_modem_present` is re-detected fresh every run, never cached). A modem that *is* present but in the wrong mode (e.g. `lte_mode: qmi` configured against a modem still in ECM firmware mode) is a different, still-hard-failing case — `lte_ecm.yml`/`lte_qmi.yml`'s own interface/device asserts are unchanged.

`cluster_gw_monitor.yml` (node0/1/2) is also gated on the bridge host's modem presence — via `hostvars[lte_bridge_host].lte_modem_present`, since that fact only exists on node3's own host context — not just `inventory_hostname != lte_bridge_host`. Deploying `cluster-gw-monitor` pointed at a node3 with no actual LTE failover configured would mean a real LAN outage has nowhere to fail over to; skipping it too means the whole role is a clean no-op everywhere until a modem shows up, not a partial, misleadingly-successful-looking deployment on three of the four nodes.

### The fallback DNS config only applies where `systemd-resolved` actually exists

Unlike the modem-gated tasks above, the DNS fallback deploy runs on all 4 nodes unconditionally by design (it has nothing to do with LTE) — but not every node necessarily runs `systemd-resolved` as its resolver. A `service_facts` check (`'systemd-resolved.service' in ansible_facts.services`) gates both the config deploy and its restart handler, matching the same pattern `roles/cluster_update` uses for its `NetworkManager.service` check. Without it, the `Restart systemd-resolved` handler fails outright on any node where the unit doesn't exist at all (`Could not find the requested service systemd-resolved: host`) — confirmed live on a node running a different base OS than its siblings (no `systemd-resolved` package at all there).

---

## Key variables

| Variable | Default | Description |
|----------|---------|-------------|
| `lte_mode` | `ecm` | Modem operating mode: `ecm` or `qmi` |
| `lte_apn` | `internet` | APN string (Digi Romania: `internet`) |
| `lte_ecm_iface` | `usb0` | ECM mode data interface |
| `lte_qmi_iface` | `wwan0` | QMI mode data interface |
| `lte_qmi_device` | `/dev/cdc-wdm0` | QMI control device path |
| `lte_test_ip` | `1.1.1.1` | IP used for post-setup connectivity check |
| `lte_modem_usb_id` | `2c7c:0125` | Expected USB vendor:product ID |
| `lan_iface` | `eth0` | Wired LAN interface |
| `lan_gateway_ip` | `192.168.100.1` | LAN gateway (from `group_vars`) |
| `lte_gateway_ip` | `192.168.225.1` | LTE modem gateway (from `group_vars`) |
| `route_check_interval` | `10` | Seconds between LAN/LTE reachability probes |
| `fail_threshold` | `3` | Consecutive probe failures required before switching to LTE |
| `recover_threshold` | `3` | Consecutive probe successes required before reverting to LAN |
| `debug` | `false` | Print intermediate facts and command output |

---

## Usage

```bash
# node3 only — LTE setup + node3 failover (no cluster-wide switching)
ansible-playbook playbooks/lte_gateway.yml -e nodes=node3

# QMI mode
ansible-playbook playbooks/lte_gateway.yml -e nodes=node3 -e lte_mode=qmi

# Full cluster — LTE gateway on node3 + cluster-wide switching on node0/1/2
ansible-playbook playbooks/lte_gateway.yml \
  -e nodes=node0,node1,node2,node3

# Tune debounce: fail after 5 bad probes, recover after 4 clean probes, check every 15 s
ansible-playbook playbooks/lte_gateway.yml \
  -e nodes=node0,node1,node2,node3 \
  -e fail_threshold=5 \
  -e recover_threshold=4 \
  -e route_check_interval=15
```

---

## Boot-time route recovery (`restore-routes.sh`)

Routing tables and `ip rule` entries are not persisted by the kernel across reboots. `restore-routes.sh` is called by `route-monitor.service` via `ExecStartPre` on every start or restart, before the monitor loop begins:

1. Ensures `200 lte` and `201 lan` entries exist in `/etc/iproute2/rt_tables`
2. Sets `net.ipv4.ip_forward = 1`
3. Adds `table lan` default route via `lan_gateway_ip`
4. **ECM only**: adds `table lte` default route via `lte_gateway_ip` (static)
5. **QMI**: skips the LTE table entry — the QMI data session sets it dynamically
6. Adds `ip rule from <node3-ip> lookup lan priority 100`
7. Adds `ip rule from <node3-ip> lookup lte priority 200`

The `-` prefix on `ExecStartPre` means the service still starts if the script fails (e.g., QMI interface not yet up on boot).

---

## Failover state machines

Both `route-monitor.sh` (node3) and `cluster-gw-monitor.sh` (other nodes) implement the same debounced state machine:

```
         ┌─────────────────────────────────────┐
         │              [ lan ]                │
         │  probe ok  → ok_count++             │
         │  probe fail → fail_count++          │
         │  fail_count ≥ FAIL_THRESHOLD?        │
         │    LTE/node3 reachable → switch      │
         │    else                → [ down ]    │
         └──────────────┬──────────────────────┘
                        │ switch
         ┌──────────────▼──────────────────────┐
         │           [ lte / lte_node ]        │
         │  probe ok  → ok_count++             │
         │  probe fail → ok_count = 0          │
         │  ok_count ≥ RECOVER_THRESHOLD?       │
         │    yes → revert to LAN gateway       │
         └─────────────────────────────────────┘
```

The counter resets to zero on any failed probe, so `RECOVER_THRESHOLD` consecutive clean pings are required — not just N successes spread over time.

State files written on every transition:

| File | Written by | Content |
|------|-----------|---------|
| `/run/route-monitor.state` | `route-monitor.sh` | Active gateway IP |
| `/run/cluster-gw.state` | `cluster-gw-monitor.sh` | Active gateway IP |

---

## Monitoring

```bash
# --- node3 ---
systemctl status route-monitor
journalctl -u route-monitor -f
tail -f /var/log/route-monitor.log
cat /run/route-monitor.state          # current active gateway IP

# --- node0 / node1 / node2 ---
systemctl status cluster-gw-monitor
journalctl -u cluster-gw-monitor -f
tail -f /var/log/cluster-gw-monitor.log
cat /run/cluster-gw.state             # current active gateway IP

# --- routing inspection (any node) ---
ip route show table main default      # active default route
ip route show table lan               # node3 only
ip route show table lte               # node3 only
ip rule show                          # node3 only
iptables -t nat -L -n -v              # node3 only
```

---

## Testing failover

> Run all commands on **node3** as root.
>
> **Do not use `ip link set eth0 down` for testing.** Taking the interface down drops the SSH session and changes the failure mode. The real-world scenario is: gateway unreachable, interface still UP.

### 1. Baseline — confirm LAN is active

```bash
ip route show table main default
# expected: default via 192.168.100.1 dev eth0

cat /run/route-monitor.state
# expected: 192.168.100.1
```

### 2. Check LTE gateway before simulating failure

```bash
# QMI mode
ip route show dev wwan0 scope link

# ECM mode
ip route show dev usb0 scope link
```

The first address is what `route-monitor.sh` resolves as the LTE gateway.

### 3. Simulate LAN upstream failure

Block traffic to the LAN gateway without touching `eth0`:

```bash
iptables -I OUTPUT -o eth0 -d 192.168.100.1 -j DROP
iptables -I INPUT  -i eth0 -s 192.168.100.1 -j REJECT
```

Wait `PING_TIMEOUT × PING_COUNT × FAIL_THRESHOLD + CHECK_INTERVAL` seconds (≤ 32 s with defaults) for the threshold to be reached.

### 4. Confirm failover to LTE

```bash
ip route show table main default
# expected: default via 192.168.225.1 dev wwan0  (or usb0 in ECM)

cat /run/route-monitor.state
# expected: 192.168.225.1

ping -c 3 1.1.1.1   # internet via LTE
```

On other nodes (node0/1/2):

```bash
ip route show table main default
# expected: default via 192.168.100.13 dev eth0

cat /run/cluster-gw.state
# expected: 192.168.100.13
```

### 5. Restore LAN

```bash
iptables -D OUTPUT -o eth0 -d 192.168.100.1 -j DROP
iptables -D INPUT  -i eth0 -s 192.168.100.1 -j REJECT
```

Wait `RECOVER_THRESHOLD × CHECK_INTERVAL` seconds (≤ 30 s with defaults) for the consecutive-success counter to fill.

### 6. Confirm failback to LAN

```bash
ip route show table main default
# expected: default via 192.168.100.1 dev eth0

cat /run/route-monitor.state
# expected: 192.168.100.1
```

### Full event log after the test

```bash
grep route-monitor /var/log/route-monitor.log
```

Expected sequence:

```
2026-05-27 10:00:00 Started (LAN=eth0/192.168.100.1 LTE=wwan0 interval=10s ...)
2026-05-27 10:00:00 Init: LAN reachable — using 192.168.100.1
2026-05-27 10:00:00 Gateway changed: <none> → 192.168.100.1
2026-05-27 10:00:32 LAN upstream down (3× fail) — switching to LTE via 192.168.225.1
2026-05-27 10:00:32 Gateway changed: 192.168.100.1 → 192.168.225.1
2026-05-27 10:01:10 LAN recovered (3× ok) — reverting to 192.168.100.1
2026-05-27 10:01:10 Gateway changed: 192.168.225.1 → 192.168.100.1
```

---

## Switching modem mode via AT commands

Connect to the modem AT port:

```bash
screen /dev/ttyUSB2 115200
```

Switch to ECM mode:

```
AT+QCFG="usbnet",1
AT+CFUN=1,1
```

Switch back to QMI mode:

```
AT+QCFG="usbnet",0
AT+CFUN=1,1
```

The modem reboots after `AT+CFUN=1,1`. Re-run the playbook with the matching `lte_mode` after it comes back up.
