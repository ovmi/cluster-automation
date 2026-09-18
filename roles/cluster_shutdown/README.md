# Role: cluster_shutdown

Shuts down the targeted cluster nodes. Nodes are stopped one at a time to avoid a simultaneous power-off that could corrupt shared storage.

## Task flow

| Task file | Description |
|-----------|-------------|
| `nodes_shutdown.yml` | Issues `ansible.builtin.command: shutdown -h now` |

## Variables

None — the role takes its target set from the dynamic group resolved by the playbook pre-tasks.

## Usage

```bash
ansible-playbook playbooks/cluster_power_manager.yml -e nodes=node0,node1 -e mode=shutdown [-e debug=true]
```

Omit `-e nodes` to shut down all cluster nodes. Recommended shutdown order: workers first, then the control node (`node0`).
