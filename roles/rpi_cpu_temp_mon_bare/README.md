# Role: rpi_cpu_temp_mon_bare

Installs and configures CPU temperature monitoring for a **bare-metal** (non-Kubernetes) cluster. Deploys Prometheus on the control node and Node Exporter as a systemd service on every node. A textfile collector script writes CPU temperature metrics that Node Exporter then exposes.

Use the sibling role `rpi_cpu_temp_mon_kube` when K3s is running.

## How it works

A cron job runs `/usr/local/bin/temperature.sh` every minute on each node. The script reads `/sys/class/thermal/thermal_zone0/temp` directly (the standard Linux kernel thermal interface, not a Pi-specific tool — confirmed working unmodified across Pi 4 and Pi 5), then writes it in Prometheus textfile format to `/var/lib/node_exporter/textfile_collector/temperature.prom`. Node Exporter (systemd service) reads that directory and exposes `node_cpu_temperature_celsius`. Prometheus (on the control node) scrapes all Node Exporters.

```
cron (every 1 min)
  └─ temperature.sh
       └─ temperature.prom   (/var/lib/node_exporter/textfile_collector/)
            └─ Node Exporter (systemd, :9100)
                 └─ Prometheus scrape (:9090, control node only)
```

## Task flow

| Task file | Runs on | Description |
|-----------|---------|-------------|
| `prometheus_install.yml` | control (`groups['control'][0]`) | Downloads Prometheus binary, installs systemd service, deploys `prometheus.yml` scrape config |
| `node_exporter_install.yml` | all nodes | Downloads Node Exporter binary, creates dedicated system user, installs systemd service with textfile collector |
| `cpu_temp_mon_config.yml` | all nodes | Deploys temperature collection script and cron job |

## Key variables

| Variable | Default | Description |
|----------|---------|-------------|
| `node_exporter_version` | `1.7.0` | Node Exporter release to download |
| `node_exporter_collector` | `/var/lib/node_exporter/textfile_collector` | Directory Node Exporter reads for `.prom` files |
| `node_exporter_port` | `9100` | Node Exporter listen port |
| `prometheus_version` | `2.52.0` | Prometheus release to download |
| `prometheus_port` | `9090` | Prometheus listen port |

## Usage

```bash
ansible-playbook playbooks/rpi_cpu_temp_monitor.yml \
  -e nodes=node0,node1,node2,node3 \
  -e temp_monitor_mode=bare
```

## Verifying temperature collection

**1. Check the cron job is installed on each node:**

```bash
ansible all -i inventories/rpi_linux/hosts -m command \
  -a "crontab -l" --become
```

**2. Check the .prom file is being written:**

```bash
ansible all -i inventories/rpi_linux/hosts -m command \
  -a "cat /var/lib/node_exporter/textfile_collector/temperature.prom" --become
# Expected output on each node:
# # HELP node_cpu_temperature_celsius CPU temperature in Celsius
# # TYPE node_cpu_temperature_celsius gauge
# node_cpu_temperature_celsius 52.7
```

**3. Verify Node Exporter exposes the metric:**

```bash
# Replace IP with the target node's address
curl -s http://192.168.100.10:9100/metrics | grep node_cpu_temperature
# node_cpu_temperature_celsius 52.7
```

**4. Query Prometheus directly:**

```bash
# Port-forward or access from the control node
curl -s 'http://192.168.100.10:9090/api/v1/query?query=node_cpu_temperature_celsius' | python3 -m json.tool
# Or open http://192.168.100.10:9090 in a browser
```

## Checking temperature in Prometheus (bare mode)

Bare mode does not include Grafana — metrics are queried directly via the Prometheus web UI at `http://192.168.100.10:9090`.

1. Open `http://192.168.100.10:9090` in a browser
2. Navigate to **Graph** and enter a PromQL query

**Useful PromQL queries:**

| Query | Description |
|-------|-------------|
| `node_cpu_temperature_celsius` | Current temperature for all nodes |
| `node_cpu_temperature_celsius{instance=~"192.168.100.1[0-3]:9100"}` | Filter to cluster nodes only |
| `max_over_time(node_cpu_temperature_celsius[1h])` | Peak temperature in the last hour per node |
| `avg by (instance) (node_cpu_temperature_celsius)` | Average temperature per node |

**If no data appears:**
- Confirm the cron job ran: `ls -la /var/lib/node_exporter/textfile_collector/` on the node
- Check Node Exporter is running: `systemctl status node_exporter`
- Verify Prometheus scrape targets: Prometheus UI → **Status → Targets** — all node-exporter targets should be `UP`
- Check scrape config: `cat /etc/prometheus/prometheus.yml`
