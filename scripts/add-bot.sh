#!/usr/bin/env bash
# shellcheck disable=SC2310,SC2311,SC2312
set -euo pipefail

# ================================================
# ADD BOT — Create per-bot GPG key and credential scope
#
# Usage: ./scripts/add-bot.sh <bot-name> [shared-access: yes/no]
# Example: ./scripts/add-bot.sh giskard yes
#
# Run on your MacBook. Called by setup.sh for the
# first bot, or standalone for additional bots.
# ================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

BOT_NAME="${1:?Usage: ./scripts/add-bot.sh <bot-name> [shared-access: yes/no]}"
SHARED_ACCESS="${2:-yes}"
GPG_EMAIL="${GPG_EMAIL:-}"

# --------------------------------------------------
# Resolve master key
# --------------------------------------------------

step "Creating bot: ${BOT_NAME}"

if [[ -z "${GPG_EMAIL}" ]]; then
  # Try to read the master key email from the pass store's .gpg-id
  if pass_initialized; then
    MASTER_KEY_ID=$(head -1 "${HOME}/.password-store/.gpg-id")
    GPG_EMAIL=$(gpg --list-keys --keyid-format long "${MASTER_KEY_ID}" 2>/dev/null \
      | awk -F'[<>]' '/uid/ { print $2; exit }')
  fi
fi

if [[ -z "${GPG_EMAIL}" ]]; then
  error "Cannot determine master GPG key. Set GPG_EMAIL or run credentials-init.sh first."
  exit 1
fi

MASTER_KEY_ID=$(gpg_key_id "${GPG_EMAIL}")
if [[ -z "${MASTER_KEY_ID}" ]]; then
  error "Master GPG key not found for: ${GPG_EMAIL}"
  error "Run ./scripts/credentials-init.sh first."
  exit 1
fi
ok "Master key: ${MASTER_KEY_ID} (${GPG_EMAIL})"

BOT_EMAIL="bot-${BOT_NAME}@openclaw.local"

# --------------------------------------------------
# 1. Generate bot GPG key (no passphrase — automation)
# --------------------------------------------------

if gpg_key_exists "${BOT_EMAIL}"; then
  BOT_KEY_ID=$(gpg_key_id "${BOT_EMAIL}")
  ok "Bot GPG key already exists: ${BOT_KEY_ID}"
else
  info "Generating bot GPG key (RSA-4096, 2yr expiry, no passphrase)..."
  BATCH_FILE="$(mktemp)"
  cat > "${BATCH_FILE}" <<EOF
Key-Type: RSA
Key-Length: 4096
Subkey-Type: RSA
Subkey-Length: 4096
Name-Real: bot-${BOT_NAME}
Name-Email: ${BOT_EMAIL}
Expire-Date: 2y
%no-protection
%commit
EOF
  gpg --batch --gen-key "${BATCH_FILE}"
  rm -f "${BATCH_FILE}"

  BOT_KEY_ID=$(gpg_key_id "${BOT_EMAIL}")
  ok "Bot GPG key created: ${BOT_KEY_ID}"
fi

BOT_KEY_ID=$(gpg_key_id "${BOT_EMAIL}")

# --------------------------------------------------
# 2. Scope bot directory in pass (bot key + master key)
# --------------------------------------------------

BOT_DIR="${HOME}/.password-store/bot-${BOT_NAME}"
if [[ -d "${BOT_DIR}" ]]; then
  ok "Bot directory already exists: bot-${BOT_NAME}/"
else
  mkdir -p "${BOT_DIR}"
  pass init -p "bot-${BOT_NAME}/" "${BOT_KEY_ID}" "${MASTER_KEY_ID}"
  ok "Bot directory created and scoped: bot-${BOT_NAME}/"
fi

# --------------------------------------------------
# 3. Add bot to shared/ recipients (if requested)
# --------------------------------------------------

if [[ "${SHARED_ACCESS}" == "yes" ]]; then
  SHARED_GPG_ID="${HOME}/.password-store/shared/.gpg-id"
  if [[ -f "${SHARED_GPG_ID}" ]] && grep -q "${BOT_KEY_ID}" "${SHARED_GPG_ID}"; then
    ok "Bot already in shared/ recipients"
  else
    CURRENT_SHARED=""
    if [[ -f "${SHARED_GPG_ID}" ]]; then
      CURRENT_SHARED=$(cat "${SHARED_GPG_ID}")
    else
      CURRENT_SHARED="${MASTER_KEY_ID}"
    fi
    # shellcheck disable=SC2086
    pass init -p shared/ ${CURRENT_SHARED} "${BOT_KEY_ID}"
    ok "Bot added to shared/ recipients"
  fi
fi

# --------------------------------------------------
# 4. Export bot key bundle (age-encrypted)
# --------------------------------------------------

AGE_KEY_FILE="${HOME}/.age-recovery-key.txt"
if [[ ! -f "${AGE_KEY_FILE}" ]]; then
  error "Age recovery key not found: ${AGE_KEY_FILE}"
  error "Run ./scripts/credentials-init.sh first."
  exit 1
fi

AGE_PUB=$(grep "public key:" "${AGE_KEY_FILE}" | awk '{print $NF}')
BOT_KEY_AGE="${HOME}/bot-${BOT_NAME}-key.age"

if [[ -f "${BOT_KEY_AGE}" ]]; then
  ok "Bot key bundle already exists: ${BOT_KEY_AGE}"
else
  info "Creating age-encrypted bot key bundle..."
  TMPDIR_SECURE=$(mktemp -d)
  gpg --export-secret-keys --armor "${BOT_KEY_ID}" > "${TMPDIR_SECURE}/bot-key.asc"
  gpg --export --armor "${MASTER_KEY_ID}" > "${TMPDIR_SECURE}/master-pub.asc"
  cat "${TMPDIR_SECURE}/bot-key.asc" "${TMPDIR_SECURE}/master-pub.asc" \
    | age -r "${AGE_PUB}" -o "${BOT_KEY_AGE}"
  rm -rf "${TMPDIR_SECURE}"

  shasum -a 256 "${BOT_KEY_AGE}" > "${BOT_KEY_AGE}.sha256"
  ok "Bot key bundle: ${BOT_KEY_AGE}"
fi

# --------------------------------------------------
# 5. Generate SSH deploy key (read-only repo access)
# --------------------------------------------------

DEPLOY_KEY="${HOME}/bot-${BOT_NAME}-deploy-key"
if [[ -f "${DEPLOY_KEY}" ]]; then
  ok "Deploy key already exists: ${DEPLOY_KEY}"
else
  info "Generating SSH deploy key..."
  ssh-keygen -t ed25519 -C "bot-${BOT_NAME}-deploy" -f "${DEPLOY_KEY}" -N ""
  ok "Deploy key: ${DEPLOY_KEY}"
fi

# --------------------------------------------------
# 6. Add deploy key to GitHub (if gh available)
# --------------------------------------------------

if command -v gh &>/dev/null; then
  # Determine repo from pass remote
  PASS_REMOTE=$(git -C "${HOME}/.password-store" remote get-url origin 2>/dev/null || true)
  # Extract owner/repo from git@github.com:owner/repo.git or https://github.com/owner/repo.git
  GH_REPO=$(echo "${PASS_REMOTE}" | sed -E 's|.*github\.com[:/]||; s|\.git$||')

  if [[ -n "${GH_REPO}" ]]; then
    # Check if deploy key already added
    EXISTING_KEYS=$(gh repo deploy-key list --repo "${GH_REPO}" 2>/dev/null || true)

    if echo "${EXISTING_KEYS}" | grep -q "bot-${BOT_NAME}-deploy"; then
      ok "Deploy key already added to GitHub"
    else
      info "Adding deploy key to GitHub repo: ${GH_REPO}"
      gh repo deploy-key add "${DEPLOY_KEY}.pub" \
        --repo "${GH_REPO}" \
        --title "bot-${BOT_NAME}-deploy"
      ok "Deploy key added to GitHub (read-only)"
    fi
  else
    warn "Could not determine GitHub repo from pass remote."
    warn "Add the deploy key manually:"
    echo "  cat ${DEPLOY_KEY}.pub"
    echo "  -> GitHub repo -> Settings -> Deploy keys -> Add (read-only)"
  fi
else
  warn "GitHub CLI not available. Add the deploy key manually:"
  echo ""
  echo "  Public key:"
  cat "${DEPLOY_KEY}.pub"
  echo ""
  echo "  -> GitHub repo -> Settings -> Deploy keys -> Add (read-only)"
  echo ""
  pause "Press Enter after adding the deploy key to GitHub..."
fi

# --------------------------------------------------
# 7. Push changes to credential store
# --------------------------------------------------

cd "${HOME}/.password-store"
git add -A
if ! git diff --cached --quiet 2>/dev/null; then
  git commit -m "Add bot-${BOT_NAME}"
  info "Pushing to GitHub..."
  if ! git push 2>&1; then
    warn "Could not push to GitHub. Push manually:"
    warn "  cd ~/.password-store && git push"
  fi
fi

# --------------------------------------------------
# Done
# --------------------------------------------------

echo ""
printf '%b═══════════════════════════════════════════════%b\n' "${GREEN}${BOLD}" "${NC}"
printf '%b  BOT %s CREATED%b\n' "${GREEN}${BOLD}" "${BOT_NAME}" "${NC}"
printf '%b═══════════════════════════════════════════════%b\n' "${GREEN}${BOLD}" "${NC}"
echo ""
info "Bot GPG key:  ${BOT_KEY_ID}"
info "Key bundle:   ${BOT_KEY_AGE}"
info "Deploy key:   ${DEPLOY_KEY}"
echo ""
info "Deploy materials for server setup:"
echo "  ${BOT_KEY_AGE}"
echo "  ${DEPLOY_KEY}"
echo "  ${AGE_KEY_FILE}"
echo ""
