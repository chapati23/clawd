#!/usr/bin/env bash
# shellcheck disable=SC2310,SC2311,SC2312
set -euo pipefail

# ================================================
# ROTATE GPG KEY
#
# Usage: ./scripts/credentials-rotate.sh <master|bot-name>
#
# Run on your MacBook. Generates a new key, re-encrypts
# affected pass directories, creates a new age backup,
# and pushes to GitHub.
#
# After rotating, you must re-deploy credentials to
# all servers that use the rotated key.
# ================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

TARGET="${1:?Usage: ./scripts/credentials-rotate.sh <master|bot-name>}"
GPG_EMAIL="${GPG_EMAIL:-}"

# --------------------------------------------------
# Determine old key
# --------------------------------------------------

step "Rotating GPG key: ${TARGET}"

if [[ "${TARGET}" == "master" ]]; then
  if [[ -z "${GPG_EMAIL}" ]]; then
    GPG_EMAIL=$(prompt "Master GPG email address" "")
  fi
  if [[ -z "${GPG_EMAIL}" ]]; then
    error "GPG_EMAIL is required for master key rotation."
    exit 1
  fi
  OLD_KEY_ID=$(gpg_key_id "${GPG_EMAIL}")
  KEY_EMAIL="${GPG_EMAIL}"
  PROTECTION="%ask-passphrase"
  # Extract display name from uid line: "uid [ultimate] Name <email>"
  KEY_NAME=$(gpg --list-keys "${KEY_EMAIL}" 2>/dev/null \
    | awk '/^uid/ { sub(/.*\] /, ""); sub(/ <.*/, ""); print; exit }')
  KEY_NAME="${KEY_NAME:-${TARGET}}"
else
  KEY_EMAIL="bot-${TARGET}@openclaw.local"
  OLD_KEY_ID=$(gpg_key_id "${KEY_EMAIL}")
  PROTECTION="%no-protection"
  KEY_NAME="bot-${TARGET}"
fi

if [[ -z "${OLD_KEY_ID}" ]]; then
  error "No existing GPG key found for: ${KEY_EMAIL}"
  exit 1
fi

info "Old key: ${OLD_KEY_ID} (${KEY_EMAIL})"

# --------------------------------------------------
# Generate new key (with -rotated email to avoid conflict)
# --------------------------------------------------

NEW_EMAIL="${KEY_EMAIL}-rotated"
info "Generating new key..."

BATCH_FILE="$(mktemp)"
cat > "${BATCH_FILE}" <<EOF
Key-Type: RSA
Key-Length: 4096
Subkey-Type: RSA
Subkey-Length: 4096
Name-Real: ${KEY_NAME}
Name-Email: ${NEW_EMAIL}
Expire-Date: 2y
${PROTECTION}
%commit
EOF
gpg --batch --gen-key "${BATCH_FILE}"
rm -f "${BATCH_FILE}"

NEW_KEY_ID=$(gpg_key_id "${NEW_EMAIL}")
ok "New key: ${NEW_KEY_ID}"

# --------------------------------------------------
# Re-encrypt affected directories
# --------------------------------------------------

info "Re-encrypting affected pass directories..."

while IFS= read -r gpg_id_file; do
  if grep -q "${OLD_KEY_ID}" "${gpg_id_file}"; then
    dir=$(dirname "${gpg_id_file}")
    subdir="${dir#"${HOME}/.password-store"}"
    subdir="${subdir#/}"

    # Build new recipient list: replace old key with new key
    RECIPIENTS=""
    while IFS= read -r recipient; do
      if [[ "${recipient}" == "${OLD_KEY_ID}" ]]; then
        RECIPIENTS="${RECIPIENTS} ${NEW_KEY_ID}"
      else
        RECIPIENTS="${RECIPIENTS} ${recipient}"
      fi
    done < "${gpg_id_file}"

    if [[ -n "${subdir}" ]]; then
      # shellcheck disable=SC2086
      pass init -p "${subdir}/" ${RECIPIENTS}
    else
      # shellcheck disable=SC2086
      pass init ${RECIPIENTS}
    fi
    ok "Re-encrypted: ${subdir:-root}"
  fi
done < <(find "${HOME}/.password-store" -name '.gpg-id')

# --------------------------------------------------
# Create new age-encrypted backup
# --------------------------------------------------

AGE_KEY_FILE="${HOME}/.age-recovery-key.txt"
if [[ ! -f "${AGE_KEY_FILE}" ]]; then
  error "Age recovery key not found: ${AGE_KEY_FILE}"
  exit 1
fi

AGE_PUB=$(grep "public key:" "${AGE_KEY_FILE}" | awk '{print $NF}')

if [[ "${TARGET}" == "master" ]]; then
  BACKUP_FILE="${HOME}/gpg-master-backup.age"
  gpg --export-secret-keys --armor "${NEW_KEY_ID}" \
    | age -r "${AGE_PUB}" -o "${BACKUP_FILE}"
  shasum -a 256 "${BACKUP_FILE}" > "${BACKUP_FILE}.sha256"
  ok "Master backup updated: ${BACKUP_FILE}"
else
  MASTER_KEY_ID=$(head -1 "${HOME}/.password-store/.gpg-id")
  BACKUP_FILE="${HOME}/bot-${TARGET}-key.age"
  (gpg --export-secret-keys --armor "${NEW_KEY_ID}"; gpg --export --armor "${MASTER_KEY_ID}") \
    | age -r "${AGE_PUB}" -o "${BACKUP_FILE}"
  shasum -a 256 "${BACKUP_FILE}" > "${BACKUP_FILE}.sha256"
  ok "Bot key bundle updated: ${BACKUP_FILE}"
fi

# --------------------------------------------------
# Push to GitHub
# --------------------------------------------------

cd "${HOME}/.password-store"
git add -A
if ! git diff --cached --quiet 2>/dev/null; then
  git commit -m "Key rotation: ${TARGET}"
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
printf '%b  KEY ROTATION COMPLETE%b\n' "${GREEN}${BOLD}" "${NC}"
printf '%b═══════════════════════════════════════════════%b\n' "${GREEN}${BOLD}" "${NC}"
echo ""
info "Old key: ${OLD_KEY_ID}"
info "New key: ${NEW_KEY_ID}"
echo ""
warn "REQUIRED FOLLOW-UP:"
echo "  1. Re-run credential setup on all servers using this key"
echo "  2. Update the age backup in your safe/USB"
echo ""
