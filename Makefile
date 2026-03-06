TF_DIR    := terraform
SSH_KEY   := $(TF_DIR)/id_ed25519
IP        := $(shell terraform -chdir=$(TF_DIR) output -raw server_ip 2>/dev/null)
# openclaw binary path on the server (molt user's npm-global prefix)
OPENCLAW  := /home/molt/.npm-global/bin/openclaw

.PHONY: setup destroy ssh logs stop restart update status add-bot rotate-key cred-status dashboard dashboard-setup dashboard-pair tailscale-ip tailscale-status mac-node-setup mac-node-approve mac-node-status mac-node-restart mac-node-update mac-node-token mac-gateway-status mac-gateway-restart gws-auth-init gws-setup gws-server-setup gws-login

## Setup & teardown ─────────────────────────────

setup:                ## Provision server and verify
	@./setup.sh

destroy:              ## Tear down all infrastructure
	@./destroy.sh

## Server access ────────────────────────────────

ssh:                  ## SSH into the server
	@ssh -i $(SSH_KEY) molt@$(IP)

logs:                 ## Tail OpenClaw gateway logs
	@ssh -i $(SSH_KEY) molt@$(IP) "journalctl --user -u openclaw-gateway -f -o cat" | \
	  perl -pe 'if (/\b(error|fail|fatal|exception|crash)\b/i) { s/.*/\e[31m$$&\e[0m/ } elsif (/\b(warn|restarting|blocked|stuck|timeout|limited)\b/i) { s/.*/\e[33m$$&\e[0m/ } else { s/\[([^\]]+)\]/\e[36m[$$1]\e[0m/g }'

status:               ## Show OpenClaw service status
	@ssh -i $(SSH_KEY) molt@$(IP) "systemctl --user status openclaw-gateway"

## Maintenance ──────────────────────────────────

stop:                 ## Emergency stop — kill the OpenClaw gateway immediately
	@ssh -i $(SSH_KEY) molt@$(IP) "systemctl --user stop openclaw-gateway"

restart:              ## Restart the OpenClaw gateway
	@ssh -i $(SSH_KEY) molt@$(IP) "systemctl --user restart openclaw-gateway"

update:               ## Update OpenClaw to latest version and restart
	@ssh -i $(SSH_KEY) molt@$(IP) "npm install -g openclaw@latest && systemctl --user restart openclaw-gateway"

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
	   $(OPENCLAW) config set gateway.trustedProxies '[\"127.0.0.1\"]' && \
	   $(OPENCLAW) config set gateway.controlUi.allowedOrigins '[\"https://$$host\"]' && \
	   $(OPENCLAW) config set gateway.auth.allowTailscale true && \
	   $(OPENCLAW) config set gateway.tailscale.mode serve && \
	   systemctl --user restart openclaw-gateway && \
	   sleep 3 && systemctl --user is-active openclaw-gateway" && \
	 echo "" && echo "Gateway configured. Open: https://$$host/chat?session=main" && \
	 echo "First visit? Run 'make dashboard-pair' after loading the page."

dashboard-pair:       ## Approve pending Control UI device pairing request
	@ssh -i $(SSH_KEY) molt@$(IP) "\
	  REQ=\$$(python3 -c 'import json; d=json.load(open(\"/home/molt/.openclaw/devices/pending.json\")); ids=[v[\"requestId\"] for v in d.values()]; print(ids[0] if ids else \"\")' 2>/dev/null) && \
	  if [ -n \"\$$REQ\" ]; then $(OPENCLAW) devices approve \"\$$REQ\"; else echo 'No pending pairing requests.'; fi"

## Syncthing ─────────────────────────────────

syncthing-tunnel:     ## Open SSH tunnel for Syncthing web UI (port 8384)
	@ssh -i $(SSH_KEY) -L 8384:127.0.0.1:8384 molt@$(IP)

syncthing-setup:      ## Run Syncthing setup helper on the server
	@ssh -i $(SSH_KEY) molt@$(IP) "bash ~/scripts/syncthing-setup.sh 2>/dev/null || bash /tmp/syncthing-setup.sh"

syncthing-id:         ## Print the server's Syncthing device ID
	@ssh -i $(SSH_KEY) molt@$(IP) "syncthing -device-id"

## Mac node ─────────────────────────────────────

mac-node-setup:       ## Set up this Mac as an OpenClaw node (idempotent)
	@./scripts/mac-node-setup.sh

mac-node-approve:     ## Approve pending Mac node pairing request on the server
	@ssh -i $(SSH_KEY) molt@$(IP) "\
	  REQ=\$$(python3 -c 'import json; d=json.load(open(\"/home/molt/.openclaw/devices/pending.json\")); ids=[v[\"requestId\"] for v in d.values() if v.get(\"role\") == \"node\"]; print(ids[0] if ids else \"\")' 2>/dev/null) && \
	  if [ -n \"\$$REQ\" ]; then $(OPENCLAW) devices approve \"\$$REQ\" && echo 'Node approved.'; else echo 'No pending node pairing requests.'; fi"

mac-node-status:      ## Show Mac node service status
	@openclaw node status

mac-node-restart:     ## Restart Mac node service + local gateway (relay)
	@openclaw node restart && launchctl kickstart -k gui/$$(id -u)/ai.openclaw.gateway 2>/dev/null; true

mac-gateway-status:   ## Show Mac local gateway status (browser relay)
	@launchctl list ai.openclaw.gateway 2>/dev/null | head -5

mac-gateway-restart:  ## Restart Mac local gateway (restarts relay on 18792)
	@launchctl kickstart -k gui/$$(id -u)/ai.openclaw.gateway 2>/dev/null

mac-node-update:      ## Update openclaw on Mac and reinstall node service
	@npm install -g openclaw@latest && ./scripts/mac-node-setup.sh

mac-node-token:       ## Print gateway auth token (paste into Chrome extension Options)
	@ssh -i $(SSH_KEY) molt@$(IP) "python3 -c \"import json; d=json.load(open('/home/molt/.openclaw/openclaw.json')); print(d.get('gateway',{}).get('auth',{}).get('token','(token not set)'))\""

## Google Workspace ─────────────────────────────

gws-auth-init:        ## One-time Mac setup: install gws, OAuth login, export credentials to pass
	@./scripts/gws-auth-init.sh

gws-setup:            ## Deploy GWS credentials from pass to this machine (idempotent)
	@./scripts/gws-setup.sh

gws-server-setup:     ## Deploy GWS credentials from pass to the server (idempotent)
	@scp -i $(SSH_KEY) scripts/gws-setup.sh molt@$(IP):~/
	@ssh -i $(SSH_KEY) molt@$(IP) "bash ~/gws-setup.sh && rm -f ~/gws-setup.sh"

gws-login:            ## Re-authenticate gws after token expiry
	@gws auth login -s drive,gmail,calendar,sheets,docs,people,chat,tasks,slides && \
	 ./scripts/gws-auth-init.sh --export-only

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
