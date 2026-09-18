# Role: rpi_cpu_temp_mon_kube

Extends the Prometheus + Grafana monitoring stack already deployed by `k3s_monitoring_stack` with CPU temperature metrics. Configures Node Exporter (running as a Kubernetes DaemonSet) to expose a textfile collector directory, deploys the temperature script on every node, and upgrades the Helm chart with updated values.

Use the sibling role `rpi_cpu_temp_mon_bare` when K3s is not running.

## How it works

A cron job runs `/usr/local/bin/temperature.sh` every minute on each node. The script reads `/sys/class/thermal/thermal_zone0/temp` directly (the standard Linux kernel thermal interface, not a Pi-specific tool — confirmed working unmodified across Pi 4 and Pi 5), then writes it in Prometheus textfile format to `/var/lib/node_exporter/textfile_collector/temperature.prom`. The Node Exporter DaemonSet mounts that host path and exposes the metric as `node_cpu_temperature_celsius`. Prometheus scrapes Node Exporter; Grafana visualises it.

```
cron (every 1 min)
  └─ temperature.sh
       └─ temperature.prom   (/var/lib/node_exporter/textfile_collector/)
            └─ Node Exporter (DaemonSet, host path mount)
                 └─ Prometheus scrape
                      └─ Grafana dashboard
```

## Task flow

| Task file | Runs on | Description |
|-----------|---------|-------------|
| `grafana_config.yml` | control only | Creates the `grafana-smtp-secret` K8s secret for alert email |
| `upgrade_release_chart.yml` | control only | Runs `helm upgrade` on the `monitoring` release with updated values |
| `cpu_temp_mon_config.yml` | all nodes | Creates `node_exporter` user/group, collector directory, temperature script, and cron job |

### Grafana secret must stay pointed at `monitoring-grafana`

`upgrade_release_chart.yml` runs `helm upgrade` without `--reuse-values`, so `templates/release-values.yaml.j2` is the *entire* values input for that upgrade — nothing from the initial `k3s_monitoring_stack` install carries over automatically. Its `grafana.admin.existingSecret: monitoring-grafana` block (mirroring the same setting in `roles/k3s_monitoring_stack/tasks/prometheus_install.yml`) has to stay in sync with that role: drop it here and the chart falls back to rendering its own Grafana secret, which collides with the existing non-Helm-owned one and fails the upgrade with an ownership-metadata error.

## Key variables

| Variable | Default | Description |
|----------|---------|-------------|
| `node_exporter_collector` | `/var/lib/node_exporter/textfile_collector` | Host path mounted into Node Exporter pods |
| `node_exporter_user` | `node_exporter` | OS user that owns the collector dir and runs the cron job |
| `smtp_host` | `smtp.gmail.com:465` | Grafana alert SMTP host |
| `smtp_user` | `ovidiu.mihalachi@gmail.com` | SMTP sender address |
| `grafana_smtp_password` | `{{ lookup('env', 'GRAFANA_SMTP_PASSWORD') }}` | Read from environment — export before running |

## Usage

```bash
GRAFANA_SMTP_PASSWORD=xxx \
  ansible-playbook playbooks/rpi_cpu_temp_monitor.yml \
  -e nodes=node0,node1,node2,node3 \
  -e temp_monitor_mode=kube
```

## Verifying temperature collection

**1. Check the cron job is installed on each node:**

```bash
ansible all -i inventories/rpi_linux/hosts -m command \
  -a "crontab -u node_exporter -l" --become
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
# From any node (replace IP with target node's address)
curl -s http://192.168.100.10:9100/metrics | grep node_cpu_temperature
# node_cpu_temperature_celsius 52.7
```

**4. Query Prometheus directly:**

```bash
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090
# Then open http://localhost:9090 and run:
# node_cpu_temperature_celsius
```

## Checking temperature in Grafana

No dashboard is provisioned automatically — see [`docs/monitoring.md`](../../docs/monitoring.md#visualizing-metrics-in-grafana) for the full procedure: getting the admin password, confirming the Prometheus data source, and importing the ready-made `roles/rpi_cpu_temp_mon_bare/files/cpu_temperature.json` dashboard (or building a panel from scratch).

**Useful PromQL queries** (enter in Grafana Explore or the panel editor):

| Query | Description |
|-------|-------------|
| `node_cpu_temperature_celsius` | Current temperature for all nodes |
| `node_cpu_temperature_celsius{instance=~"192.168.100.1[0-3]:9100"}` | Filter to cluster nodes only |
| `max_over_time(node_cpu_temperature_celsius[1h])` | Peak temperature in the last hour per node |
| `avg by (instance) (node_cpu_temperature_celsius)` | Average temperature per node |

**If no data appears:**
- Confirm the cron job ran: `ls -la /var/lib/node_exporter/textfile_collector/` on the node
- Check Node Exporter pod logs: `kubectl logs -n monitoring -l app.kubernetes.io/name=node-exporter`
- Verify Prometheus scrape targets: Prometheus UI → **Status → Targets** — all node-exporter targets should be `UP`
