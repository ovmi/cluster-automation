# Role: k3s_glusterfs

Creates the Kubernetes storage primitives (StorageClass, PersistentVolume, PersistentVolumeClaim) that expose the GlusterFS volume already mounted by `glusterfs_setup` to K3s workloads. All Kubernetes API calls are delegated to the control node (`gluster_control_host`) using the K3s kubeconfig.

## Task flow

| Task file / block | Runs on | Description |
|-------------------|---------|-------------|
| kubeconfig check | control only | Asserts `/etc/rancher/k3s/k3s.yaml` exists; fails if the control node is not the K3s server |
| `gluster-sc.yaml.j2` apply | control only (`run_once`) | Creates a static `StorageClass` named `gluster-static` |
| `gluster-pv.yaml.j2` apply | control only (`run_once`) | Creates a `PersistentVolume` backed by the GlusterFS hostpath |
| `gluster-pvc.yaml.j2` apply | control only (`run_once`) | Creates a `PersistentVolumeClaim` bound to the PV |
| `gluster_pod_test.yml` | all | Runs a test pod that mounts the PVC and verifies read/write |
| `gluster_deployment.yml` | all | Deploys a production pod using GlusterFS storage |

## Key variables

| Variable | Default | Description |
|----------|---------|-------------|
| `gluster_namespace` | `default` | Kubernetes namespace for storage objects |
| `gluster_pv_name` | `gluster-pv` | PersistentVolume name |
| `gluster_pvc_name` | `gluster-pvc` | PersistentVolumeClaim name |
| `gluster_storage_class_name` | `gluster-static` | StorageClass name |
| `gluster_static_pv_size` | `1Gi` | PV capacity |
| `gluster_access_mode` | `ReadWriteMany` | PV access mode |
| `gluster_hostpath` | `/mnt/glusterfs-volume` | Host path where GlusterFS volume is mounted (must match `glusterfs_setup`) |
| `gluster_node_name` | `{{ hostname_map[k3s_control] }}` | Node affinity for the test/production pods (not the PV itself — hostPath PVs carry no node affinity) — resolves to the control node's Kubernetes node name |
| `gluster_deployment_name` | `gluster-deploy` | Name of the production Deployment/pods created by `gluster_deployment.yml` |
| `gluster_pod_test_name` | `gluster-test` | Name of the throwaway pod `gluster_pod_test.yml` creates, waits on, and deletes |
| `kubeconfig_path` | `{{ k3s_kubeconfig }}` | K3s kubeconfig path on the control node |

## Dependencies

Requires `glusterfs_setup` to have already mounted the volume at `gluster_hostpath` on the control node, and K3s to be running. The `python3-kubernetes` package is installed automatically on the delegate host.

## Usage

This role is applied automatically by `playbooks/glusterfs_setup.yml` after `glusterfs_setup` completes:

```bash
ansible-playbook playbooks/glusterfs_setup.yml -e nodes=node0,node3 -e glusterfs_mode=install
```
