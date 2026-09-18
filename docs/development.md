# Development

## Tools

`ansible-lint`, `yamllint`, `molecule`, `ansible-vault`.

## Required collections

```yaml
collections:
  - name: community.general
  - name: ansible.posix
  - name: kubernetes.core
  - name: community.crypto
```

Install with:

```bash
ansible-galaxy collection install -r ansible/collections/requirements.yml
```

## Future enhancements

- Integrate **Hailo AI accelerator** workloads in K3s.
- Expand **NAS** with dynamic Gluster volume management.
- Add **Telegram/MQTT** boot failure alerts.
- Implement **tryboot A/B** OS updates.
