# Role: k3s_monitoring_stack

Deploys a full observability stack into the K3s cluster using Helm: Prometheus (via `kube-prometheus-stack`), Grafana, and Traefik as the ingress controller. Runs entirely on the control node (`groups['control'][0]`).

## Task flow

| Task file | Description |
|-----------|-------------|
| `pre_install.yml` | Installs Helm if absent, adds the `prometheus-community` and Traefik Helm repos, creates the `monitoring` namespace |
| `prometheus_install.yml` | Creates the `monitoring-grafana` admin-credentials secret, then installs/upgrades `kube-prometheus-stack` via Helm (pointed at that secret via `grafana.admin.existingSecret`) |
| `grafana_install.yml` | Waits for the Grafana deployment to become available, adds its hostname to `/etc/hosts` |
| `traefik_install.yml` | Installs/upgrades the Traefik Helm chart in the `traefik` namespace |
| `ingress_config.yml` | Applies `IngressRoute` or `Ingress` objects for Prometheus (`prometheus.cluster.local`) and Grafana (`grafana.cluster.local`) |

## Key variables

| Variable | Default | Description |
|----------|---------|-------------|
| `monitoring_namespace` | `monitoring` | Kubernetes namespace for the monitoring stack |
| `prometheus_enabled` | `true` | Toggle Prometheus deployment |
| `grafana_enabled` | `true` | Toggle Grafana deployment |
| `prometheus_replicas` | `1` | Prometheus pod replicas |
| `grafana_replicas` | `1` | Grafana pod replicas |
| `prometheus_port` | `9090` | Prometheus service port |
| `grafana_port` | `80` | Grafana service port |
| `prometheus_hostname` | `prometheus.cluster.local` | Ingress hostname for Prometheus |
| `grafana_hostname` | `grafana.cluster.local` | Ingress hostname for Grafana |
| `traefik_namespace` | `traefik` | Namespace for the Traefik chart |
| `helm_release_monitoring` | `monitoring` | Helm release name — matches namespace for consistent resource naming |
| `kube_manifests_dir` | `/home/k3sadmin/k3s-manifests` | Staging directory on the control node for rendered manifests |
| `helm_install_timeout` | `15m` | `kubernetes.core.helm`'s wait timeout for the initial install — see below before lowering it |

### The initial install needs more than Helm's default 5-minute wait

`prometheus_install.yml`'s `kubernetes.core.helm` task installs Prometheus, Alertmanager, Grafana, kube-state-metrics, the operator, and a node-exporter DaemonSet all at once, all pulling images and starting simultaneously. On this hardware that has been observed taking close to 10 minutes for Grafana to report `Ready` — well past `kubernetes.core.helm`'s own 5-minute default `wait` timeout, which fails the whole task with `context deadline exceeded` even though nothing is actually broken. `helm_install_timeout` (default `15m`) exists to give it real headroom. If this happens anyway: `helm status monitoring -n monitoring` and `kubectl get pods -n monitoring` will usually show everything already healthy despite Helm marking the release `failed` — that's a terminal state, not a lock, so simply re-running the task (or the whole playbook) creates a new revision and succeeds immediately against the already-running pods; no `helm rollback` needed.

## Grafana admin credentials secret

`prometheus_install.yml` creates the `monitoring-grafana` secret (from `grafana_admin_user`/`grafana_admin_password`) *before* the Helm install, and passes `grafana.admin.existingSecret: monitoring-grafana` in the initial install's values. This matters: if the chart is ever installed without `existingSecret` set, that first Helm revision renders and owns the Secret itself — any later `helm upgrade` (from this role or another, e.g. `rpi_cpu_temp_mon_kube`) that sets `existingSecret` omits the Secret from its manifest, and Helm's diff against the owning revision treats that as "no longer desired" and deletes it, breaking the running Grafana pod. Don't remove `existingSecret` from the initial install's values without removing it everywhere else too.

## Operational reference

```bash
# Port-forward for direct access during development
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090

# Check Helm release status
helm get values monitoring -n monitoring
helm history monitoring -n monitoring

# Restart Grafana after config changes
kubectl rollout restart deployment monitoring-grafana -n monitoring
```

## Usage

```bash
ansible-playbook playbooks/k3s_monitoring_stack.yml
```

The playbook targets the `control` inventory group directly; no `nodes` parameter is needed.
