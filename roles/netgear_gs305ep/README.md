# Role: netgear_gs305ep

Controls the **Netgear GS305EP** PoE+ switch via the `ntgrrc` CLI binary (bundled at `roles/netgear_gs305ep/files/ntgrrc`). Supports enabling/disabling/toggling PoE power per port and applying full port configuration (speed, flow control, PoE mode).

The switch IP and port assignments come from the inventory: `switch_ip` is an `[all:vars]` variable, and each host entry carries a `switch_port` number.

## Task flow

| Task file | Runs when | Description |
|-----------|-----------|-------------|
| `switch_config.yml` | always | Reads switch credentials, validates connection to `switch_ip` |
| `show_config.yml` | `debug: true` | Prints current port configuration for all switch ports |
| `port_config.yml` | `config: true` | Applies `gs305ep_config` data structure (speed, flow control, PoE mode) per port |
| `poe_config.yml` | `poe_action in [enable, disable, toggle]` | Calls `ntgrrc` to set PoE power state on the ports associated with targeted nodes |

## Key variables

| Variable | Default | Description |
|----------|---------|-------------|
| `switch_password` | *(none — from vault)* | Switch admin login password, defined in `inventories/rpi_linux/group_vars/all/vault.yml`. See [vault.md](../../docs/vault.md). |
| `poe_action` | `null` | PoE operation: `enable`, `disable`, or `toggle` |
| `config` | `false` | Set to `true` to apply port configuration |
| `ntgrrc_bin` | `{{ role_path }}/files/ntgrrc` | Path to the ntgrrc binary |
| `gs305ep_port_defaults.speed` | `Auto` | Default port speed |
| `gs305ep_port_defaults.flow_control` | `On` | Default flow control setting |
| `gs305ep_port_defaults.mode` | `legacy` | Default PoE mode |
| `gs305ep_port_defaults.power` | `enable` | Default PoE power state |
| `debug` | `false` | Print port config before changes |

The per-host `switch_port` inventory variable maps each node to its physical switch port number.

## Usage

```bash
# Enable PoE on node1 and node2 ports
ansible-playbook playbooks/netgear_gs305ep.yml -e nodes=node1,node2 -e poe_action=enable

# Disable PoE on node3
ansible-playbook playbooks/netgear_gs305ep.yml -e nodes=node3 -e poe_action=disable

# Toggle PoE on node1 (power cycle)
ansible-playbook playbooks/netgear_gs305ep.yml -e nodes=node1 -e poe_action=toggle

# Apply full port configuration
ansible-playbook playbooks/netgear_gs305ep.yml -e nodes=node1 -e config=true
```
