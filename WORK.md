# Server Upgrade: cx23 → cx32 — Migration Plan

## ⚠️ CRITICAL: Do NOT just `terraform apply`

Terraform treats `server_type` changes as **destroy + recreate**, which would **wipe all data**. We must rescale via Hetzner API/Console first, then sync Terraform state.

## What Lives on This Server (State Inventory)

### Critical (irreplaceable without backup)
| Item | Location | Backed Up? |
|------|----------|------------|
| OpenClaw config | `~/.openclaw/openclaw.json` | ❌ Not in git |
| OpenClaw identity/auth | `~/.openclaw/identity/` | ❌ Not in git |
| Subagent run history | `~/.openclaw/subagents/runs.json` | ❌ Not in git |
| Cron job definitions | OpenClaw internal state | ❌ In memory/config |
| GPG keys | `~/.gnupg/` | ❌ Local only |
| SSH keys | `~/.ssh/` (github_giskard, github-deploy) | ❌ Local only |
| Password store | `~/.password-store/` (1.2 MB) | ✅ GitHub private repo |
| Credential backup cron | System crontab (`0 3 * * *`) | ❌ Set up by setup.sh |

### Important (in git, recoverable)
| Item | Location | Backed Up? |
|------|----------|------------|
| Workspace (memory, skills, etc.) | `~/.openclaw/workspace/` | ✅ Git (chapati23/Giskard) |
| Custom skills | `~/.openclaw/workspace/skills/` | ✅ Git |
| Memory files | `~/.openclaw/workspace/memory/` | ✅ Git |
| MEMORY.md, AGENTS.md, etc. | `~/.openclaw/workspace/` | ✅ Git |

### Recreatable (from setup.sh / cloud-init)
| Item | How to Recreate |
|------|----------------|
| Node.js, npm, OpenClaw | cloud-init / `npm i -g openclaw` |
| Playwright + Chromium | `npx playwright install chromium` |
| systemd user service | `openclaw onboard --install-daemon` |
| fail2ban, ufw, etc. | cloud-init |

## Safe Migration Procedure

### Step 1: Pre-flight Backup (on server, ~2 min)

```bash
# 1a. Push workspace to git
cd ~/.openclaw/workspace && git add -A && git commit -m "pre-upgrade backup" && git push

# 1b. Backup OpenClaw config + identity (NOT in git)
tar czf /tmp/openclaw-state-backup.tar.gz \
  ~/.openclaw/openclaw.json \
  ~/.openclaw/openclaw.json.bak* \
  ~/.openclaw/identity/ \
  ~/.openclaw/subagents/ \
  ~/.openclaw/devices/ \
  ~/.openclaw/update-check.json

# 1c. Backup GPG + SSH keys
tar czf /tmp/keys-backup.tar.gz \
  ~/.gnupg/ \
  ~/.ssh/

# 1d. Download backups to your Mac
scp molt@<server-ip>:/tmp/openclaw-state-backup.tar.gz ~/Desktop/
scp molt@<server-ip>:/tmp/keys-backup.tar.gz ~/Desktop/

# 1e. Verify credential store is pushed
cd ~/.password-store && git status  # should be clean
```

### Step 2: Rescale via Hetzner Console (~3 min downtime)

**Do this in the Hetzner Cloud Console (console.hetzner.cloud), NOT via Terraform:**

1. Go to your project → Servers → moltbot-01
2. Click **Power** → **Power Off** (wait for it to stop)
3. Click **Rescale** in the left sidebar
4. Select **CX32** (4 vCPU, 8 GB, 80 GB)
5. **IMPORTANT:** Leave "Resize disk" CHECKED (to get 80 GB disk)
6. Click **Rescale** (red button)
7. Server auto-restarts after rescale

### Step 3: Post-Rescale Disk Resize (if needed)

Hetzner may not auto-expand the partition. After the server is back up:

```bash
ssh molt@<server-ip>

# Check current disk
df -h /
# If still showing ~38G, need to resize:

# For ext4 (most likely):
sudo growpart /dev/sda 1
sudo resize2fs /dev/sda1

# Verify
df -h /  # Should now show ~78G
free -h   # Should show ~7.7 GB
nproc     # Should show 4
```

### Step 4: Verify Everything Works

```bash
# OpenClaw running?
DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus systemctl --user status openclaw-gateway

# If not running, start it:
DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus systemctl --user start openclaw-gateway

# Test Telegram bot responds
# Check cron jobs still exist (they're in OpenClaw's internal state, should persist)
# Verify workspace intact
ls ~/.openclaw/workspace/MEMORY.md
```

### Step 5: Sync Terraform State

On your Mac, after the rescale is confirmed working:

```bash
cd clawd/terraform

# Import the new server type into Terraform state
terraform refresh

# Now update variables.tf to match reality (cx23 → cx32)
# This is what the PR already does

# Verify no diff
terraform plan
# Should show: "No changes. Infrastructure is up-to-date."
```

Then merge the PR.

## What Could Go Wrong

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Disk doesn't auto-expand | Medium | Manual growpart + resize2fs (Step 3) |
| OpenClaw doesn't restart | Low | systemctl --user start, check logs |
| Cron jobs lost | Very Low | OpenClaw stores in config, survives reboot |
| SSH keys broken | None | Keys are on disk, preserved by rescale |
| Partition table issues | Very Low | Hetzner Rescue System available |

## Total Downtime Estimate

- Power off: ~30 seconds
- Rescale: ~1-2 minutes
- Boot + disk resize: ~1-2 minutes
- **Total: ~3-5 minutes**

## Summary

1. **Backup** (safety net — data is preserved, but always backup)
2. **Rescale in Console** (NOT terraform apply)
3. **Resize disk** if needed
4. **Verify** OpenClaw + Telegram
5. **Sync Terraform** state + merge PR
