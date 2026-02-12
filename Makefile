TF_DIR  := terraform
SSH_KEY := $(TF_DIR)/id_ed25519
IP      := $(shell terraform -chdir=$(TF_DIR) output -raw server_ip 2>/dev/null)

.PHONY: setup destroy ssh logs restart update status

## Setup & teardown ─────────────────────────────

setup:                ## Provision server and verify
	@./setup.sh

destroy:              ## Tear down all infrastructure
	@./destroy.sh

## Server access ────────────────────────────────

ssh:                  ## SSH into the server
	@ssh -i $(SSH_KEY) molt@$(IP)

logs:                 ## Tail OpenClaw gateway logs
	@ssh -i $(SSH_KEY) molt@$(IP) "journalctl -u openclaw -f"

status:               ## Show OpenClaw service status
	@ssh -i $(SSH_KEY) molt@$(IP) "systemctl status openclaw"

## Maintenance ──────────────────────────────────

restart:              ## Restart the OpenClaw gateway
	@ssh -i $(SSH_KEY) molt@$(IP) "sudo systemctl restart openclaw"

update:               ## Update OpenClaw to latest version and restart
	@ssh -i $(SSH_KEY) molt@$(IP) "sudo npm install -g openclaw@latest && sudo systemctl restart openclaw"

tunnel:               ## Open SSH tunnel for remote gateway access (port 18789)
	@ssh -i $(SSH_KEY) -L 18789:127.0.0.1:18789 molt@$(IP)

## Help ─────────────────────────────────────────

help:                 ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[1m%-15s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
