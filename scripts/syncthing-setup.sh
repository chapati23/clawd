#!/usr/bin/env bash
# Post-provisioning helper: configure Syncthing shared folder and print pairing info.
# Run this on the server after cloud-init completes.
set -euo pipefail

# Inline logging helpers (this script runs on the server, can't source lib.sh)
info() { printf '\033[0;36m[info]\033[0m  %s\n' "$*"; }
ok() { printf '\033[0;32m[ok]\033[0m    %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m  %s\n' "$*"; }
error() { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }
step() { printf '\n\033[1m> %s\033[0m\n' "$*"; }

WORKSPACE="${HOME}/.openclaw/workspace"
SYNCTHING_CONFIG="${HOME}/.local/state/syncthing/config.xml"

# ──────────────────────────────────────────────
# Wait for Syncthing to generate its config
# ──────────────────────────────────────────────

step "Checking Syncthing status"

if ! systemctl --user is-active syncthing.service &>/dev/null; then
  info "Starting Syncthing..."
  systemctl --user start syncthing.service
  sleep 3
fi

# Wait for config file to appear (Syncthing generates it on first run)
attempts=0
while [[ ! -f "${SYNCTHING_CONFIG}" ]]; do
  sleep 2
  attempts=$((attempts + 1))
  if [[ ${attempts} -ge 15 ]]; then
    error "Syncthing config not found after 30s. Check: systemctl --user status syncthing"
    exit 1
  fi
done
ok "Syncthing is running"

# ──────────────────────────────────────────────
# Extract device ID
# ──────────────────────────────────────────────

step "Server device info"

DEVICE_ID=$(syncthing -device-id 2>/dev/null || syncthing cli show system 2>/dev/null | grep -oP '"myID"\s*:\s*"\K[^"]+' || echo "unknown")

if [[ "${DEVICE_ID}" == "unknown" ]]; then
  warn "Could not determine device ID automatically."
  info "Try: syncthing -device-id"
else
  ok "Device ID: ${DEVICE_ID}"
fi

# ──────────────────────────────────────────────
# Configure shared folder (if not already done)
# ──────────────────────────────────────────────

step "Checking workspace folder configuration"

if grep -q "${WORKSPACE}" "${SYNCTHING_CONFIG}" 2>/dev/null; then
  ok "Workspace folder already configured in Syncthing"
else
  info "Workspace folder not yet shared in Syncthing."
  info "Use the web UI to add it (see instructions below)."
fi

# ──────────────────────────────────────────────
# Print pairing instructions
# ──────────────────────────────────────────────

step "Pairing instructions"

SERVER_IP=$(curl -4 -sf ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

cat <<EOF

  ┌─────────────────────────────────────────────────────────┐
  │  Syncthing Pairing Guide                                │
  ├─────────────────────────────────────────────────────────┤
  │                                                         │
  │  Server Device ID:                                      │
  │  ${DEVICE_ID}
  │                                                         │
  │  1. Access the Syncthing web UI via SSH tunnel:         │
  │                                                         │
  │     ssh -i terraform/id_ed25519 \\                       │
  │       -L 8384:127.0.0.1:8384 molt@${SERVER_IP}
  │                                                         │
  │     Then open: http://127.0.0.1:8384                    │
  │                                                         │
  │  2. On your device (Mac/phone), install Syncthing       │
  │     and add this server as a remote device using        │
  │     the Device ID above.                                │
  │                                                         │
  │  3. Share the workspace folder:                         │
  │     Path: ${WORKSPACE}
  │     Folder ID: openclaw-workspace                       │
  │                                                         │
  │  4. Accept the share on your device and point it        │
  │     to your local Obsidian vault directory.             │
  │                                                         │
  └─────────────────────────────────────────────────────────┘

EOF

ok "Setup complete. Pair your devices using the info above."
