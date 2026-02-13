#!/usr/bin/env bash
# shellcheck disable=SC2310,SC2311,SC2312
set -euo pipefail

# ================================================
# CREDENTIAL INFRASTRUCTURE — One-time bootstrap
#
# Sets up: master GPG key, pass store, age recovery,
# GitHub credentials repo, and initial token storage.
#
# Run once on your MacBook. Called by setup.sh on
# first run, or standalone: ./scripts/credentials-init.sh
# ================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

GPG_EMAIL="${GPG_EMAIL:-}"
GPG_NAME="${GPG_NAME:-}"
PASS_REPO="${PASS_REPO:-}"

step "Setting up credential infrastructure (one-time)"

# --------------------------------------------------
# 1. Install dependencies
# --------------------------------------------------

info "Checking credential management dependencies..."

if ! is_macos; then
  error "Credential infrastructure setup is designed for macOS."
  error "Run this on your MacBook, not on a server."
  exit 1
fi

if ! command -v brew &>/dev/null; then
  error "Homebrew not found. Install from https://brew.sh"
  exit 1
fi

DEPS=(pass pass-otp gnupg age git jq pinentry-mac)
missing=()
for dep in "${DEPS[@]}"; do
  if ! brew list "${dep}" &>/dev/null; then
    missing+=("${dep}")
  fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
  info "Installing missing dependencies: ${missing[*]}"
  brew install "${missing[@]}"
  ok "Dependencies installed"
else
  ok "All dependencies already installed"
fi

# Configure pinentry for macOS (idempotent)
mkdir -p ~/.gnupg
chmod 700 ~/.gnupg
PINENTRY_PATH="$(brew --prefix)/bin/pinentry-mac"
if [[ -f "${PINENTRY_PATH}" ]] && ! grep -q "pinentry-program" ~/.gnupg/gpg-agent.conf 2>/dev/null; then
  echo "pinentry-program ${PINENTRY_PATH}" >> ~/.gnupg/gpg-agent.conf
  ok "Configured pinentry-mac"
fi

# --------------------------------------------------
# 2. Generate master GPG key
# --------------------------------------------------

if [[ -z "${GPG_EMAIL}" ]]; then
  GPG_EMAIL=$(prompt "GPG email address for master key" "")
fi
if [[ -z "${GPG_EMAIL}" ]]; then
  error "GPG email is required."
  exit 1
fi

if gpg_key_exists "${GPG_EMAIL}"; then
  MASTER_KEY_ID=$(gpg_key_id "${GPG_EMAIL}")
  ok "Master GPG key already exists: ${MASTER_KEY_ID}"
else
  if [[ -z "${GPG_NAME}" ]]; then
    GPG_NAME=$(prompt "Your full name for the GPG key" "")
  fi
  if [[ -z "${GPG_NAME}" ]]; then
    error "GPG name is required."
    exit 1
  fi

  info "Generating master GPG key (RSA-4096, 2yr expiry)..."
  info "GPG will prompt you to set a passphrase."
  pause "Press Enter to start GPG key generation..."

  BATCH_FILE="$(mktemp)"
  cat > "${BATCH_FILE}" <<EOF
%echo Generating master GPG key
Key-Type: RSA
Key-Length: 4096
Subkey-Type: RSA
Subkey-Length: 4096
Name-Real: ${GPG_NAME}
Name-Email: ${GPG_EMAIL}
Expire-Date: 2y
%ask-passphrase
%commit
EOF
  gpg --batch --gen-key "${BATCH_FILE}"
  rm -f "${BATCH_FILE}"

  MASTER_KEY_ID=$(gpg_key_id "${GPG_EMAIL}")
  MASTER_FP=$(gpg_fingerprint "${GPG_EMAIL}")
  ok "Master GPG key created"
  info "Key ID:      ${MASTER_KEY_ID}"
  info "Fingerprint: ${MASTER_FP}"
fi

MASTER_KEY_ID=$(gpg_key_id "${GPG_EMAIL}")

# --------------------------------------------------
# 3. Create GitHub credentials repo
# --------------------------------------------------

if [[ -z "${PASS_REPO}" ]]; then
  if ! command -v gh &>/dev/null; then
    error "GitHub CLI (gh) is required for repo creation."
    error "Install with: brew install gh && gh auth login"
    exit 1
  fi

  GH_USER=$(gh_username)
  if [[ -z "${GH_USER}" ]]; then
    error "Not authenticated with GitHub CLI. Run: gh auth login"
    exit 1
  fi

  REPO_NAME=$(prompt "GitHub repo name for encrypted credentials" "credentials-encrypted")
  PASS_REPO="git@github.com:${GH_USER}/${REPO_NAME}.git"

  if ! gh_repo_exists "${GH_USER}/${REPO_NAME}"; then
    info "Creating private repo: ${GH_USER}/${REPO_NAME}"
    gh repo create "${REPO_NAME}" --private --description "Encrypted credential store (pass + GPG)"
    ok "GitHub repo created: ${GH_USER}/${REPO_NAME}"
  else
    ok "GitHub repo already exists: ${GH_USER}/${REPO_NAME}"
  fi
fi

# --------------------------------------------------
# 4. Initialize pass store
# --------------------------------------------------

if pass_initialized; then
  ok "Password store already initialized"
else
  info "Initializing password store with master key..."
  pass init "${MASTER_KEY_ID}"
  ok "Password store initialized"
fi

# Set up git in the pass store (idempotent)
if [[ ! -d "${HOME}/.password-store/.git" ]]; then
  pass git init
  ok "Git initialized in password store"
fi

# Add remote if not present
CURRENT_REMOTE=$(git -C "${HOME}/.password-store" remote get-url origin 2>/dev/null || true)
if [[ -z "${CURRENT_REMOTE}" ]]; then
  pass git remote add origin "${PASS_REPO}"
  ok "Remote added: ${PASS_REPO}"
elif [[ "${CURRENT_REMOTE}" != "${PASS_REPO}" ]]; then
  warn "Remote origin already set to: ${CURRENT_REMOTE}"
  warn "Expected: ${PASS_REPO}"
  warn "Leaving as-is. Update manually if needed."
fi

# Create directory structure
mkdir -p "${HOME}/.password-store/shared"
mkdir -p "${HOME}/.password-store/infrastructure"

# --------------------------------------------------
# 5. Generate age recovery key
# --------------------------------------------------

AGE_KEY_FILE="${HOME}/.age-recovery-key.txt"
if [[ -f "${AGE_KEY_FILE}" ]]; then
  ok "Age recovery key already exists"
else
  info "Generating age recovery key..."
  age-keygen -o "${AGE_KEY_FILE}" 2>&1
  chmod 400 "${AGE_KEY_FILE}"
  ok "Age recovery key generated"
fi

AGE_PUB=$(grep "public key:" "${AGE_KEY_FILE}" | awk '{print $NF}')
info "Age public key: ${AGE_PUB}"

# --------------------------------------------------
# 6. Backup master GPG key with age
# --------------------------------------------------

GPG_BACKUP="${HOME}/gpg-master-backup.age"
if [[ -f "${GPG_BACKUP}" ]]; then
  ok "Age-encrypted GPG backup already exists"
else
  info "Creating age-encrypted GPG key backup..."
  gpg --export-secret-keys --armor "${MASTER_KEY_ID}" \
    | age -r "${AGE_PUB}" -o "${GPG_BACKUP}"
  shasum -a 256 "${GPG_BACKUP}" > "${GPG_BACKUP}.sha256"
  ok "GPG backup: ${GPG_BACKUP}"
fi

# --------------------------------------------------
# 7. Restart GPG agent
# --------------------------------------------------

gpgconf --kill gpg-agent 2>/dev/null || true
gpgconf --launch gpg-agent 2>/dev/null || true

# --------------------------------------------------
# 8. Push to GitHub
# --------------------------------------------------

# Add any new files and push
cd "${HOME}/.password-store"
git add -A
if ! git diff --cached --quiet 2>/dev/null; then
  git commit -m "Initial credential store setup"
fi
info "Pushing to GitHub..."
if ! pass git push -u origin main 2>&1 && ! pass git push -u origin master 2>&1; then
  warn "Could not push to GitHub. You may need to push manually:"
  warn "  cd ~/.password-store && git push -u origin main"
fi

# --------------------------------------------------
# Done
# --------------------------------------------------

echo ""
printf '%b═══════════════════════════════════════════════%b\n' "${GREEN}${BOLD}" "${NC}"
printf '%b  CREDENTIAL INFRASTRUCTURE READY%b\n' "${GREEN}${BOLD}" "${NC}"
printf '%b═══════════════════════════════════════════════%b\n' "${GREEN}${BOLD}" "${NC}"
echo ""
info "Master GPG Key: ${MASTER_KEY_ID}"
info "Pass repo:      ${PASS_REPO}"
info "Age backup:     ${GPG_BACKUP}"
info "Age identity:   ${AGE_KEY_FILE}"
echo ""
warn "IMPORTANT: Store these recovery materials separately:"
echo "  1. Print ~/.age-recovery-key.txt -> paper in safe"
echo "  2. Copy ~/gpg-master-backup.age -> USB in safe"
echo "  3. Store GPG passphrase in your personal password manager"
echo "  4. Store backup SHA-256 in your personal password manager"
echo ""
pause "Press Enter when you've noted the above..."
