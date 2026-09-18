# Role: cluster_reboot

Reboots the targeted cluster nodes sequentially. Ansible waits for SSH to become reachable on each host before moving to the next, so the cluster never goes fully offline at once.

## Task flow

| Task file | Description |
|-----------|-------------|
| `nodes_reboot.yml` | Issues `ansible.builtin.reboot` and waits for SSH reconnect |

## Variables

None — the role takes its target set from the dynamic group resolved by the playbook pre-tasks.

## Usage

```bash
ansible-playbook playbooks/cluster_power_manager.yml -e nodes=node0,node1 -e mode=reboot [-e debug=true]
```

Omit `-e nodes` to reboot all cluster nodes.
