# Role: ssh_config

Manages SSH key generation and distribution for the cluster. Supports two modes: `bootstrap` for first-time password-based key deployment, and `config` for steady-state key verification and `known_hosts` maintenance.

## Task flow

`ssh_mode` must be passed explicitly; the role fails if the value is invalid.

| Task file | Runs when | Description |
|-----------|-----------|-------------|
| `cleanup.yml` | `ssh_cleanup: true` | Removes existing entries from `~/.ssh/known_hosts` for all target hosts |
| `generate_key.yml` | always (before `bootstrap.yml`/`config.yml`) | Generates the controller's ed25519 key pair under `~/.ssh/` if the private key is absent |
| `bootstrap.yml` | `ssh_mode == bootstrap` | Uses `sshpass` + `ssh-copy-id` to push the public key to each host using the password from inventory; updates `known_hosts` via `ssh-keyscan` |
| `config.yml` | `ssh_mode == config` | Tests key-based SSH connectivity; updates `known_hosts`; installs the public key on any host where key auth fails; writes the sshd drop-in and restarts `ssh` on each target whose config changed (a task delegated to the target, not a handler, since handlers run on the play host) |
| `install_key.yml` | called from `config.yml` | Handles the actual `authorized_keys` update for a single host |

The SSH target list is built from `groups[ssh_targets_group]` (passed by the playbook) or `resolved_hosts` as a fallback.

### Drop-in filename ordering

`config.yml` writes SSH hardening to `/etc/ssh/sshd_config.d/10-cluster.conf`. The number must sort before cloud-init's own drop-in (typically `50-cloud-init.conf` on Ubuntu) — unlike systemd unit drop-ins, sshd_config's `Include` directive uses first-match-wins semantics (see `sshd_config(5)`), so a *higher* number here would lose to cloud-init's `PasswordAuthentication no` instead of overriding it.

## Key variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ssh_mode` | `config` | Required: `bootstrap` (first run, password auth) or `config` (steady state) |
| `ssh_cleanup` | `false` | Remove existing `known_hosts` entries before proceeding |
| `ssh_key_type` | `ed25519` | Key type for generation |
| `ssh_private_key_file` | `id_ed25519_cluster` | Filename under `~/.ssh/` |
| `ssh_private_key_path` | `~/.ssh/id_ed25519_cluster` | Full path to private key |
| `ssh_known_hosts` | `~/.ssh/known_hosts` | Known hosts file to update |
| `ssh_connection_timeout` | `10` | Seconds before SSH test times out |

## Requirements

`sshpass` must be installed on the control machine for `bootstrap` mode:

```bash
sudo apt install sshpass
```

## Usage

```bash
# First time: push keys using inventory passwords
ansible-playbook playbooks/ssh_config.yml -e nodes=node0,node1 -e ssh_mode=bootstrap

# Steady state: verify and refresh known_hosts
ansible-playbook playbooks/ssh_config.yml -e nodes=node0,node1 -e ssh_mode=config
```
