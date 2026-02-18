# clawd

Personal [OpenClaw](https://openclaw.ai) gateway running on Hetzner Cloud, fully managed via Terraform.

OpenClaw is an open-source AI assistant that connects to messaging platforms (WhatsApp, Telegram, Discord, Slack, Signal, etc.) and runs as a persistent gateway on your own server.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5
- A [Hetzner Cloud](https://console.hetzner.cloud/) account with an API token
- A Hetzner Cloud project (create one in the console)
- A [Telegram](https://telegram.org/) account (for creating a bot via [@BotFather](https://t.me/BotFather) — see [Connecting Telegram](#connecting-telegram))
- An [Anthropic API key](https://console.anthropic.com/) (for the AI backend)
- A [Notion](https://www.notion.so) internal integration for read/write workspace access (see [Connecting Notion](#connecting-notion))

For encrypted credential management (recommended):

- [Homebrew](https://brew.sh) (macOS)
- [GitHub CLI](https://cli.github.com/) (`gh`) — authenticated with `gh auth login`

## Quick Start

```bash
git clone <repo-url> && cd clawd
./setup.sh
```

That's it. The script handles everything:

1. **Credential setup** (first run only) — installs `pass` + GPG + `age`, generates encryption keys, creates a private GitHub repo for your encrypted credential store
2. **Infrastructure provisioning** — Terraform init, apply, cloud-init, verification
3. **Credential deployment** — securely copies encryption keys to the server and clones the credential store
4. **Verification** — checks every component and reports pass/fail

At the end, SSH in and run the one manual step — OpenClaw onboarding:

```bash
make ssh
openclaw onboard --install-daemon
```

The onboarding wizard walks you through connecting messaging platforms (Telegram, WhatsApp, Discord, etc.) and installs OpenClaw as a system daemon so it survives reboots.

### Returning users

On subsequent runs, `setup.sh` detects that credential infrastructure already exists and skips the bootstrap. It pulls tokens from `pass` automatically, updates `terraform.tfvars`, provisions the server, and deploys credentials — no manual input needed.

## Credential Management

Secrets are stored in an encrypted credential store powered by [`pass`](https://www.passwordstore.org/) (GPG-encrypted) with `age`-encrypted backups for disaster recovery.

### Architecture

```
~/.password-store/
  shared/              # Encrypted to: master-key + ALL bot keys
    openai/api-key.gpg
    anthropic/api-key.gpg
  bot-moltbot-01/      # Encrypted to: master-key + bot-key ONLY
    telegram/bot-token.gpg
    notion/api-key.gpg
  infrastructure/      # Encrypted to: master-key ONLY (no bot access)
    hetzner/api-key.gpg
```

Each bot only accesses its own credentials plus shared ones. Compromising one bot does **not** expose other bots' secrets.

### How it works

- **On your MacBook**: `pass` + GPG manages the encrypted store, pushed to a private GitHub repo
- **On each server**: A read-only clone with a bot-scoped GPG key that can only decrypt its own entries
- **Backups**: Daily cron job creates tarballs + pushes to GitHub, prunes backups older than 90 days
- **Recovery**: `age`-encrypted GPG key backups stored on USB/paper in a safe

### Security properties

| Property                           | Status                    |
| ---------------------------------- | ------------------------- |
| Encrypted at rest                  | GPG (AES-256)             |
| Per-bot isolation                  | Separate GPG keys per bot |
| One bot compromised != all secrets | Scoped decryption         |
| Temp keys never touch disk         | tmpfs on server           |
| Backup integrity verification      | SHA-256                   |
| Key expiry forces rotation         | 2-year expiry             |

### Store path conventions

| Path                             | Encrypted to                     | Use for                                                |
| -------------------------------- | -------------------------------- | ------------------------------------------------------ |
| `shared/<service>/<key>`         | Master key + all bot keys        | API keys shared across bots (Anthropic, OpenAI, etc.)  |
| `bot-<name>/<service>/<key>`     | Master key + that bot's key only | Bot-specific credentials (Telegram token, Notion key)  |
| `infrastructure/<service>/<key>` | Master key only                  | Infra secrets bots should never access (Hetzner token) |

### Initial token migration

After first-time setup, migrate your existing tokens from [`terraform/terraform.tfvars`](terraform/terraform.tfvars) into `pass`:

```bash
# Infrastructure (master-key only, no bot access)
pass insert infrastructure/hetzner/api-key

# Shared credentials (accessible by all bots)
pass insert shared/anthropic/api-key
pass insert shared/telegram/bot-token
pass insert shared/gemini/api-key
pass insert shared/notion/api-key
pass insert shared/perplexity/api-key

# Push to GitHub + sync to server
cd ~/.password-store && git push
make ssh
# On the server:
cd ~/.password-store && git pull
```

Each `pass insert` prompts you to paste the value. Copy them from `terraform/terraform.tfvars`.

### Adding, changing, and removing credentials

All credential changes happen on your **MacBook**, then sync to the server.

**Add a new credential:**

```bash
pass insert shared/openai/api-key        # prompts for value
pass insert bot-moltbot-01/slack/token    # bot-scoped credential
```

**Update an existing credential:**

```bash
pass insert -f shared/anthropic/api-key   # -f overwrites existing
```

**Remove a credential:**

```bash
pass rm shared/old-service/api-key
```

**View a credential:**

```bash
pass show shared/anthropic/api-key        # prints decrypted value
pass show                                 # list all entries
```

**Sync changes to the server:**

```bash
# On MacBook: push to GitHub
cd ~/.password-store && git add -A && git commit -m "Update credentials" && git push

# On server: pull changes
make ssh
cd ~/.password-store && git pull
```

Or check the server's current state from your MacBook:

```bash
make cred-status
```

### Service credential rotation

When rotating an API key for a specific service:

| Service        | Steps                                                                                                                                                           |
| -------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Anthropic**  | Generate new key at [console.anthropic.com](https://console.anthropic.com/) -> `pass insert -f shared/anthropic/api-key` -> delete old key                      |
| **OpenAI**     | Generate new key at [platform.openai.com](https://platform.openai.com/api-keys) -> `pass insert -f shared/openai/api-key` -> delete old key                     |
| **Telegram**   | @BotFather `/revoke` -> `pass insert -f shared/telegram/bot-token` -> restart bot                                                                               |
| **Hetzner**    | New token in Cloud Console -> `pass insert -f infrastructure/hetzner/api-key` -> delete old token                                                               |
| **Notion**     | Regenerate at [notion.so/my-integrations](https://www.notion.so/my-integrations) -> `pass insert -f shared/notion/api-key` -> re-share pages if new integration |
| **Gemini**     | New key at [AI Studio](https://aistudio.google.com/) -> `pass insert -f shared/gemini/api-key` -> delete old key                                                |
| **Perplexity** | New key at [perplexity.ai](https://www.perplexity.ai/) -> `pass insert -f shared/perplexity/api-key` -> delete old key                                          |

After rotating, always push and sync:

```bash
cd ~/.password-store && git add -A && git commit -m "Rotate <service> key" && git push
```

### GPG key rotation

GPG keys expire after 2 years. To rotate:

```bash
# Rotate master key (prompts for new passphrase)
./scripts/credentials-rotate.sh master

# Rotate a bot key
./scripts/credentials-rotate.sh moltbot-01
```

After rotating, re-deploy credentials to affected servers with `make setup`.

To **extend** an expiring key without rotating:

```bash
gpg --edit-key <key-id>
> expire
> 2y
> save
cd ~/.password-store && git add -A && git commit -m "Extend key expiry" && git push
```

### Backups

**Automatic:** A daily cron job runs at 03:00 on the server ([`scripts/credentials-backup.sh`](scripts/credentials-backup.sh)):

- Creates a tarball of the credential store with SHA-256 checksum
- Pushes any changes to GitHub
- Prunes backups older than 90 days
- Logs to `/var/log/credential-backup.log`

**Verify backups are running:**

```bash
make ssh
cat /var/log/credential-backup.log        # check recent backup logs
ls -la /var/backups/credentials/          # list backup tarballs
crontab -l | grep credentials             # confirm cron is registered
```

**Restore from backup (on server):**

```bash
# From a tarball
tar -xzf /var/backups/credentials/credentials-2026-02-12.tar.gz -C ~/
# Or from GitHub
cd ~/.password-store && git pull
```

**Recovery materials** (store separately, not on any server):

| Material                  | Store where               | Purpose                   |
| ------------------------- | ------------------------- | ------------------------- |
| `~/.age-recovery-key.txt` | Paper printout in safe    | Decrypts GPG key backups  |
| `~/gpg-master-backup.age` | USB drive in safe         | Encrypted master GPG key  |
| GPG passphrase            | Personal password manager | Unlocks master GPG key    |
| Backup SHA-256 hash       | Personal password manager | Verifies backup integrity |

### Fallback mode

If you decline credential setup during `./setup.sh`, tokens fall back to [`terraform/terraform.tfvars`](terraform/terraform.tfvars) (plaintext, gitignored). This is fine for getting started but less secure for production use.

## Connecting Telegram

Telegram bots can only be created manually through [@BotFather](https://t.me/BotFather) — there's no API for programmatic bot creation. This is a one-time setup that takes about 30 seconds.

### Step 1: Create the bot

1. Open [@BotFather](https://t.me/BotFather) in Telegram
2. Send `/newbot`
3. Choose a **display name** (e.g. "My OpenClaw")
4. Choose a **username** — must end in `bot` (e.g. `my_openclaw_bot`)
5. BotFather replies with a token like `110201543:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw`
6. Copy the token — you'll need it during setup

Optional but recommended:

- `/setdescription` — set a short bio visible on the bot's profile
- `/setuserpic` — give it an avatar
- `/setcommands` — define slash commands (e.g. `help - Show available commands`)

### Step 2: Store the token

If using credential management (recommended), `setup.sh` will prompt you to store it:

```bash
pass insert shared/telegram/bot-token
```

Alternatively, add it to [`terraform/terraform.tfvars`](terraform/terraform.tfvars):

```hcl
telegram_bot_token = "110201543:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw"
```

This file is gitignored. You can also set it via environment variable:

```bash
export TF_VAR_telegram_bot_token="110201543:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw"
```

### Step 3: Connect it to OpenClaw

For now, connect manually during onboarding:

```bash
make ssh
openclaw onboard --install-daemon
# → Select "Telegram"
# → Paste your bot token
```

OpenClaw stores the token in its daemon config at `~/.config/openclaw/config.json` on the server. The token persists across reboots (systemd) and `make update` (only the binary is updated, not the config).

> Cloud-init bootstrapping (auto-configuring OpenClaw on boot using the token from `terraform.tfvars`) is planned but not yet wired up.

### Step 4: Verify

After onboarding, send a message to your bot in Telegram. You should get a response from OpenClaw. You can also check the logs:

```bash
make logs   # Tail the OpenClaw daemon logs
make status # Check if the daemon is running
```

### If you reprovision the server

Running `make destroy` + `make setup` creates a fresh server. Credentials are automatically redeployed from your encrypted store — no need to manually re-enter tokens. You only need to re-run `openclaw onboard --install-daemon` to reconnect messaging platforms.

## Connecting Notion

Notion integrations can only be created manually through the [Notion developer portal](https://www.notion.so/profile/integrations) — there's no API for programmatic integration creation. This is a one-time setup that takes about 2 minutes.

### Step 1: Create the integration

1. Go to [notion.so/profile/integrations](https://www.notion.so/profile/integrations) (you must be a Workspace Owner)
2. Click **+ New integration**
3. Enter a name (e.g. "clawd" or "openclaw-bot")
4. Select the workspace you want the bot to access
5. Under **Capabilities**, ensure **Read content**, **Update content**, and **Insert content** are all checked
6. Click **Submit**
7. On the **Configuration** tab, copy the **Internal Integration Secret** (starts with `ntn_`)

### Step 2: Share pages with the integration

Notion integrations have **zero access by default** — you must explicitly share each top-level page or database you want the bot to read/write:

1. Open a Notion page or database you want the bot to access
2. Click the **...** menu (top-right corner)
3. Click **+ Add connections**
4. Search for your integration name (e.g. "clawd") and select it
5. Confirm access

Child pages under a shared page are automatically accessible. To give the bot access to your entire workspace, share each top-level page.

### Step 3: Store the token

If using credential management:

```bash
pass insert shared/notion/api-key
```

Or add to [`terraform/terraform.tfvars`](terraform/terraform.tfvars):

```hcl
notion_api_key = "ntn_..."
```

### Step 4: Connect it to OpenClaw

For now, connect manually during onboarding:

```bash
make ssh
openclaw onboard --install-daemon
# → When prompted for a Notion API key, paste your token
```

OpenClaw stores the token in its daemon config on the server. The token persists across reboots (systemd) and `make update` (only the binary is updated, not the config).

> Cloud-init bootstrapping (auto-configuring OpenClaw on boot using the token from `terraform.tfvars`) is planned but not yet wired up.

### Step 5: Verify

After onboarding, send a message to your bot asking it to read or create something in Notion. You can also check the logs:

```bash
make logs   # Tail the OpenClaw daemon logs
make status # Check if the daemon is running
```

## Teardown

```bash
make destroy
```

Handles delete-protection toggling, confirmation, and full resource cleanup automatically.
Pass `--yes` to skip the confirmation prompt: `./destroy.sh --yes`.

## Project Structure

```
Makefile               # Shortcuts: make ssh, make logs, make destroy, etc.
setup.sh               # One-command setup: provision + verify + deploy credentials
destroy.sh             # One-command teardown: unprotect + destroy
scripts/
├── lib.sh             # Shared helpers: colors, logging, prompts, GPG/pass utilities
├── credentials-init.sh       # One-time: bootstrap pass + GPG + age + GitHub repo
├── add-bot.sh                # Per-bot: create GPG key, scope credentials, deploy key
├── credentials-server-setup.sh  # Server-side: import keys, clone credential store
├── credentials-backup.sh     # Cron: daily backup + push + prune
└── credentials-rotate.sh     # Day-2: GPG key rotation
terraform/
├── main.tf            # Providers, SSH key generation, Hetzner resources, outputs
├── variables.tf       # Input variable definitions with defaults
├── terraform.tfvars   # Your secrets and overrides (gitignored, auto-generated by setup.sh)
├── user-data.yml      # Cloud-init: user, packages, Node.js, OpenClaw, hardening
└── .gitignore         # Excludes secrets, state, and generated SSH keys
```

## Day-to-Day Operations

Run `make` or `make help` to see all available commands:

```
  setup           Provision server and verify
  destroy         Tear down all infrastructure
  ssh             SSH into the server
  logs            Tail OpenClaw gateway logs
  status          Show OpenClaw service status
  restart         Restart the OpenClaw gateway
  update          Update OpenClaw to latest version and restart
  tunnel          Open SSH tunnel for remote gateway access (port 18789)
  add-bot         Add a new bot (usage: make add-bot NAME=mybot)
  rotate-key      Rotate a GPG key (usage: make rotate-key TARGET=master)
  cred-status     Show credential store status on server
```

## API Tokens

With credential management enabled, all secrets live in `pass` (GPG-encrypted, backed by a private GitHub repo). The `setup.sh` script reads tokens from `pass` and populates [`terraform/terraform.tfvars`](terraform/terraform.tfvars) automatically.

Without credential management, secrets live directly in `terraform.tfvars` (gitignored, never committed).

| Variable             | Required | Source                                                                                                          |
| -------------------- | -------- | --------------------------------------------------------------------------------------------------------------- |
| `hcloud_token`       | Yes      | [Hetzner Console](https://console.hetzner.cloud/) > Project > API tokens                                        |
| `telegram_bot_token` | No       | [@BotFather](https://t.me/BotFather) on Telegram (see [Connecting Telegram](#connecting-telegram))              |
| `anthropic_api_key`  | No       | [Anthropic Console](https://console.anthropic.com/) > API keys                                                  |
| `gemini_api_key`     | No       | [Google AI Studio](https://aistudio.google.com/) > API keys                                                     |
| `notion_api_key`     | No       | [Notion Integrations](https://www.notion.so/profile/integrations) (see [Connecting Notion](#connecting-notion)) |
| `perplexity_api_key` | No       | [Perplexity](https://www.perplexity.ai/) > API keys                                                             |

All can also be set via environment variables (prefix with `TF_VAR_`, e.g. `TF_VAR_hcloud_token`).

## How setup.sh Works

For reference, here's what the setup script automates:

1. **Checks prerequisites** — Terraform >= 1.5, SSH
2. **Credential infrastructure** (first run) — installs `pass`, GPG, `age`; generates master key; creates GitHub repo; bootstraps encrypted credential store
3. **Bot credentials** (first run) — generates per-bot GPG key, scopes credential access, creates deploy key
4. **Resolves tokens** — reads from `pass` -> env vars -> `terraform.tfvars` -> interactive prompt (in that order)
5. **Generates/updates `terraform/terraform.tfvars`** — safely updates existing values, never deletes keys
6. **Runs `terraform init`** (skips if already initialized)
7. **Runs `terraform apply`** — creates SSH keypair, firewall, and cpx23 server with Ubuntu 24.04
8. **Waits for cloud-init** (~2-3 min) — polls until Node.js 22, OpenClaw, fail2ban, swap, and SSH hardening are all in place
9. **Deploys credentials to server** — SCPs encrypted key bundle + deploy key, imports GPG keys, clones credential store
10. **Deploys backup cron** — daily credential backup at 03:00
11. **Runs full verification** — checks every component including credential access

## Security

The following hardening is applied automatically via cloud-init:

- **SSH**: Root login disabled, password authentication disabled (key-only)
- **Firewall**: Only port 22 (SSH) is open; the OpenClaw gateway is only accessible via SSH tunnel
- **fail2ban**: Monitors and bans IPs with repeated failed SSH login attempts
- **unattended-upgrades**: Automatically installs security patches
- **Swap**: 1 GB swap file as OOM safety net
- **Server protection**: Delete and rebuild protection enabled (handled automatically by `destroy.sh` during teardown)
- **Credential isolation**: Per-bot GPG keys ensure one compromised server cannot decrypt another bot's secrets
- **Key material safety**: GPG keys are imported via tmpfs on the server and never touch persistent disk

### Note on SSH keys in Terraform state

The SSH private key is stored in Terraform's local state file (`terraform.tfstate`). This is acceptable for a personal project with local state. If you ever move to a remote backend (e.g., S3, Terraform Cloud), consider using a separate key management approach instead.

## Recovery Procedures

### New bot server

1. Run `make add-bot NAME=<name>` on your MacBook
2. Run `make setup` — credentials are deployed automatically

### Single bot compromised

1. Kill the server (Hetzner Console -> Power Off)
2. `./scripts/credentials-rotate.sh <bot-name>` on your MacBook
3. Rotate all credentials the bot had access to (its scope + shared)
4. Remove old deploy key from GitHub
5. Reprovision: `make setup`

### Everything compromised (nuclear)

1. Get `age` backup from USB in safe
2. Get `age` identity from paper printout
3. On a clean machine: `age -d -i <identity> <backup.age> | gpg --import`
4. Clone credential repo: `git clone ... ~/.password-store`
5. Rotate **everything**: master key, all bot keys, all credentials, new GitHub repo
6. Estimated time: ~4-6 hours

### Maintenance schedule

| When              | What                                                |
| ----------------- | --------------------------------------------------- |
| Daily (automated) | `credentials-backup.sh` via cron on server          |
| Monthly           | Review `/var/log/credential-backup.log`             |
| Quarterly         | Recovery drill: bootstrap a throwaway VM            |
| Annually          | `./scripts/credentials-rotate.sh master` + all bots |
