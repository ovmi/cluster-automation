# Role: cluster_monitoring

Runs per-node health and performance checks across the cluster.

## Checks

| Check | Task file | Runs on |
|-------|-----------|---------|
| Service health | `services.yml` | All nodes |
| Network bandwidth | `server.yml` + `client.yml` | node0 (server), workers (clients) |

### Service health

Uses `service_facts` to build a `service_health` dict — one entry per `monitor_services` item — with values `running`, `stopped`, `failed`, or `absent` when not installed. No task fails on absent services so the same check runs identically on all nodes.

```json
"service_health": {
    "k3s":                "absent",
    "k3s-agent":          "stopped",
    "glusterd":           "running",
    "docker":             "running",
    "route-monitor":      "absent",
    "cluster-gw-monitor": "running"
}
```

Default service list (overridable via `monitor_services`):
- `k3s` — K3s server (node0)
- `k3s-agent` — K3s agent (node1–3)
- `glusterd` — GlusterFS daemon (node2, node3)
- `docker` — Docker engine
- `route-monitor` — LTE route monitor (node3)
- `cluster-gw-monitor` — Cluster gateway failover monitor (node0–2)

### Network bandwidth

`iperf3` in server daemon mode starts on node0 (if not already running). Each worker node connects as a client and reports TX and RX throughput in Mbps.

## Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `monitor_services` | see above | List of systemd service names to probe |

## Task flow

| Task file | Runs on | What it does |
|-----------|---------|--------------|
| `connectivity.yml` | All nodes | Pings nodes; installs `iperf3` via apt; measures RTT per node when `debug=true` |
| `services.yml` | All nodes | Gathers service facts; reports state of each `monitor_services` entry |
| `server.yml` | node0 only | Starts `iperf3 -s -D` if not already running |
| `client.yml` | Workers only | Runs `iperf3 -c <node0-ip>` for 10s with `throttle: 1` (one client at a time); reports raw iperf3 output |

## Usage

```bash
# Full cluster
ansible-playbook playbooks/cluster_monitoring.yml -e nodes=node0,node1,node2,node3

# Subset — service health only on node2 and node3
# (iperf3 client skipped: node0 not in targets, no server started)
ansible-playbook playbooks/cluster_monitoring.yml -e nodes=node2,node3
```

iperf3 clients are serialized via `throttle: 1` on the command task — worker nodes run the bandwidth test one at a time so the server on node0 is never hit concurrently. All other tasks (ping, service health) run in parallel across nodes.
