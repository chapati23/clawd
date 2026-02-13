#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/scripts/lib.sh"
TF_DIR="${SCRIPT_DIR}/terraform"

# ----------------------------------------------
# Prerequisites
# ----------------------------------------------

step "Checking prerequisites"

if ! command -v terraform &>/dev/null; then
  error "Terraform is not installed"
  exit 1
fi
ok "Terraform available"

if [[ ! -f "${TF_DIR}/terraform.tfstate" ]]; then
  error "No Terraform state found at ${TF_DIR}/terraform.tfstate -- nothing to destroy"
  exit 1
fi
ok "State file found"

# Show what will be destroyed
SERVER_IP="$(terraform -chdir="${TF_DIR}" output -raw server_ip 2>/dev/null || echo "unknown")"
info "Server IP: ${SERVER_IP}"

# ----------------------------------------------
# Confirmation
# ----------------------------------------------

if [[ "${1:-}" != "--yes" ]]; then
  printf '\n%b  This will permanently destroy your OpenClaw server and all its data.%b\n\n' "${RED}${BOLD}" "${NC}"
  printf "  Continue? [y/N] "
  read -r confirm
  if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
    info "Aborted."
    exit 0
  fi
fi

# ----------------------------------------------
# Disable protections
# ----------------------------------------------

step "Disabling delete protection"

terraform -chdir="${TF_DIR}" apply \
  -var="enable_protection=false" \
  -auto-approve \
  -input=false \
  -compact-warnings
ok "Protections disabled"

# ----------------------------------------------
# Destroy
# ----------------------------------------------

step "Destroying infrastructure"

terraform -chdir="${TF_DIR}" destroy \
  -var="enable_protection=false" \
  -auto-approve \
  -input=false
ok "All resources destroyed"

# ----------------------------------------------
# Done
# ----------------------------------------------

BANNER="${GREEN}${BOLD}"
printf "\n%b----------------------------------------%b\n" "${BANNER}" "${NC}"
printf "%b  Teardown complete.%b\n" "${BANNER}" "${NC}"
printf "%b----------------------------------------%b\n\n" "${BANNER}" "${NC}"
printf '  All Hetzner resources have been destroyed.\n'
printf '  Run %b./setup.sh%b to recreate.\n\n' "${BOLD}" "${NC}"
