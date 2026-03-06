#!/usr/bin/env bash
# shellcheck disable=SC2310,SC2311,SC2312
set -euo pipefail

# ================================================
# GWS SETUP — Deploy Google Workspace CLI credentials
#
# Idempotent. Runs on Mac or server. Pulls credentials
# from pass, installs gws, and links OpenClaw skills.
#
# Usage: ./scripts/gws-setup.sh
#
# Prerequisites:
#   - pass initialized with entries at:
#       shared/gws/mentolabs/credentials
#       shared/gws/mentolabs/client-secret
#   - Run 'make gws-auth-init' on Mac first to populate those entries
# ================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# lib.sh may not exist on server (script is SCP'd over); inline minimal helpers
if [[ -f "${SCRIPT_DIR}/lib.sh" ]]; then
  # shellcheck source=lib.sh
  source "${SCRIPT_DIR}/lib.sh"
else
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
  info()  { printf '%b[info]%b  %s\n' "${CYAN}"   "${NC}" "$*"; }
  ok()    { printf '%b[ok]%b    %s\n' "${GREEN}"  "${NC}" "$*"; }
  warn()  { printf '%b[warn]%b  %s\n' "${YELLOW}" "${NC}" "$*"; }
  error() { printf '%b[error]%b %s\n' "${RED}"    "${NC}" "$*" >&2; }
  step()  { printf '\n%b> %s%b\n' "${BOLD}" "$*" "${NC}"; }
  pass_entry_exists() { [[ -f "${HOME}/.password-store/${1}.gpg" ]]; }
fi

GWS_CONFIG_DIR="${HOME}/.config/gws"
PASS_CREDENTIALS="shared/gws/mentolabs/credentials"
PASS_CLIENT_SECRET="shared/gws/mentolabs/client-secret"
OPENCLAW_SKILLS_DIR="${HOME}/.openclaw/skills"
GWS_SKILLS=(drive gmail calendar sheets docs chat slides)

step "GWS setup"

# --------------------------------------------------
# Preflight: sync pass store, then check entries exist
# --------------------------------------------------

if [[ -d "${HOME}/.password-store/.git" ]]; then
  info "Syncing credential store..."
  if git -C "${HOME}/.password-store" pull --ff-only &>/dev/null; then
    ok "Credential store up to date"
  else
    warn "Could not pull credential store — continuing with local state"
  fi
fi

if ! pass_entry_exists "${PASS_CREDENTIALS}" || ! pass_entry_exists "${PASS_CLIENT_SECRET}"; then
  warn "GWS credentials not found in pass."
  warn "Run 'make gws-auth-init' on your Mac first, then re-run this script."
  exit 0
fi

# --------------------------------------------------
# Idempotency: skip if already working
# --------------------------------------------------

if command -v gws &>/dev/null \
  && [[ -f "${GWS_CONFIG_DIR}/credentials.json" ]] \
  && gws drive files list --params '{"pageSize":1}' &>/dev/null 2>&1; then
  ok "GWS already configured and working"
  exit 0
fi

# --------------------------------------------------
# Step 1: Install gws
# --------------------------------------------------

if ! command -v gws &>/dev/null; then
  step "Installing gws"
  npm install -g @googleworkspace/cli
  ok "gws installed"
else
  ok "gws already installed"
fi

# --------------------------------------------------
# Step 2: Pull credentials from pass
# --------------------------------------------------

step "Pulling credentials from pass"

mkdir -p "${GWS_CONFIG_DIR}"

# Create files with restricted permissions before writing secrets
for f in client_secret.json credentials.json; do
  touch "${GWS_CONFIG_DIR}/${f}" && chmod 600 "${GWS_CONFIG_DIR}/${f}"
done
pass show "${PASS_CLIENT_SECRET}" > "${GWS_CONFIG_DIR}/client_secret.json"
pass show "${PASS_CREDENTIALS}"   > "${GWS_CONFIG_DIR}/credentials.json"

ok "Credentials written to ${GWS_CONFIG_DIR}"

# --------------------------------------------------
# Step 3: Install OpenClaw skills (if applicable)
# --------------------------------------------------

if [[ -d "${OPENCLAW_SKILLS_DIR}" ]]; then
  step "Installing OpenClaw GWS skills"
  for skill in "${GWS_SKILLS[@]}"; do
    skill_dir="${OPENCLAW_SKILLS_DIR}/gws-${skill}"
    if [[ -d "${skill_dir}" ]]; then
      ok "Skill already installed: gws-${skill}"
    else
      info "Installing gws-${skill}..."
      if npx --yes skills add \
        "https://github.com/googleworkspace/cli/tree/main/skills/gws-${skill}" \
        --output "${OPENCLAW_SKILLS_DIR}" &>/dev/null; then
        ok "Installed gws-${skill}"
      else
        warn "Could not install gws-${skill} (check network)"
      fi
    fi
  done
else
  info "OpenClaw skills directory not found — skipping skill install"
  info "(Run 'openclaw onboard' first if you want GWS skills)"
fi

# --------------------------------------------------
# Step 4: Smoke test
# --------------------------------------------------

step "Verifying access"

if gws drive files list --params '{"pageSize": 1}' &>/dev/null 2>&1; then
  ok "Drive API access confirmed"
else
  error "Smoke test failed — credentials may be expired or APIs not enabled"
  error "Re-authenticate with: make gws-login"
  exit 1
fi

# --------------------------------------------------
# Done
# --------------------------------------------------

echo ""
printf '%b══════════════════════════════════════════════%b\n' "${GREEN}${BOLD}" "${NC}"
printf '%b  GWS SETUP COMPLETE%b\n' "${GREEN}${BOLD}" "${NC}"
printf '%b══════════════════════════════════════════════%b\n' "${GREEN}${BOLD}" "${NC}"
echo ""
info "Credentials: ${GWS_CONFIG_DIR}/credentials.json"
info "Account:     philip.paetz@mentolabs.xyz"
echo ""
info "Test:  gws drive files list --params '{\"pageSize\": 5}'"
info "Help:  gws --help"
echo ""
