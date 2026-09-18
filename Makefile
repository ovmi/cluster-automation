
.PHONY: collections
collections:
	ansible-galaxy collection install -r ansible/collections/requirements.yml

.PHONY: lint
lint:
	ansible-lint
	shellcheck -x -P SCRIPTDIR scripts/*.sh

.PHONY: status
status:
	scripts/cluster_status.sh

.PHONY: provision
provision:
	scripts/cluster_full_provision.sh

.PHONY: powerup
powerup:
	scripts/cluster_powerup.sh

.PHONY: shutdown
shutdown:
	scripts/cluster_shutdown.sh
