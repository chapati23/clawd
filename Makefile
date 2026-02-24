TF_DIR  := terraform
SSH_KEY := $(TF_DIR)/id_ed25519
IP      := $(shell terraform -chdir=$(TF_DIR) output -raw server_ip 2>/dev/null)

.PHONY: setup destroy ssh logs stop restart update status add-bot rotate-key cred-status dashboard dashboard-setup dashboard-pair tailscale-ip tailscale-status

## Setup & teardown ─────────────────────────────

setup:                ## Provision server and verify
	@./setup.sh

destroy:              ## Tear down all infrastructure
	@./destroy.sh

## Server access ────────────────────────────────

ssh:                  ## SSH into the server
	@ssh -i $(SSH_KEY) molt@$(IP)

logs:                 ## Tail OpenClaw gateway logs
	@ssh -i $(SSH_KEY) molt@$(IP) "journalctl --user -u openclaw-gateway -f"

status:               ## Show OpenClaw service status
	@ssh -i $(SSH_KEY) molt@$(IP) "systemctl --user status openclaw-gateway"

## Maintenance ──────────────────────────────────

stop:                 ## Emergency stop — kill the OpenClaw gateway immediately
	@ssh -i $(SSH_KEY) molt@$(IP) "systemctl --user stop openclaw-gateway"

restart:              ## Restart the OpenClaw gateway
	@ssh -i $(SSH_KEY) molt@$(IP) "systemctl --user restart openclaw-gateway"

update:               ## Update OpenClaw to latest version and restart
	@ssh -i $(SSH_KEY) molt@$(IP) "sudo npm install -g openclaw@latest && systemctl --user restart openclaw-gateway"

tunnel:               ## Open SSH tunnel for remote gateway access (port 18789)
	@ssh -i $(SSH_KEY) -L 18789:127.0.0.1:18789 molt@$(IP)

## Tailscale ────────────────────────────────────

tailscale-ip:         ## Print the server's Tailscale IP
	@ssh -i $(SSH_KEY) molt@$(IP) "tailscale ip -4"

tailscale-status:     ## Show Tailscale connection status
	@ssh -i $(SSH_KEY) molt@$(IP) "tailscale status"

dashboard:            ## Open OpenClaw dashboard in browser (via Tailscale)
	@host=$$(ssh -i $(SSH_KEY) molt@$(IP) "tailscale status --json | python3 -c 'import sys,json; print(json.load(sys.stdin)[\"Self\"][\"DNSName\"].rstrip(\".\"))'") && \
	 open "https://$$host/chat?session=main"

dashboard-setup:      ## Configure gateway for Tailscale dashboard access (run once after openclaw onboard)
	@host=$$(ssh -i $(SSH_KEY) molt@$(IP) "tailscale status --json | python3 -c 'import sys,json; print(json.load(sys.stdin)[\"Self\"][\"DNSName\"].rstrip(\".\"))'") && \
	 ssh -i $(SSH_KEY) molt@$(IP) "\
	   openclaw config set gateway.trustedProxies '[\"127.0.0.1\"]' && \
	   openclaw config set gateway.controlUi.allowedOrigins '[\"https://$$host\"]' && \
	   openclaw config set gateway.auth.allowTailscale true && \
	   openclaw config set gateway.tailscale.mode serve && \
	   systemctl --user restart openclaw-gateway && \
	   sleep 3 && systemctl --user is-active openclaw-gateway" && \
	 echo "" && echo "Gateway configured. Open: https://$$host/chat?session=main" && \
	 echo "First visit? Run 'make dashboard-pair' after loading the page."

dashboard-pair:       ## Approve pending Control UI device pairing request
	@ssh -i $(SSH_KEY) molt@$(IP) "\
	  REQ=\$$(python3 -c 'import json; d=json.load(open(\"/home/molt/.openclaw/devices/pending.json\")); ids=[v[\"requestId\"] for v in d.values()]; print(ids[0] if ids else \"\")' 2>/dev/null) && \
	  if [ -n \"\$$REQ\" ]; then openclaw devices approve \"\$$REQ\"; else echo 'No pending pairing requests.'; fi"

## Syncthing ─────────────────────────────────

syncthing-tunnel:     ## Open SSH tunnel for Syncthing web UI (port 8384)
	@ssh -i $(SSH_KEY) -L 8384:127.0.0.1:8384 molt@$(IP)

syncthing-setup:      ## Run Syncthing setup helper on the server
	@ssh -i $(SSH_KEY) molt@$(IP) "bash ~/scripts/syncthing-setup.sh 2>/dev/null || bash /tmp/syncthing-setup.sh"

syncthing-id:         ## Print the server's Syncthing device ID
	@ssh -i $(SSH_KEY) molt@$(IP) "syncthing -device-id"

## Credential management ───────────────────────

add-bot:              ## Add a new bot (usage: make add-bot NAME=mybot)
	@./scripts/add-bot.sh $(NAME) yes

rotate-key:           ## Rotate a GPG key (usage: make rotate-key TARGET=master)
	@./scripts/credentials-rotate.sh $(TARGET)

cred-status:          ## Show credential store status on server
	@ssh -i $(SSH_KEY) molt@$(IP) "echo 'Entries:' && find ~/.password-store -name '*.gpg' 2>/dev/null | wc -l && echo 'Last git log:' && git -C ~/.password-store log --oneline -3 2>/dev/null || echo 'No credential store found'"

## Help ─────────────────────────────────────────

help:                 ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[1m%-15s\033[0m %s\n", $$1, $$2}'

.DEFAULT_GOAL := help
