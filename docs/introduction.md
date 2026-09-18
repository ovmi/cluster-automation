# Introduction

A fully automated infrastructure for a four-node Raspberry Pi cluster that handles everything from **NVMe flashing** and **PXE boot configuration** to **K3s deployment**, **GlusterFS storage**, and **Prometheus + Grafana monitoring**.

![Cluster Diagram](images/cluster_presentation.jpg)

This setup combines high-speed NVMe storage, an AI accelerator, distributed SSD bricks, and an LTE failover node — all interconnected through a Gigabit Ethernet switch and orchestrated by automated Ansible playbooks.

## Goals

The goal of this project is to build a **self-provisioning Raspberry Pi cluster** capable of:

- Booting worker nodes directly from images flashed on an NVMe SSD (PXE/NFS).
- Managing distributed storage through GlusterFS.
- Running lightweight Kubernetes (K3s) for container workloads.
- Providing system monitoring and alerting through Prometheus and Grafana.
- Maintaining automated network routing with LTE failover redundancy.

Automation is achieved using modular Ansible roles that can bring the cluster from bare-metal to a fully operational, monitored Kubernetes environment.

## Where to go next

| Doc | Covers |
|-----|--------|
| [hardware.md](hardware.md) | Physical nodes, network topology, power |
| [architecture.md](architecture.md) | Software layers, Ansible conventions, repository layout |
| [vault.md](vault.md) | Secrets management setup |
| [provisioning.md](provisioning.md) | Raspberry Pi from-scratch setup sequence, maintenance, recovery |
| [x86_linux.md](x86_linux.md) | x86 Linux (VM/container) target: prerequisites and playbook sequence |
| [commands.md](commands.md) | Full playbook command reference |
| [monitoring.md](monitoring.md) | Prometheus + Grafana architecture |
| [development.md](development.md) | Dev tools, required collections, roadmap |
