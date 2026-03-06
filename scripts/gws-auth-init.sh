#!/usr/bin/env bash
# shellcheck disable=SC2310,SC2311,SC2312
set -euo pipefail

# ================================================
# GWS AUTH INIT — One-time Mac setup for Google Workspace CLI
#
# Installs gws, authenticates as philip.paetz@mentolabs.xyz,
# then exports credentials into pass for server deployment.
#
# Usage:
#   ./scripts/gws-auth-init.sh               # full flow
#   ./scripts/gws-auth-init.sh --export-only # skip install+login, just re-export
#
# Prerequisites:
#   - Run on macOS (requires browser for OAuth)
#   - ~/.config/gws/client_secret.json must exist:
#       1. https://console.cloud.google.com/apis/credentials/consent?project=giskard-bot
#          → User type: Internal → Save
#       2. https://console.cloud.google.com/apis/credentials?project=giskard-bot
#          → + Create Credentials → OAuth client ID → Desktop app → Download JSON
#          → Save to ~/.config/gws/client_secret.json
#   - pass initialized and push access to credential repo
# ================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

EXPORT_ONLY=false
if [[ "${1:-}" == "--export-only" ]]; then
  EXPORT_ONLY=true
fi

GCP_PROJECT="giskard-bot"
GWS_CONFIG_DIR="${HOME}/.config/gws"
CLIENT_SECRET_FILE="${GWS_CONFIG_DIR}/client_secret.json"
SCOPES="drive,gmail,calendar,sheets,docs,people,chat,tasks,slides"

PASS_CREDENTIALS="shared/gws/mentolabs/credentials"
PASS_CLIENT_SECRET="shared/gws/mentolabs/client-secret"

# --------------------------------------------------
# Preflight: macOS only
# --------------------------------------------------

if ! is_macos; then
  error "This script must be run on macOS (OAuth requires a browser)."
  error "To deploy credentials to a server, run: make gws-setup"
  exit 1
fi

step "GWS auth init (mentolabs)"

# --------------------------------------------------
# Step 1: Install gws
# --------------------------------------------------

if ! ${EXPORT_ONLY}; then
  if ! command -v gws &>/dev/null; then
    step "Installing gws"
    npm install -g @googleworkspace/cli
    ok "gws installed"
  else
    ok "gws already installed"
  fi
fi

# --------------------------------------------------
# Step 2: Enable required APIs via gcloud
# --------------------------------------------------

if ! ${EXPORT_ONLY}; then
  if ! command -v gcloud &>/dev/null; then
    warn "gcloud CLI not found — skipping API enablement (install from https://cloud.google.com/sdk/docs/install)"
  else
    step "Enabling required Google APIs in ${GCP_PROJECT}"
    APIS=(
      drive.googleapis.com
      gmail.googleapis.com
      calendar-json.googleapis.com
      sheets.googleapis.com
      docs.googleapis.com
      people.googleapis.com
      chat.googleapis.com
      tasks.googleapis.com
      slides.googleapis.com
    )
    gcloud services enable "${APIS[@]}" --project="${GCP_PROJECT}" --quiet
    ok "All APIs enabled in ${GCP_PROJECT}"

    # Set ADC quota project to giskard-bot so gws sends x-goog-user-project: giskard-bot
    # on every request (gws reads quota_project_id from ~/.config/gcloud/application_default_credentials.json)
    if gcloud auth application-default set-quota-project "${GCP_PROJECT}" --quiet 2>/dev/null; then
      ok "ADC quota project set to ${GCP_PROJECT}"
    else
      warn "Could not set ADC quota project — run: gcloud auth application-default set-quota-project ${GCP_PROJECT}"
    fi
  fi
fi

# --------------------------------------------------
# Step 3: Check client_secret.json exists
# --------------------------------------------------

if ! ${EXPORT_ONLY}; then
  if [[ ! -f "${CLIENT_SECRET_FILE}" ]]; then
    error "OAuth client secret not found at: ${CLIENT_SECRET_FILE}"
    echo ""
    echo "  Complete the one-time GCP Console setup (2 steps):"
    echo ""
    echo "  1. Configure consent screen (one-time, ~10 seconds):"
    echo "     https://console.cloud.google.com/apis/credentials/consent?project=giskard-bot"
    echo "     → User type: Internal → Save"
    echo ""
    echo "  2. Create OAuth client and download JSON:"
    echo "     https://console.cloud.google.com/apis/credentials?project=giskard-bot"
    echo "     → + Create Credentials → OAuth client ID → Desktop app → Download JSON"
    echo "     → Save the file to: ${CLIENT_SECRET_FILE}"
    echo ""
    echo "  Then re-run: make gws-auth-init"
    echo ""
    exit 1
  fi
  ok "client_secret.json found"
fi

# --------------------------------------------------
# Step 4: OAuth login
# --------------------------------------------------

if ! ${EXPORT_ONLY}; then
  step "Authenticating as philip.paetz@mentolabs.xyz"
  info "Scopes: ${SCOPES}"
  info "Select only the *.readonly variant for each scope in the consent picker."
  echo ""
  gws auth login -s "${SCOPES}"
  ok "Authentication complete"
fi

# --------------------------------------------------
# Step 5: Export credentials to pass
# --------------------------------------------------

step "Exporting credentials to pass"

if ! pass_initialized; then
  error "pass is not initialized. Run ./scripts/credentials-init.sh first."
  exit 1
fi

# Export OAuth token (includes refresh token)
info "Exporting token..."
gws auth export --unmasked | pass insert -m -f "${PASS_CREDENTIALS}" >/dev/null
ok "Stored: ${PASS_CREDENTIALS}"

# Store client secret (needed for token refresh)
info "Storing client secret..."
pass insert -m -f "${PASS_CLIENT_SECRET}" < "${CLIENT_SECRET_FILE}" >/dev/null
ok "Stored: ${PASS_CLIENT_SECRET}"

# Commit any uncommitted changes, then push (pass insert auto-commits but does not push)
info "Pushing to credential repo..."
git -C "${HOME}/.password-store" add -A &>/dev/null || true
if ! git -C "${HOME}/.password-store" diff --cached --quiet 2>/dev/null; then
  git -C "${HOME}/.password-store" commit -m "GWS credentials (mentolabs)" &>/dev/null || true
fi
if git -C "${HOME}/.password-store" push &>/dev/null; then
  ok "Pushed to credential repo"
else
  warn "Push failed — run: cd ~/.password-store && git push"
fi

# --------------------------------------------------
# Step 6: Smoke test
# --------------------------------------------------

step "Verifying access"

if gws drive files list --params '{"pageSize": 1}' &>/dev/null; then
  ok "Drive API access confirmed"
else
  error "Smoke test failed — check that Drive API is enabled in giskard-bot project"
  error "Enable at: https://console.cloud.google.com/apis/library/drive.googleapis.com?project=giskard-bot"
  exit 1
fi

# --------------------------------------------------
# Done
# --------------------------------------------------

echo ""
printf '%b══════════════════════════════════════════════%b\n' "${GREEN}${BOLD}" "${NC}"
printf '%b  GWS CREDENTIALS READY%b\n' "${GREEN}${BOLD}" "${NC}"
printf '%b══════════════════════════════════════════════%b\n' "${GREEN}${BOLD}" "${NC}"
echo ""
info "Account:    philip.paetz@mentolabs.xyz"
info "Scopes:     ${SCOPES}"
info "pass:       ${PASS_CREDENTIALS}"
echo ""
info "Deploy to server:  make gws-setup"
info "Re-auth later:     make gws-login"
echo ""
