# Role: common

Shared pre-task utilities included by other playbooks via `tasks_from:`. This role has no `main.yml` — it is never applied as a full role, only individual task files are imported.

## Task files

### `node_check.yml`
Normalises the `nodes` extra-var (comma-separated string or list), validates each entry against `hostname_map`, and sets two facts consumed by the calling playbook:

| Fact | Value |
|------|-------|
| `resolved_hosts` | list of Ansible hostnames (e.g. `[rpi-node0, rpi-node3]`) |
| `node_host_map` | dict mapping logical IDs to hostnames (e.g. `{node0: rpi-node0}`) |

If `nodes` is omitted or empty, all keys from `hostname_map` are targeted.  
Pass `-e debug=true` to print the resolved values.

### `slot_check.yml`
Validates the `slot` extra-var (`a` or `b`) used by `rpi_nvme_provision` and `rpi_pxe_server`. Fails early with a clear message if an invalid value is passed.

### `ansible_check.yml`
Asserts that the minimum required Ansible version is present on the control machine before a playbook proceeds.

## Usage pattern

```yaml
pre_tasks:
  - name: Check parameters for valid nodes
    ansible.builtin.include_role:
      name: common
      tasks_from: node_check.yml
```

`node_check.yml` must always run on `localhost` (before the cluster play) so that `resolved_hosts` is available for `add_host`.
