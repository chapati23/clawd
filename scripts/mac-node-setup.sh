#!/usr/bin/env bash
# shellcheck disable=SC2310,SC2311,SC2312
#
# mac-node-setup.sh — Install this Mac as an OpenClaw node that connects to the
# Hetzner gateway. Allows the gateway's agents to drive your local Chrome browser
# for automations that get bot-flagged when run from the server.
#
# Run: ./scripts/mac-node-setup.sh  (or: make mac-node-setup)
# Idempotent — safe to re-run after updates or if anything breaks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

TF_DIR="${SCRIPT_DIR}/../terraform"
SSH_KEY="${TF_DIR}/id_ed25519"

# ==============================================================
# Phase 1: Prerequisites
# ==============================================================

step "Checking prerequisites"

if ! command -v node &>/dev/null; then
	error "Node.js is not installed. Install it from https://nodejs.org"
	exit 1
fi
ok "Node.js $(node --version)"

if [[ ! -f ${SSH_KEY} ]]; then
	error "SSH key not found at ${SSH_KEY}. Run ./setup.sh first."
	exit 1
fi

IP=$(terraform -chdir="${TF_DIR}" output -raw server_ip 2>/dev/null || true)
if [[ -z ${IP} ]]; then
	error "Could not get server IP from Terraform state. Run ./setup.sh first."
	exit 1
fi
ok "Server IP: ${IP}"

# ==============================================================
# Phase 2: Install openclaw if needed
# ==============================================================

step "Checking openclaw"

if ! command -v openclaw &>/dev/null; then
	info "openclaw not found — installing via npm"
	npm install -g openclaw
fi
ok "openclaw $(openclaw --version 2>/dev/null || echo 'installed')"

# ==============================================================
# Phase 3: Resolve gateway hostname
# ==============================================================

step "Resolving gateway hostname from server"

GATEWAY_HOST=$(ssh -i "${SSH_KEY}" molt@"${IP}" \
	"tailscale status --json | python3 -c \
  'import sys,json; print(json.load(sys.stdin)[\"Self\"][\"DNSName\"].rstrip(\".\"))'")

if [[ -z ${GATEWAY_HOST} ]]; then
	error "Could not resolve Tailscale hostname. Is Tailscale running on the server?"
	exit 1
fi
ok "Gateway host: ${GATEWAY_HOST}"

# ==============================================================
# Phase 3.5: Ensure gateway hostname resolves (CLI Tailscale DNS)
# ==============================================================
#
# The brew CLI Tailscale doesn't configure macOS DNS for .ts.net domains.
# If the hostname can't be resolved, add it to /etc/hosts automatically.

step "Checking DNS resolution for ${GATEWAY_HOST}"

if ! python3 -c "import socket; socket.gethostbyname('${GATEWAY_HOST}')" &>/dev/null; then
	warn "${GATEWAY_HOST} does not resolve — CLI Tailscale DNS not configured"
	TAILSCALE_IP=$(ssh -i "${SSH_KEY}" molt@"${IP}" "tailscale ip -4")
	if grep -qF "${GATEWAY_HOST}" /etc/hosts 2>/dev/null; then
		warn "Stale entry already in /etc/hosts — skipping (check manually)"
	else
		info "Adding ${TAILSCALE_IP} ${GATEWAY_HOST} to /etc/hosts (requires sudo)"
		echo "${TAILSCALE_IP} ${GATEWAY_HOST}" | sudo tee -a /etc/hosts >/dev/null
		ok "Added to /etc/hosts"
	fi
else
	ok "${GATEWAY_HOST} resolves"
fi

# ==============================================================
# Phase 4: Install node host as a background service
# ==============================================================

step "Installing node host service"

# Use the Mac's friendly name as the display name.
DISPLAY_NAME=$(scutil --get ComputerName 2>/dev/null || hostname)

# --force makes this idempotent: reinstalls cleanly if already present.
openclaw node install \
	--host "${GATEWAY_HOST}" \
	--port 443 \
	--tls \
	--display-name "${DISPLAY_NAME}" \
	--force

ok "Node host installed (display name: ${DISPLAY_NAME})"

# ==============================================================
# Phase 5: Configure and install local gateway (browser relay)
# ==============================================================
#
# The Chrome extension relay (127.0.0.1:18792) is started by the LOCAL
# gateway process, not the headless node host. We run a minimal local
# gateway in "local" mode that proxies to the Hetzner gateway and starts
# the relay as a side effect.

step "Configuring local gateway for browser relay"

# Get the Hetzner gateway token (used for both the remote connection and
# the local relay authentication).
GATEWAY_TOKEN=$(ssh -i "${SSH_KEY}" molt@"${IP}" \
	"python3 -c \"import json; print(json.load(open('/home/molt/.openclaw/openclaw.json'))['gateway']['auth']['token'])\"")

if [[ -z ${GATEWAY_TOKEN} ]]; then
	error "Could not retrieve gateway token from server."
	exit 1
fi
ok "Gateway token retrieved"

# Write local openclaw.json: mode=local + remote URL + auth token
OC_CONFIG="${HOME}/.openclaw/openclaw.json"
python3 - <<PYEOF
import json, os
path = os.path.expanduser('${OC_CONFIG}')
cfg = {}
if os.path.exists(path):
    with open(path) as f:
        cfg = json.load(f)
cfg.setdefault('gateway', {}).update({
    'mode': 'local',
    'auth': {'mode': 'token', 'token': '${GATEWAY_TOKEN}'},
    'remote': {'url': 'wss://${GATEWAY_HOST}', 'token': '${GATEWAY_TOKEN}'},
})
with open(path, 'w') as f:
    json.dump(cfg, f, indent=2)
print('Local openclaw.json configured')
PYEOF

ok "Local openclaw.json configured"

# Install the local gateway as a launchd service.
NODE_BIN=$(command -v node)
OC_SCRIPT=$(python3 -c "
import subprocess, json
result = subprocess.run(['npm', 'root', '-g'], capture_output=True, text=True)
print(result.stdout.strip() + '/openclaw/dist/index.js')
" 2>/dev/null || echo "")

if [[ -z ${OC_SCRIPT} ]] || [[ ! -f ${OC_SCRIPT} ]]; then
	# Fallback: resolve via node require
	OC_SCRIPT=$(node -e "console.log(require.resolve('openclaw/dist/index.js'))" 2>/dev/null || true)
fi
if [[ -z ${OC_SCRIPT} ]] || [[ ! -f ${OC_SCRIPT} ]]; then
	OC_SCRIPT=$(find "$(dirname "${NODE_BIN}")" -name "index.js" -path "*/openclaw/dist/*" 2>/dev/null | head -1 || true)
fi

GW_PLIST="${HOME}/Library/LaunchAgents/ai.openclaw.gateway.plist"
cat >"${GW_PLIST}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>ai.openclaw.gateway</string>
    <key>Comment</key>
    <string>OpenClaw Local Gateway (browser relay for Chrome extension)</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>ProgramArguments</key>
    <array>
      <string>${NODE_BIN}</string>
      <string>$(openclaw browser extension path 2>/dev/null | xargs dirname)/../../dist/index.js</string>
      <string>gateway</string>
    </array>
    <key>StandardOutPath</key>
    <string>${HOME}/.openclaw/logs/gateway-local.log</string>
    <key>StandardErrorPath</key>
    <string>${HOME}/.openclaw/logs/gateway-local.err.log</string>
    <key>EnvironmentVariables</key>
    <dict>
      <key>HOME</key>
      <string>${HOME}</string>
      <key>PATH</key>
      <string>$(dirname "${NODE_BIN}"):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
      <key>OPENCLAW_GATEWAY_TOKEN</key>
      <string>${GATEWAY_TOKEN}</string>
    </dict>
  </dict>
</plist>
PLIST

launchctl unload "${GW_PLIST}" 2>/dev/null || true
launchctl load "${GW_PLIST}"
sleep 3

if lsof -iTCP:18792 -sTCP:LISTEN &>/dev/null 2>&1; then
	ok "Local gateway installed, relay listening on 127.0.0.1:18792"
else
	warn "Local gateway installed but relay not yet visible — may take a few seconds"
fi

# ==============================================================
# Phase 6: Install Chrome extension relay
# ==============================================================

step "Installing Chrome extension"

openclaw browser extension install
EXTENSION_PATH=$(openclaw browser extension path)
ok "Extension files at: ${EXTENSION_PATH}"

# ==============================================================
# Done — print next steps
# ==============================================================

echo ""
info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
info "Node host installed. Complete the setup with these one-time steps:"
info ""
info "  1. Approve this Mac on the server (run once after first connect):"
info "       make mac-node-approve"
info ""
info "  2. Load the Chrome extension (run once in Chrome):"
info "       a) Open chrome://extensions"
info "       b) Enable Developer mode (top-right toggle)"
info "       c) Click 'Load unpacked' → select:"
info "            ${EXTENSION_PATH}"
info "       d) Pin the extension to your toolbar"
info ""
info "  3. Configure the extension (open its Options page):"
info "       Gateway token: run 'make mac-node-token' to get it"
info "       Port:          18792 (default — relay is now listening there)"
info ""
info "  4. Attach a Chrome tab:"
info "       Open the tab you want the agent to drive, then click"
info "       the OpenClaw toolbar icon. Badge shows ON when ready."
info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
