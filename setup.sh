#!/usr/bin/env bash
# shellcheck disable=SC2310,SC2311,SC2312
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/scripts/lib.sh"

TF_DIR="${SCRIPT_DIR}/terraform"
SSH_KEY="${TF_DIR}/id_ed25519"
TFVARS="${TF_DIR}/terraform.tfvars"
CLOUD_INIT_TIMEOUT=300 # 5 minutes
USE_CREDENTIALS=false

# pass path : terraform variable name
TOKEN_MAP=(
  "shared/telegram/bot-token:telegram_bot_token"
  "shared/anthropic/api-key:anthropic_api_key"
  "shared/gemini/api-key:gemini_api_key"
  "shared/notion/api-key:notion_api_key"
  "shared/perplexity/api-key:perplexity_api_key"
)

# ==============================================================
# Phase 1: Prerequisites
# ==============================================================

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

# ==============================================================
# Phase 2: Credential infrastructure (detect or bootstrap)
# ==============================================================

step "Checking credential management"

# Detect if credential infrastructure is already set up
if pass_initialized && command -v gpg &>/dev/null; then
  USE_CREDENTIALS=true
  ok "Credential store found (pass initialized)"
elif is_macos; then
  # First-time setup: offer to bootstrap credential management
  echo ""
  info "No encrypted credential store detected."
  info "Credential management uses pass + GPG + age to securely"
  info "store and deploy API tokens and secrets."
  echo ""
  if confirm "Set up encrypted credential management? (recommended)" "Y"; then
    USE_CREDENTIALS=true

    # Run the one-time credential infrastructure bootstrap
    "${SCRIPT_DIR}/scripts/credentials-init.sh"
    echo ""
  else
    warn "Skipping credential management. Tokens will be stored in terraform.tfvars (plaintext, gitignored)."
  fi
else
  info "Credential management not configured. Using terraform.tfvars for tokens."
fi

# ==============================================================
# Phase 3: Bot credentials (detect or create)
# ==============================================================

# Determine bot name from existing tfvars or default
BOT_NAME=""
if [[ -f "${TFVARS}" ]]; then
  BOT_NAME=$(tfvars_get "server_name" "${TFVARS}")
fi
BOT_NAME="${BOT_NAME:-moltbot-01}"

if ${USE_CREDENTIALS}; then
  step "Checking bot credentials"

  BOT_EMAIL="bot-${BOT_NAME}@openclaw.local"

  if gpg_key_exists "${BOT_EMAIL}"; then
    ok "Bot GPG key exists for: ${BOT_NAME}"
  else
    info "No bot GPG key found for: ${BOT_NAME}"
    info "Creating bot credentials..."
    echo ""
    "${SCRIPT_DIR}/scripts/add-bot.sh" "${BOT_NAME}" "yes"
    echo ""
  fi
fi

# ==============================================================
# Phase 4: Resolve tokens (pass → env vars → tfvars)
# ==============================================================

step "Resolving API tokens"

# --- Hetzner token ---
HCLOUD_TOKEN="${HCLOUD_TOKEN:-${TF_VAR_hcloud_token:-}}"

# Try pass first
if [[ -z "${HCLOUD_TOKEN}" ]] && ${USE_CREDENTIALS}; then
  HCLOUD_TOKEN=$(pass_get "infrastructure/hetzner/api-key" || true)
  if [[ -n "${HCLOUD_TOKEN}" ]]; then
    info "Hetzner token loaded from pass"
  fi
fi

# Try existing tfvars
if [[ -z "${HCLOUD_TOKEN}" ]] && [[ -f "${TFVARS}" ]]; then
  HCLOUD_TOKEN=$(tfvars_get "hcloud_token" "${TFVARS}")
  if [[ -n "${HCLOUD_TOKEN}" ]]; then
    info "Hetzner token loaded from terraform.tfvars"
  fi
fi

# Prompt as last resort
if [[ -z "${HCLOUD_TOKEN}" ]]; then
  info "No Hetzner token found in pass, env vars, or terraform.tfvars."
  HCLOUD_TOKEN=$(prompt_secret "Enter your Hetzner Cloud API token")
  if [[ -z "${HCLOUD_TOKEN}" ]]; then
    error "No token provided. Aborting."
    exit 1
  fi

  # Store in pass if available
  if ${USE_CREDENTIALS}; then
    if echo "${HCLOUD_TOKEN}" | pass insert -f infrastructure/hetzner/api-key 2>&1; then
      ok "Hetzner token stored in pass"
    else
      warn "Could not store Hetzner token in pass (continuing with env var)"
    fi
  fi
fi

export TF_VAR_hcloud_token="${HCLOUD_TOKEN}"
ok "Hetzner token resolved"

# --- Optional tokens (only resolve from pass to env vars) ---
if ${USE_CREDENTIALS}; then
  for token_pair in "${TOKEN_MAP[@]}"; do
    pass_path="${token_pair%%:*}"
    tf_var="${token_pair##*:}"
    env_var="TF_VAR_${tf_var}"

    # Skip if already set via env
    if [[ -n "${!env_var:-}" ]]; then
      continue
    fi

    value=$(pass_get "${pass_path}" || true)
    if [[ -n "${value}" ]]; then
      export "${env_var}=${value}"
    fi
  done
  ok "Optional tokens loaded from pass"
fi

# ==============================================================
# Phase 5: Generate / update terraform.tfvars
# ==============================================================

step "Checking terraform.tfvars"

if [[ -f "${TFVARS}" ]]; then
  info "Using existing ${TFVARS}"

  # Safely update tokens from pass (targeted per-key replacement, backup first)
  if ${USE_CREDENTIALS}; then
    tfvars_update "hcloud_token" "${HCLOUD_TOKEN}" "${TFVARS}"

    # Update optional tokens if they exist in both pass and tfvars
    for token_pair in "${TOKEN_MAP[@]}"; do
      pass_path="${token_pair%%:*}"
      tf_var="${token_pair##*:}"
      value=$(pass_get "${pass_path}" || true)

      if [[ -n "${value}" ]]; then
        tfvars_update "${tf_var}" "${value}" "${TFVARS}"
      fi
    done
    ok "terraform.tfvars updated from pass (backup: terraform.tfvars.bak)"
  fi
else
  info "Generating ${TFVARS}"
  cat >"${TFVARS}" <<EOF
# Hetzner API token — alternatively set via:  export TF_VAR_hcloud_token="..."
hcloud_token = "${HCLOUD_TOKEN}"

server_name = "${BOT_NAME}"
location    = "nbg1"
server_type = "cx23"

# API tokens for OpenClaw bootstrapping (fill in to auto-configure on boot)
telegram_bot_token = "${TF_VAR_telegram_bot_token:-}"
anthropic_api_key  = "${TF_VAR_anthropic_api_key:-}"
gemini_api_key     = "${TF_VAR_gemini_api_key:-}"
notion_api_key     = "${TF_VAR_notion_api_key:-}"
perplexity_api_key = "${TF_VAR_perplexity_api_key:-}"
EOF
  ok "Created ${TFVARS}"
fi

# ==============================================================
# Phase 6: Terraform init
# ==============================================================

step "Initializing Terraform"

if [[ -d "${TF_DIR}/.terraform" ]]; then
  info "Already initialized, skipping"
else
  terraform -chdir="${TF_DIR}" init -input=false
fi
ok "Terraform initialized"

# ==============================================================
# Phase 7: Terraform apply
# ==============================================================

step "Provisioning infrastructure"

terraform -chdir="${TF_DIR}" apply -auto-approve -input=false
ok "Infrastructure provisioned"

# ==============================================================
# Phase 8: Extract outputs
# ==============================================================

SERVER_IP="$(terraform -chdir="${TF_DIR}" output -raw server_ip)"
SSH_CMD="ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR molt@${SERVER_IP}"
SCP_CMD="scp -i ${SSH_KEY} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# Clear stale host key so manual SSH works without warnings
ssh-keygen -R "${SERVER_IP}" &>/dev/null || true

ok "Server IP: ${SERVER_IP}"

# ==============================================================
# Phase 9: Wait for cloud-init
# ==============================================================

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

# ==============================================================
# Phase 10: Deploy credentials to server
# ==============================================================

if ${USE_CREDENTIALS}; then
  step "Deploying credentials to server"

  BOT_KEY_AGE="${HOME}/bot-${BOT_NAME}-key.age"
  DEPLOY_KEY="${HOME}/bot-${BOT_NAME}-deploy-key"
  AGE_KEY_FILE="${HOME}/.age-recovery-key.txt"

  # Verify deploy materials exist
  DEPLOY_READY=true
  for f in "${BOT_KEY_AGE}" "${DEPLOY_KEY}" "${AGE_KEY_FILE}"; do
    if [[ ! -f "${f}" ]]; then
      warn "Missing deploy material: ${f}"
      DEPLOY_READY=false
    fi
  done

  if ${DEPLOY_READY}; then
    # Check if credentials are already set up on the server
    if ${SSH_CMD} "test -d ~/.password-store/.git" &>/dev/null; then
      info "Credentials already deployed on server, pulling latest..."
      ${SSH_CMD} "cd ~/.password-store && git pull --ff-only" 2>/dev/null || true
      ok "Credential store updated on server"
    else
      # Get SHA-256 for integrity verification
      BOT_KEY_SHA256=""
      if [[ -f "${BOT_KEY_AGE}.sha256" ]]; then
        BOT_KEY_SHA256=$(awk '{print $1}' "${BOT_KEY_AGE}.sha256")
      fi

      # Determine pass repo URL
      PASS_REPO=$(git -C "${HOME}/.password-store" remote get-url origin 2>/dev/null || true)

      # Clean up stale deploy materials from previous runs (read-only files block scp)
      ${SSH_CMD} "rm -f ~/credentials-server-setup.sh ~/bot-*-key.age ~/.age-recovery-key.txt ~/bot-*-deploy-key" 2>/dev/null || true

      info "Copying deploy materials to server..."
      ${SCP_CMD} \
        "${SCRIPT_DIR}/scripts/credentials-server-setup.sh" \
        "${BOT_KEY_AGE}" \
        "${AGE_KEY_FILE}" \
        "${DEPLOY_KEY}" \
        "molt@${SERVER_IP}:~/"

      info "Running credential setup on server..."
      ${SSH_CMD} "PASS_REPO='${PASS_REPO}' bash ~/credentials-server-setup.sh '${BOT_NAME}' 'bot-${BOT_NAME}-key.age' '.age-recovery-key.txt' 'bot-${BOT_NAME}-deploy-key' '${BOT_KEY_SHA256}'"

      # Clean up the setup script from server (deploy materials are cleaned by the script itself)
      ${SSH_CMD} "rm -f ~/credentials-server-setup.sh" 2>/dev/null || true

      ok "Credentials deployed to server"
    fi

    # Deploy backup cron job
    info "Deploying credential backup cron..."
    ${SCP_CMD} "${SCRIPT_DIR}/scripts/credentials-backup.sh" "molt@${SERVER_IP}:~/"
    ${SSH_CMD} "sudo mkdir -p /opt/scripts && sudo mv ~/credentials-backup.sh /opt/scripts/ && sudo chmod 700 /opt/scripts/credentials-backup.sh"
    # Add cron job if not already present
    ${SSH_CMD} "(crontab -l 2>/dev/null | grep -q 'credentials-backup' || (crontab -l 2>/dev/null; echo '0 3 * * * /opt/scripts/credentials-backup.sh') | crontab -)" 2>/dev/null || true
    ok "Backup cron job deployed (daily at 03:00)"
  else
    warn "Skipping credential deployment (missing deploy materials)."
    warn "Run ./scripts/add-bot.sh ${BOT_NAME} to generate them."
  fi
fi

# ==============================================================
# Phase 11: Verification
# ==============================================================

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

# Verify credential access on server
if ${USE_CREDENTIALS}; then
  if ${SSH_CMD} "test -d ~/.password-store/.git" &>/dev/null; then
    cred_count=$(${SSH_CMD} "find ~/.password-store -name '*.gpg' 2>/dev/null | wc -l" 2>/dev/null || echo "0")
    if [[ "${cred_count}" -gt 0 ]]; then
      ok "Credential store: ${cred_count} entries accessible"
    else
      warn "Credential store cloned but no entries found"
    fi
  fi
fi

if [[ ${failed} -ne 0 ]]; then
  error "Some checks failed. Review output above."
  exit 1
fi

# ==============================================================
# Phase 12: Register host key for manual SSH
# ==============================================================

step "Registering SSH host key"

ssh-keyscan -H "${SERVER_IP}" >>~/.ssh/known_hosts 2>/dev/null
ok "Host key added to ~/.ssh/known_hosts"

# ==============================================================
# Done
# ==============================================================

BANNER="${GREEN}${BOLD}"
printf "\n%b----------------------------------------%b\n" "${BANNER}" "${NC}"
printf "%b  Setup complete!%b\n" "${BANNER}" "${NC}"
printf "%b----------------------------------------%b\n\n" "${BANNER}" "${NC}"

printf '  Server IP:  %b%s%b\n' "${BOLD}" "${SERVER_IP}" "${NC}"
printf '  SSH:        %bssh -i terraform/id_ed25519 molt@%s%b\n' "${BOLD}" "${SERVER_IP}" "${NC}"
printf '  Shortcut:   %bmake ssh%b\n\n' "${BOLD}" "${NC}"

if ${USE_CREDENTIALS}; then
  printf '  %bCredentials:%b Deployed via pass (encrypted)\n' "${BOLD}" "${NC}"
  printf '  %bBackup cron:%b Daily at 03:00 UTC\n\n' "${BOLD}" "${NC}"
fi

printf '  %bNext step:%b SSH in and run the OpenClaw onboarding wizard:\n\n' "${YELLOW}" "${NC}"
printf '    make ssh\n'
printf '    openclaw onboard --install-daemon\n\n'
