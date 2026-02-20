#!/usr/bin/env bash
# shellcheck disable=SC2310,SC2311,SC2312
set -euo pipefail

# ================================================
# GCP SETUP — Create a read-only service account for an agent
#
# Creates a GCP service account with minimal permissions
# (Cloud Run Viewer + Logs Viewer) and activates it on the
# current machine. Designed for agents that need to read
# logs and service status but never modify infrastructure.
#
# Usage: ./scripts/gcp-setup.sh <gcp-project-id> <bot-name>
#
# Prerequisites:
#   - gcloud CLI installed (added by cloud-init)
#   - An authenticated gcloud session with IAM Admin permissions
#     (run: gcloud auth login --no-launch-browser)
#   - The bot's pass store (for key storage)
#
# What it does:
#   1. Creates SA: <bot-name>-readonly@<project>.iam.gserviceaccount.com
#   2. Grants roles: run.viewer, logging.viewer
#   3. Creates JSON key → stores in pass
#   4. Activates SA on the machine
#
# The SA key is stored in pass at:
#   bot-<bot-name>/gcp/<project-id>/sa-key
# ================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

PROJECT_ID="${1:?Usage: ./scripts/gcp-setup.sh <gcp-project-id> <bot-name>}"
BOT_NAME="${2:?Usage: ./scripts/gcp-setup.sh <gcp-project-id> <bot-name>}"

SA_NAME="${BOT_NAME}-readonly"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
PASS_PATH="bot-${BOT_NAME}/gcp/${PROJECT_ID}/sa-key"

TMPKEY=""
cleanup() { [[ -n "${TMPKEY}" ]] && rm -f "${TMPKEY}"; }
trap cleanup EXIT

# --------------------------------------------------
# Preflight
# --------------------------------------------------

step "Setting up GCP read-only access for ${BOT_NAME}"

if ! command -v gcloud &>/dev/null; then
  error "gcloud CLI not installed."
  error "If this is a clawd-provisioned server, re-run setup or install manually:"
  error "  https://cloud.google.com/sdk/docs/install"
  exit 1
fi

# Check if already set up
if pass_entry_exists "${PASS_PATH}"; then
  info "Service account key already in pass at ${PASS_PATH}"
  if gcloud auth list --format="value(account)" --filter="status:ACTIVE" 2>/dev/null | grep -qF "${SA_EMAIL}"; then
    ok "Already authenticated as ${SA_EMAIL}"
    exit 0
  else
    info "Key exists but not activated — re-activating..."
    TMPKEY="$(mktemp)"
    pass show "${PASS_PATH}" > "${TMPKEY}"
    gcloud auth activate-service-account --key-file="${TMPKEY}" --project="${PROJECT_ID}"
    gcloud config set project "${PROJECT_ID}"
    ok "Authenticated as ${SA_EMAIL}"
    exit 0
  fi
fi

# Need an authenticated admin session to create the SA
if ! gcloud auth list --format="value(account)" --filter="status:ACTIVE" 2>/dev/null | grep -q .; then
  error "No active gcloud auth session."
  error "Ask the project owner to run this script from their machine,"
  error "or authenticate with: gcloud auth login --no-launch-browser"
  exit 1
fi

# --------------------------------------------------
# 1. Create service account
# --------------------------------------------------

step "Creating service account: ${SA_NAME}"

if gcloud iam service-accounts describe "${SA_EMAIL}" --project="${PROJECT_ID}" &>/dev/null; then
  ok "Service account already exists: ${SA_EMAIL}"
else
  gcloud iam service-accounts create "${SA_NAME}" \
    --project="${PROJECT_ID}" \
    --display-name="${BOT_NAME} Read-Only Agent" \
    --description="Read-only access for ${BOT_NAME} agent (logs, Cloud Run status)"
  ok "Created ${SA_EMAIL}"
fi

# --------------------------------------------------
# 2. Grant minimal roles
# --------------------------------------------------

step "Granting read-only roles"

ROLES=(
  "roles/run.viewer"       # View Cloud Run services, revisions, logs
  "roles/logging.viewer"   # View Cloud Logging entries
)

for role in "${ROLES[@]}"; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="${role}" \
    --condition=None \
    --quiet &>/dev/null
  ok "Granted ${role}"
done

# --------------------------------------------------
# 3. Create and store key
# --------------------------------------------------

step "Creating service account key"

TMPKEY="$(mktemp)"

gcloud iam service-accounts keys create "${TMPKEY}" \
  --iam-account="${SA_EMAIL}" \
  --project="${PROJECT_ID}"

# Store in pass
if pass_initialized; then
  pass insert -m -f "${PASS_PATH}" < "${TMPKEY}" &>/dev/null
  ok "Key stored in pass: ${PASS_PATH}"
  if git -C "${HOME}/.password-store" push &>/dev/null; then
    ok "Pushed to credentials repo"
  else
    warn "Could not push to credentials repo — run: cd ~/.password-store && git push"
  fi
else
  warn "pass not initialized — saving key to ~/.config/gcloud/${PROJECT_ID}-sa-key.json"
  mkdir -p ~/.config/gcloud
  cp "${TMPKEY}" ~/.config/gcloud/"${PROJECT_ID}-sa-key.json"
  chmod 600 ~/.config/gcloud/"${PROJECT_ID}-sa-key.json"
  ok "Key saved to ~/.config/gcloud/${PROJECT_ID}-sa-key.json"
fi

# --------------------------------------------------
# 4. Activate on this machine
# --------------------------------------------------

step "Activating service account"

gcloud auth activate-service-account --key-file="${TMPKEY}" --project="${PROJECT_ID}"
gcloud config set project "${PROJECT_ID}"

# --------------------------------------------------
# Done
# --------------------------------------------------

echo ""
printf '%b═══════════════════════════════════════════════%b\n' "${GREEN}${BOLD}" "${NC}"
printf '%b  GCP READ-ONLY ACCESS CONFIGURED%b\n' "${GREEN}${BOLD}" "${NC}"
printf '%b═══════════════════════════════════════════════%b\n' "${GREEN}${BOLD}" "${NC}"
echo ""
info "Service account: ${SA_EMAIL}"
info "Roles: ${ROLES[*]}"
info "Key stored in: pass ${PASS_PATH}"
echo ""
info "Test with:"
echo "  gcloud run services list --project=${PROJECT_ID}"
echo "  gcloud run services logs read morning-briefing --project=${PROJECT_ID} --region=europe-west1 --limit=10"
echo ""
