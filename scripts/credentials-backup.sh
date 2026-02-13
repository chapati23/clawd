#!/usr/bin/env bash
# shellcheck disable=SC2312
set -euo pipefail

# ================================================
# CREDENTIAL BACKUP — Daily cron job
#
# Deployed to /opt/scripts/ on the primary server.
# Cron: 0 3 * * * /opt/scripts/credentials-backup.sh
#
# Creates a tarball backup, pushes to GitHub, and
# prunes backups older than 90 days.
# ================================================

LOG="/var/log/credential-backup.log"
PASS_DIR="${HOME}/.password-store"
BACKUP_DIR="/var/backups/credentials"
DATE=$(date +%Y-%m-%d)
HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG}"; }

# --------------------------------------------------
# Lockfile (with stale detection)
# --------------------------------------------------

LOCKFILE="/var/run/credential-backup.lock"
if [[ -f "${LOCKFILE}" ]]; then
  if [[ "$(uname -s)" == "Darwin" ]]; then
    LOCK_AGE=$(( $(date +%s) - $(stat -f %m "${LOCKFILE}") ))
  else
    LOCK_AGE=$(( $(date +%s) - $(stat -c %Y "${LOCKFILE}") ))
  fi
  if [[ "${LOCK_AGE}" -gt 3600 ]]; then
    rm -f "${LOCKFILE}"
  else
    log "ERROR: Already running (lockfile age: ${LOCK_AGE}s)"
    exit 1
  fi
fi
trap 'rm -f "${LOCKFILE}"' EXIT
touch "${LOCKFILE}"

log "Starting backup..."

# --------------------------------------------------
# Sanity check
# --------------------------------------------------

if [[ ! -d "${PASS_DIR}" ]]; then
  log "ERROR: Password store not found at ${PASS_DIR}"
  exit 1
fi

ENTRY_COUNT=$(find "${PASS_DIR}" -name '*.gpg' | wc -l)

# --------------------------------------------------
# Create tarball + checksum
# --------------------------------------------------

mkdir -p "${BACKUP_DIR}"
TARBALL="${BACKUP_DIR}/credentials-${DATE}.tar.gz"
tar -czf "${TARBALL}" -C "${HOME}" .password-store

# Verify tarball integrity
if ! tar -tzf "${TARBALL}" > /dev/null 2>&1; then
  log "CRITICAL: Corrupt tarball! Aborting."
  exit 1
fi

SHA256=$(sha256sum "${TARBALL}" | awk '{print $1}')
echo "${SHA256}  credentials-${DATE}.tar.gz" >> "${BACKUP_DIR}/checksums.txt"

# --------------------------------------------------
# Push to GitHub
# --------------------------------------------------

cd "${PASS_DIR}"
if [[ -n "$(git status --porcelain)" ]]; then
  git add -A
  git commit -m "Backup $(date +%Y%m%d)"
  git push
  log "Pushed to GitHub"
fi

# --------------------------------------------------
# Prune old backups (>90 days)
# --------------------------------------------------

find "${BACKUP_DIR}" -name "credentials-*.tar.gz" -mtime +90 -delete

# --------------------------------------------------
# Healthcheck ping (optional)
# --------------------------------------------------

if [[ -n "${HEALTHCHECK_URL}" ]]; then
  curl -fsS -m 10 --retry 3 "${HEALTHCHECK_URL}" > /dev/null 2>&1 || true
fi

log "Done. ${ENTRY_COUNT} entries, SHA256: ${SHA256:0:16}..."
