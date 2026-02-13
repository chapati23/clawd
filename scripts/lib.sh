#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2312
# Shared helpers for all clawd scripts.
# Source this file; do not execute directly.

# ----------------------------------------------
# Colors
# ----------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ----------------------------------------------
# Logging
# ----------------------------------------------

info() { printf '%b[info]%b  %s\n' "${CYAN}" "${NC}" "$*"; }
ok() { printf '%b[ok]%b    %s\n' "${GREEN}" "${NC}" "$*"; }
warn() { printf '%b[warn]%b  %s\n' "${YELLOW}" "${NC}" "$*"; }
error() { printf '%b[error]%b %s\n' "${RED}" "${NC}" "$*" >&2; }
step() { printf '\n%b> %s%b\n' "${BOLD}" "$*" "${NC}"; }

# ----------------------------------------------
# Prompts
# ----------------------------------------------

# Ask user for input with a default value.
# Usage: result=$(prompt "Your name" "default_value")
prompt() {
  local message="$1"
  local default="${2:-}"
  local answer

  if [[ -n "${default}" ]]; then
    printf '  %s [%s]: ' "${message}" "${default}" >&2
  else
    printf '  %s: ' "${message}" >&2
  fi
  read -r answer
  echo "${answer:-${default}}"
}

# Ask user for secret input (no echo).
# Usage: result=$(prompt_secret "API token")
prompt_secret() {
  local message="$1"
  local answer

  printf '  %s: ' "${message}" >&2
  read -rs answer
  echo >&2
  echo "${answer}"
}

# Ask yes/no question. Returns 0 for yes, 1 for no.
# Usage: if confirm "Continue?" "Y"; then ...
confirm() {
  local message="$1"
  local default="${2:-N}" # Y or N
  local hint answer

  if [[ "${default}" == "Y" ]]; then
    hint="Y/n"
  else
    hint="y/N"
  fi

  printf '  %s [%s] ' "${message}" "${hint}" >&2
  read -r answer
  answer="${answer:-${default}}"

  [[ "${answer}" =~ ^[Yy]$ ]]
}

# Wait for user to press Enter after reading important information.
pause() {
  local message="${1:-Press Enter to continue...}"
  printf '\n  %b%s%b ' "${YELLOW}" "${message}" "${NC}" >&2
  read -r
}

# ----------------------------------------------
# Platform detection
# ----------------------------------------------

is_macos() { [[ "$(uname -s)" == "Darwin" ]]; }

# ----------------------------------------------
# GPG helpers
# ----------------------------------------------

# Get the long key ID for a GPG key by email.
# Usage: key_id=$(gpg_key_id "user@example.com")
gpg_key_id() {
  local email="$1"
  gpg --list-keys --keyid-format long "${email}" 2>/dev/null \
    | awk '/^pub/ { split($2, a, "/"); print a[2]; exit }'
}

# Get the fingerprint for a GPG key by email.
# Usage: fp=$(gpg_fingerprint "user@example.com")
gpg_fingerprint() {
  local email="$1"
  gpg --fingerprint "${email}" 2>/dev/null \
    | awk '/^ / { gsub(/ /, ""); print; exit }'
}

# Check if a GPG key exists for a given email.
gpg_key_exists() {
  local email="$1"
  gpg --list-keys "${email}" &>/dev/null
}

# ----------------------------------------------
# pass helpers
# ----------------------------------------------

# Check if the pass store is initialized.
pass_initialized() {
  [[ -f "${HOME}/.password-store/.gpg-id" ]]
}

# Check if a pass entry exists.
pass_entry_exists() {
  local entry="$1"
  [[ -f "${HOME}/.password-store/${entry}.gpg" ]]
}

# Read a value from pass (returns empty string if not found).
pass_get() {
  local entry="$1"
  if pass_entry_exists "${entry}"; then
    pass show "${entry}" 2>/dev/null
  fi
}

# ----------------------------------------------
# terraform.tfvars helpers
# ----------------------------------------------

# Safely update a single key in terraform.tfvars (targeted replacement).
# Creates a .bak backup before modifying. Never deletes keys.
# Usage: tfvars_update "hcloud_token" "new_value" "/path/to/terraform.tfvars"
tfvars_update() {
  local key="$1"
  local value="$2"
  local file="$3"

  if [[ ! -f "${file}" ]]; then
    warn "tfvars file not found: ${file}"
    return 1
  fi

  # Only update if the key already exists in the file
  if grep -q "^${key}[[:space:]]*=" "${file}"; then
    cp "${file}" "${file}.bak"
    # Use awk with ENVIRON to avoid sed injection via special characters in value
    KEY="${key}" VALUE="${value}" awk '
      BEGIN { key = ENVIRON["KEY"]; val = ENVIRON["VALUE"] }
      $0 ~ "^"key"[[:space:]]*=" { print key " = \"" val "\""; next }
      { print }
    ' "${file}.bak" > "${file}"
  fi
}

# Read a value from terraform.tfvars.
# Usage: value=$(tfvars_get "hcloud_token" "/path/to/terraform.tfvars")
tfvars_get() {
  local key="$1"
  local file="$2"

  if [[ -f "${file}" ]]; then
    sed -n "s/^${key}[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" "${file}" 2>/dev/null
  fi
}

# ----------------------------------------------
# GitHub CLI helpers
# ----------------------------------------------

# Get the authenticated GitHub username.
gh_username() {
  gh api user --jq '.login' 2>/dev/null
}

# Check if a GitHub repo exists.
# Usage: if gh_repo_exists "owner/repo"; then ...
gh_repo_exists() {
  local repo="$1"
  gh repo view "${repo}" &>/dev/null
}
