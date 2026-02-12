#!/usr/bin/env bash
set -euo pipefail

# ----------------------------------------------
# Colors
# ----------------------------------------------

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
step() { printf '\n%b> %s%b\n' "${BOLD}" "$*" "${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TF_DIR="${SCRIPT_DIR}/terraform"
SSH_KEY="${TF_DIR}/id_ed25519"
TFVARS="${TF_DIR}/terraform.tfvars"
CLOUD_INIT_TIMEOUT=300 # 5 minutes

# ----------------------------------------------
# Prerequisites
# ----------------------------------------------

step "Checking prerequisites"

if ! command -v terraform &>/dev/null; then
  error "Terraform is not installed. Install it from https://developer.hashicorp.com/terraform/install"
  exit 1
fi

tf_version="$(terraform version -json | python3 -c "import sys,json; print(json.load(sys.stdin)['terraform_version'])")"
tf_major="$(echo "${tf_version}" | cut -d. -f1)"
tf_minor="$(echo "${tf_version}" | cut -d. -f2)"
if [[ "${tf_major}" -lt 1 ]] || { [[ "${tf_major}" -eq 1 ]] && [[ "${tf_minor}" -lt 5 ]]; }; then
  error "Terraform >= 1.5 required (found ${tf_version})"
  exit 1
fi
ok "Terraform ${tf_version}"

if ! command -v ssh &>/dev/null; then
  error "ssh is not installed"
  exit 1
fi
ok "SSH available"

# ----------------------------------------------
# Resolve Hetzner token
# ----------------------------------------------

step "Resolving Hetzner Cloud API token"

HCLOUD_TOKEN="${HCLOUD_TOKEN:-${TF_VAR_hcloud_token:-}}"

if [[ -z "${HCLOUD_TOKEN}" ]] && [[ -f "${TFVARS}" ]]; then
  HCLOUD_TOKEN="$(sed -n 's/^hcloud_token[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "${TFVARS}" 2>/dev/null || true)"
  if [[ -n "${HCLOUD_TOKEN}" ]]; then
    info "Using token from existing terraform.tfvars"
  fi
fi

if [[ -z "${HCLOUD_TOKEN}" ]]; then
  info "No token found in HCLOUD_TOKEN or TF_VAR_hcloud_token env vars."
  printf "  Enter your Hetzner Cloud API token: "
  read -rs HCLOUD_TOKEN
  echo
  if [[ -z "${HCLOUD_TOKEN}" ]]; then
    error "No token provided. Aborting."
    exit 1
  fi
fi

export TF_VAR_hcloud_token="${HCLOUD_TOKEN}"
ok "Token resolved"

# ----------------------------------------------
# Generate terraform.tfvars (if missing)
# ----------------------------------------------

step "Checking terraform.tfvars"

if [[ -f "${TFVARS}" ]]; then
  info "Using existing ${TFVARS}"
else
  info "Generating ${TFVARS}"
  cat >"${TFVARS}" <<EOF
# Hetzner API token — alternatively set via:  export TF_VAR_hcloud_token="..."
hcloud_token = "${HCLOUD_TOKEN}"

server_name = "moltbot-01"
location    = "nbg1"
server_type = "cx23"

# API tokens for OpenClaw bootstrapping (fill in to auto-configure on boot)
telegram_bot_token = ""
anthropic_api_key  = ""
EOF
  ok "Created ${TFVARS}"
fi

# ----------------------------------------------
# Terraform init
# ----------------------------------------------

step "Initializing Terraform"

if [[ -d "${TF_DIR}/.terraform" ]]; then
  info "Already initialized, skipping"
else
  terraform -chdir="${TF_DIR}" init -input=false
fi
ok "Terraform initialized"

# ----------------------------------------------
# Terraform apply
# ----------------------------------------------

step "Provisioning infrastructure"

terraform -chdir="${TF_DIR}" apply -auto-approve -input=false
ok "Infrastructure provisioned"

# ----------------------------------------------
# Extract outputs
# ----------------------------------------------

SERVER_IP="$(terraform -chdir="${TF_DIR}" output -raw server_ip)"
SSH_CMD="ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR molt@${SERVER_IP}"

# Clear stale host key so manual SSH works without warnings
ssh-keygen -R "${SERVER_IP}" &>/dev/null || true

ok "Server IP: ${SERVER_IP}"

# ----------------------------------------------
# Wait for cloud-init
# ----------------------------------------------

step "Waiting for cloud-init to finish (timeout: ${CLOUD_INIT_TIMEOUT}s)"

elapsed=0
interval=10

# Wait for SSH to become available
info "Waiting for SSH..."
while ! ${SSH_CMD} "true" &>/dev/null; do
  sleep 5
  elapsed=$((elapsed + 5))
  if [[ ${elapsed} -ge ${CLOUD_INIT_TIMEOUT} ]]; then
    error "Timed out waiting for SSH after ${CLOUD_INIT_TIMEOUT}s"
    exit 1
  fi
done
ok "SSH is up"

# Wait for cloud-init sentinel
info "Waiting for cloud-init (Node.js, OpenClaw, hardening)..."
while ! ${SSH_CMD} "test -f ~/.openclaw-ready" &>/dev/null; do
  sleep "${interval}"
  elapsed=$((elapsed + interval))
  if [[ ${elapsed} -ge ${CLOUD_INIT_TIMEOUT} ]]; then
    error "Cloud-init timed out after ${CLOUD_INIT_TIMEOUT}s"
    error "Check logs: ${SSH_CMD} \"sudo tail -50 /var/log/cloud-init-output.log\""
    exit 1
  fi
  printf "."
done
echo
ok "Cloud-init complete"

# ----------------------------------------------
# Verification
# ----------------------------------------------

step "Verifying server"

verify_output="$(${SSH_CMD} "
  echo \"Node:\$(node -v)\" \
  && echo \"npm:\$(npm -v)\" \
  && echo \"OpenClaw:\$(openclaw --version)\" \
  && echo \"fail2ban:\$(sudo systemctl is-active fail2ban)\" \
  && echo \"swap:\$(free -m | awk '/Swap/{print \$2}')MB\" \
  && echo \"root_login:\$(grep '^PermitRootLogin' /etc/ssh/sshd_config | awk '{print \$2}')\" \
  && echo \"password_auth:\$(grep '^PasswordAuthentication' /etc/ssh/sshd_config | awk '{print \$2}')\"
")"

failed=0
while IFS=: read -r key value; do
  case "${key}" in
    Node)
      if [[ "${value}" == v22.* ]]; then ok "Node.js ${value}"; else error "Node.js ${value} (expected v22.x)"; failed=1; fi ;;
    npm)
      if [[ -n "${value}" ]]; then ok "npm ${value}"; else error "npm not found"; failed=1; fi ;;
    OpenClaw)
      if [[ -n "${value}" ]]; then ok "OpenClaw ${value}"; else error "OpenClaw not found"; failed=1; fi ;;
    fail2ban)
      if [[ "${value}" == "active" ]]; then ok "fail2ban active"; else error "fail2ban: ${value}"; failed=1; fi ;;
    swap)
      if [[ "${value%MB}" -gt 0 ]]; then ok "Swap ${value}"; else error "No swap configured"; failed=1; fi ;;
    root_login)
      if [[ "${value}" == "no" ]]; then ok "Root login disabled"; else error "Root login: ${value}"; failed=1; fi ;;
    password_auth)
      if [[ "${value}" == "no" ]]; then ok "Password auth disabled"; else error "Password auth: ${value}"; failed=1; fi ;;
    *) ;;
  esac
done <<<"${verify_output}"

if [[ ${failed} -ne 0 ]]; then
  error "Some checks failed. Review output above."
  exit 1
fi

# ----------------------------------------------
# Register host key for manual SSH
# ----------------------------------------------

step "Registering SSH host key"

ssh-keyscan -H "${SERVER_IP}" >>~/.ssh/known_hosts 2>/dev/null
ok "Host key added to ~/.ssh/known_hosts"

# ----------------------------------------------
# Done
# ----------------------------------------------

BANNER="${GREEN}${BOLD}"
printf "\n%b----------------------------------------%b\n" "${BANNER}" "${NC}"
printf "%b  Setup complete!%b\n" "${BANNER}" "${NC}"
printf "%b----------------------------------------%b\n\n" "${BANNER}" "${NC}"

printf '  Server IP:  %b%s%b\n' "${BOLD}" "${SERVER_IP}" "${NC}"
printf '  SSH:        %bssh -i terraform/id_ed25519 molt@%s%b\n' "${BOLD}" "${SERVER_IP}" "${NC}"
printf '  Shortcut:   %bmake ssh%b\n\n' "${BOLD}" "${NC}"

printf '  %bNext step:%b SSH in and run the OpenClaw onboarding wizard:\n\n' "${YELLOW}" "${NC}"
printf '    make ssh\n'
printf '    openclaw onboard --install-daemon\n\n'
