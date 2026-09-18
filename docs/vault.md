# Vault and Secrets Management

`ansible.cfg` points to `~/.vault_pass.txt` for vault decryption. The file must exist on the developer's machine to run any playbook that uses encrypted vars.

Encrypted secrets live in `inventories/rpi_linux/group_vars/all/vault.yml`, applied to every host. The project uses a **variable-indirection pattern**: plaintext files reference a variable name, and the actual value is defined only inside the vault file — never inline the real secret in a non-vault file.

```yaml
# inventories/rpi_linux/host_vars/localhost.yml (plaintext, checked into git)
ansible_become_password: "{{ localhost_sudo_password }}"

# inventories/rpi_linux/group_vars/all/vault.yml (encrypted, defines the real value)
localhost_sudo_password: "correct-horse-battery-staple"
```

## One-time setup on a new developer machine

```bash
# 1. Create the vault password file (a passphrase used to decrypt vault.yml, not a secret value itself)
openssl rand -base64 32 > ~/.vault_pass.txt
chmod 600 ~/.vault_pass.txt
# Share this passphrase with the developer out-of-band (password manager, not git/Slack).
```

If the repo already has `vault.yml` populated (the normal case — see below), get the *existing* passphrase from another team member out-of-band instead of generating a new one, and confirm you can read it before running any playbook:

```bash
ansible-vault view inventories/rpi_linux/group_vars/all/vault.yml
ansible-vault view inventories/x86_linux/group_vars/all/vault.yml
```

## Creating `vault.yml` for the first time

Only needed once per inventory, the very first time that target's `vault.yml` is created — every inventory added to this repo so far already has one, so in practice this is history, not a step you're likely to run again:

```bash
ansible-vault create inventories/rpi_linux/group_vars/all/vault.yml
# or, for the x86 target:
ansible-vault create inventories/x86_linux/group_vars/all/vault.yml
```

This opens `$EDITOR` on an empty buffer. Write one `key: value` pair per line (plain YAML, same as any other vars file), save, and exit — `ansible-vault` encrypts the file in place using the passphrase in `~/.vault_pass.txt` before it ever touches disk unencrypted. Commit the resulting file normally; it's ciphertext (`$ANSIBLE_VAULT;1.1;AES256...`), safe to check into git.

## Adding or changing an entry in an existing `vault.yml`

This is the common case — the file already exists, you're adding one more secret to it (or rotating a value already there):

```bash
ansible-vault edit inventories/rpi_linux/group_vars/all/vault.yml
```

`edit` decrypts the file to a temp location, opens it in `$EDITOR` with the real plaintext values visible, and — once you save and exit — re-encrypts it back in place automatically. You don't run `encrypt`/`decrypt` yourself as separate steps. Inside the editor:

- **New secret:** add a new `some_new_secret_var: <value>` line, then reference `{{ some_new_secret_var }}` from whichever plaintext file/role default needs it (a `host_vars/*.yml`, a role's `defaults/main.yml`, etc.) — never the literal value.
- **Rotating an existing one:** just change the value on its existing line; every plaintext file that references the variable name picks up the new value automatically on the next run, with no other file to touch.

Save and quit your editor as usual (`:wq` in vim, `Ctrl+O`/`Ctrl+X` in nano) — that's what triggers the re-encrypt. Diffing the result (`git diff`) will show the whole ciphertext blob changed, not a readable line-level diff; that's expected for an encrypted file.

Other useful commands:

```bash
# View decrypted contents without editing (and without leaving a decrypted copy on disk)
ansible-vault view inventories/rpi_linux/group_vars/all/vault.yml

# Change the vault password itself (re-encrypts in place with a new passphrase)
ansible-vault rekey inventories/rpi_linux/group_vars/all/vault.yml
```

## Required vars currently expected inside `vault.yml`

| Variable | Used by | Purpose |
|----------|---------|---------|
| `localhost_sudo_password` | `host_vars/localhost.yml` → `ansible_become_password` | sudo password for local `become` tasks run against `localhost` |
| `switch_password` | `roles/netgear_gs305ep/tasks/switch_config.yml` | Netgear GS305EP switch admin login password (the switch's *address*, `switch_ip`, is a plaintext `[all:vars]` inventory var, not vaulted) |
| `grafana_admin_user` | `roles/k3s_monitoring_stack/tasks/prometheus_install.yml` | Grafana admin username, seeded into the `monitoring-grafana` secret before the initial Helm install |
| `grafana_admin_password` | `roles/k3s_monitoring_stack/tasks/prometheus_install.yml` | Grafana admin password, same secret |
| `vault_rpi_node0_password` … `vault_rpi_node3_password` | `host_vars/rpi-nodeN.yml` → `ansible_password`/`ansible_become_password` | Per-node SSH/become password |

`inventories/x86_linux/group_vars/all/vault.yml` is a second, independent encrypted vault for that target — same passphrase file, separate contents. It expects `localhost_sudo_password` plus `vault_vm_node0_password` through `vault_vm_node3_password` (referenced from `inventories/x86_linux/hosts`).

## The one exception — env-var secrets

`grafana_smtp_password` (`roles/rpi_cpu_temp_mon_kube/defaults/main.yml`) is sourced from the `GRAFANA_SMTP_PASSWORD` environment variable rather than vault, so it never touches disk on the control machine at all. Export it before running `playbooks/rpi_cpu_temp_monitor.yml`:

```bash
GRAFANA_SMTP_PASSWORD=xxx ansible-playbook playbooks/rpi_cpu_temp_monitor.yml -e temp_monitor_mode=kube
```
