#!/usr/bin/env bash
# shellcheck disable=SC2312
set -euo pipefail

# ================================================
# SERVER CREDENTIAL SETUP
#
# Run on the bot server AFTER OpenClaw is deployed.
# Sets up GPG keys, clones the encrypted credential
# store, and verifies access.
#
# Usage: ./credentials-server-setup.sh <bot-name> <key-bundle.asc> <deploy-key>
#
# Typically invoked by setup.sh via SSH, not manually.
# ================================================

# -- Inline logging (lib.sh is not available on server) --
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'
info() { printf '%b[info]%b  %s\n' "${CYAN}" "${NC}" "$*"; }
ok() { printf '%b[ok]%b    %s\n' "${GREEN}" "${NC}" "$*"; }
warn() { printf '%b[warn]%b  %s\n' "${YELLOW}" "${NC}" "$*"; }
error() { printf '%b[error]%b %s\n' "${RED}" "${NC}" "$*" >&2; }

BOT_NAME="${1:?Usage: ./credentials-server-setup.sh <bot-name> <key-bundle.asc> <deploy-key>}"
KEY_BUNDLE="${2:?Provide decrypted GPG key bundle (.asc)}"
DEPLOY_KEY="${3:?Provide SSH deploy key}"
PASS_REPO="${PASS_REPO:?PASS_REPO must be set (e.g. git@github.com:user/repo.git)}"

echo ""
info "Setting up credentials for bot: ${BOT_NAME}"
echo "-------------------------------------------"

# --------------------------------------------------
# 0. Verify inputs exist
# --------------------------------------------------

for f in "${KEY_BUNDLE}" "${DEPLOY_KEY}"; do
  if [[ ! -f "${f}" ]]; then
    error "File not found: ${f}"
    exit 1
  fi
done
ok "All input files present"

# --------------------------------------------------
# 1. Install dependencies
# --------------------------------------------------

info "Installing credential management packages..."
sudo apt-get update -qq
sudo apt-get install -y -qq pass pass-extension-otp gnupg git
ok "Packages installed"

# --------------------------------------------------
# 2. Ensure NTP (needed for TOTP)
# --------------------------------------------------

info "Verifying NTP..."
sudo timedatectl set-ntp true
ok "NTP enabled"

# --------------------------------------------------
# 3. Set up SSH deploy key for GitHub
# --------------------------------------------------

info "Configuring SSH deploy key for GitHub..."
mkdir -p ~/.ssh && chmod 700 ~/.ssh
cp "${DEPLOY_KEY}" ~/.ssh/github-deploy
chmod 600 ~/.ssh/github-deploy

if ! grep -q "github-deploy" ~/.ssh/config 2>/dev/null; then
  cat >> ~/.ssh/config <<EOF

Host github.com
    IdentityFile ~/.ssh/github-deploy
    IdentitiesOnly yes
EOF
  chmod 600 ~/.ssh/config
fi
ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts 2>/dev/null
ok "SSH deploy key configured"

# --------------------------------------------------
# 4. Import GPG key (via tmpfs to keep key out of disk)
# --------------------------------------------------

info "Importing GPG key..."
TMPDIR_SECURE=$(mktemp -d)
MOUNTED=false
if sudo mount -t tmpfs -o "size=10M,mode=700,uid=$(id -u)" tmpfs "${TMPDIR_SECURE}" 2>/dev/null; then
  MOUNTED=true
fi
cleanup() {
  if ${MOUNTED}; then
    sudo umount "${TMPDIR_SECURE}" 2>/dev/null || true
  else
    rm -f "${TMPDIR_SECURE}"/* 2>/dev/null || true
  fi
  rmdir "${TMPDIR_SECURE}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM ERR

# Key bundle was decrypted locally — move to tmpfs for import, then wipe
mv "${KEY_BUNDLE}" "${TMPDIR_SECURE}/key.asc"
gpg --batch --import "${TMPDIR_SECURE}/key.asc" 2>&1

# Trust imported keys
for fingerprint in $(gpg --list-keys --fingerprint 2>/dev/null | awk '/^ / { gsub(/ /, ""); print }'); do
  echo "${fingerprint}:6:" | gpg --import-ownertrust 2>/dev/null || true
done

BOT_KEY_ID=$(gpg --list-keys --keyid-format long "bot-${BOT_NAME}@openclaw.local" 2>/dev/null \
  | awk '/^pub/ { split($2, a, "/"); print a[2]; exit }')
ok "Bot GPG key imported: ${BOT_KEY_ID}"

# --------------------------------------------------
# 5. Configure GPG agent
# --------------------------------------------------

mkdir -p ~/.gnupg && chmod 700 ~/.gnupg
cat > ~/.gnupg/gpg-agent.conf <<EOF
default-cache-ttl 3600
max-cache-ttl 7200
EOF
gpgconf --kill gpg-agent 2>/dev/null || true

# --------------------------------------------------
# 6. Clone credential store
# --------------------------------------------------

if [[ -d "${HOME}/.password-store/.git" ]]; then
  info "Credential store already cloned, pulling latest..."
  git -C "${HOME}/.password-store" pull --ff-only 2>/dev/null || true
  ok "Credential store updated"
else
  # Remove stale directory if it exists without .git (e.g. from pass package install)
  if [[ -d "${HOME}/.password-store" ]]; then
    warn "Removing stale ~/.password-store (not a git repo)..."
    rm -rf "${HOME}/.password-store"
  fi
  info "Cloning credential store..."
  git clone "${PASS_REPO}" "${HOME}/.password-store"
  chmod 700 "${HOME}/.password-store"
  ok "Credential store cloned"
fi

# --------------------------------------------------
# 7. Verify access
# --------------------------------------------------

info "Verifying credential access..."
BOT_ENTRIES=$(find "${HOME}/.password-store/bot-${BOT_NAME}/" -name '*.gpg' 2>/dev/null | wc -l || echo "0")
SHARED_ENTRIES=$(find "${HOME}/.password-store/shared/" -name '*.gpg' 2>/dev/null | wc -l || echo "0")
info "bot-${BOT_NAME}/: ${BOT_ENTRIES} entries"
info "shared/:          ${SHARED_ENTRIES} entries"
if [[ "${BOT_ENTRIES}" -eq 0 ]] && [[ "${SHARED_ENTRIES}" -eq 0 ]]; then
  warn "No credentials found yet. Store will populate after you run 'pass insert' on your MacBook and push."
fi

# --------------------------------------------------
# 8. Clean up deploy materials from server
# --------------------------------------------------

info "Cleaning up deploy materials..."
rm -f "${KEY_BUNDLE}" "${DEPLOY_KEY}"
ok "Deploy materials removed from server"

# --------------------------------------------------
# Done
# --------------------------------------------------

echo ""
printf '%b═══════════════════════════════════════════════%b\n' "${GREEN}${BOLD}" "${NC}"
printf '%b  CREDENTIALS READY FOR %s%b\n' "${GREEN}${BOLD}" "${BOT_NAME}" "${NC}"
printf '%b═══════════════════════════════════════════════%b\n' "${GREEN}${BOLD}" "${NC}"
echo ""
echo "  pass show shared/openai/api-key"
echo "  pass show bot-${BOT_NAME}/telegram/token"
echo "  pass otp shared/github"
echo ""
