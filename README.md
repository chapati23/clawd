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

## Quick Start

```bash
git clone <repo-url> && cd clawd
export HCLOUD_TOKEN="your-hetzner-api-token"
./setup.sh
```

That's it. The script handles everything: Terraform init, provisioning, waiting for cloud-init, verification, and SSH host key registration. At the end, SSH in and run the one manual step — OpenClaw onboarding:

```bash
make ssh
openclaw onboard --install-daemon
```

The onboarding wizard walks you through connecting messaging platforms (Telegram, WhatsApp, Discord, etc.) and installs OpenClaw as a system daemon so it survives reboots.

## Connecting Telegram

Telegram bots can only be created manually through [@BotFather](https://t.me/BotFather) — there's no API for programmatic bot creation. This is a one-time setup that takes about 30 seconds.

### Step 1: Create the bot

1. Open [@BotFather](https://t.me/BotFather) in Telegram
2. Send `/newbot`
3. Choose a **display name** (e.g. "My OpenClaw")
4. Choose a **username** — must end in `bot` (e.g. `my_openclaw_bot`)
5. BotFather replies with a token like `110201543:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw`
6. Copy the token — you'll need it during onboarding

Optional but recommended:

- `/setdescription` — set a short bio visible on the bot's profile
- `/setuserpic` — give it an avatar
- `/setcommands` — define slash commands (e.g. `help - Show available commands`)

### Step 2: Store the token

Add your bot token to [`terraform/terraform.tfvars`](terraform/terraform.tfvars):

```hcl
telegram_bot_token = "110201543:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw"
```

This file is gitignored — your token never leaves your machine. Alternatively, set it via environment variable:

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

Running `make destroy` + `make setup` creates a fresh server. You'll need to re-run `openclaw onboard --install-daemon` and paste the bot token again. The bot itself (and its token) stays valid — you don't need to create a new one via BotFather. Since the token is saved in `terraform.tfvars`, you can just copy it from there.

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

Add your integration token to [`terraform/terraform.tfvars`](terraform/terraform.tfvars):

```hcl
notion_api_key = "ntn_..."
```

This file is gitignored — your token never leaves your machine. Alternatively, set it via environment variable:

```bash
export TF_VAR_notion_api_key="ntn_..."
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

### If you reprovision the server

Running `make destroy` + `make setup` creates a fresh server. You'll need to re-run `openclaw onboard --install-daemon` and paste the Notion token again. The integration itself stays valid — you don't need to create a new one in Notion. Since the token is saved in `terraform.tfvars`, you can just copy it from there.

## Teardown

```bash
make destroy
```

Handles delete-protection toggling, confirmation, and full resource cleanup automatically.
Pass `--yes` to skip the confirmation prompt: `./destroy.sh --yes`.

## Project Structure

```
Makefile               # Shortcuts: make ssh, make logs, make destroy, etc.
setup.sh               # One-command setup: provision + verify
destroy.sh             # One-command teardown: unprotect + destroy
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
```

## API Tokens

All secrets live in [`terraform/terraform.tfvars`](terraform/terraform.tfvars) (gitignored, never committed). The file is auto-generated by `setup.sh` on first run, and you fill in the optional tokens afterward.

| Variable             | Required | Source                                                                                                          |
| -------------------- | -------- | --------------------------------------------------------------------------------------------------------------- |
| `hcloud_token`       | Yes      | [Hetzner Console](https://console.hetzner.cloud/) > Project > API tokens                                        |
| `telegram_bot_token` | No       | [@BotFather](https://t.me/BotFather) on Telegram (see [Connecting Telegram](#connecting-telegram))              |
| `anthropic_api_key`  | No       | [Anthropic Console](https://console.anthropic.com/) > API keys                                                  |
| `notion_api_key`     | No       | [Notion Integrations](https://www.notion.so/profile/integrations) (see [Connecting Notion](#connecting-notion)) |

All four can also be set via environment variables (`TF_VAR_hcloud_token`, `TF_VAR_telegram_bot_token`, `TF_VAR_anthropic_api_key`, `TF_VAR_notion_api_key`).

The Telegram, Anthropic, and Notion tokens are optional — if left empty, the server provisions normally and you configure OpenClaw manually via `openclaw onboard`. When cloud-init bootstrapping is wired up, filling them in will skip the manual onboarding step entirely.

## How setup.sh Works

For reference, here's what the setup script automates:

1. **Checks prerequisites** — Terraform >= 1.5, SSH
2. **Resolves the Hetzner token** — checks `HCLOUD_TOKEN`, `TF_VAR_hcloud_token`, existing `terraform.tfvars`, or prompts interactively
3. **Generates `terraform/terraform.tfvars`** if it doesn't exist
4. **Runs `terraform init`** (skips if already initialized)
5. **Runs `terraform apply`** — creates SSH keypair, firewall, and cx23 server with Ubuntu 24.04
6. **Waits for cloud-init** (~2-3 min) — polls until Node.js 22, OpenClaw, fail2ban, swap, and SSH hardening are all in place
7. **Runs full verification** — checks every component and reports pass/fail

## Security

The following hardening is applied automatically via cloud-init:

- **SSH**: Root login disabled, password authentication disabled (key-only)
- **Firewall**: Only port 22 (SSH) is open; the OpenClaw gateway is only accessible via SSH tunnel
- **fail2ban**: Monitors and bans IPs with repeated failed SSH login attempts
- **unattended-upgrades**: Automatically installs security patches
- **Swap**: 1 GB swap file as OOM safety net
- **Server protection**: Delete and rebuild protection enabled (handled automatically by `destroy.sh` during teardown)

### Note on SSH keys in Terraform state

The SSH private key is stored in Terraform's local state file (`terraform.tfstate`). This is acceptable for a personal project with local state. If you ever move to a remote backend (e.g., S3, Terraform Cloud), consider using a separate key management approach instead.
