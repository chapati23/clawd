# Migration Guide: Add Syncthing to Existing Servers

This guide is for **existing servers** (e.g., Giskard's current `moltbot-01`). New servers get Syncthing automatically via cloud-init — see [README.md](README.md#syncthing--obsidian-sync).

## Prerequisites

- SSH access to the server (`make ssh`)
- The Terraform firewall changes from this PR have been applied (`terraform apply`)

## Step 1: Apply Firewall Rules

On your **MacBook**, apply the updated Terraform config to open Syncthing ports:

```bash
cd clawd/terraform
terraform apply
```

This adds two new firewall rules:

- **22000/TCP** — Syncthing data transfer
- **21027/UDP** — Syncthing local/global discovery

## Step 2: Install Syncthing on the Server

SSH into the server and install from the official apt repo:

```bash
make ssh
```

Then on the server:

```bash
# Add the official Syncthing apt repository
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://syncthing.net/release-key.gpg | sudo gpg --dearmor -o /etc/apt/keyrings/syncthing.gpg
echo "deb [signed-by=/etc/apt/keyrings/syncthing.gpg] https://apt.syncthing.net/ syncthing stable" \
  | sudo tee /etc/apt/sources.list.d/syncthing.list > /dev/null

sudo apt-get update
sudo apt-get install -y syncthing
```

## Step 3: Enable Syncthing as a User Service

```bash
# Enable lingering so the service runs without an active login session
sudo loginctl enable-linger molt

# Enable and start Syncthing
systemctl --user enable syncthing.service
systemctl --user start syncthing.service

# Verify it's running
systemctl --user status syncthing.service
```

## Step 4: Create .stignore

Create the ignore file in the workspace directory to hide agent internals:

```bash
cat > ~/.openclaw/workspace/.stignore << 'EOF'
// Syncthing ignore patterns — agent internals Philip doesn't need to see
.git
.gitignore
node_modules
__pycache__
*.pyc
.clawhub
.openclaw
*.log
scripts/
EOF
```

## Step 5: Create Obsidian Vault Structure

```bash
# Create vault directories
mkdir -p ~/.openclaw/workspace/.obsidian/plugins
mkdir -p ~/.openclaw/workspace/00-inbox
mkdir -p ~/.openclaw/workspace/research
mkdir -p ~/.openclaw/workspace/templates

# Community plugins config
cat > ~/.openclaw/workspace/.obsidian/community-plugins.json << 'EOF'
[
  "obsidian-kanban",
  "dataview",
  "templater-obsidian",
  "calendar",
  "obsidian-git"
]
EOF

# Obsidian app settings
cat > ~/.openclaw/workspace/.obsidian/app.json << 'EOF'
{
  "newFileLocation": "folder",
  "newFileFolderPath": "00-inbox",
  "attachmentFolderPath": "artifacts",
  "alwaysUpdateLinks": true,
  "showLineNumber": true,
  "strictLineBreaks": false
}
EOF

# Templates
cat > ~/.openclaw/workspace/templates/daily-note.md << 'EOF'
# {{date:YYYY-MM-DD}} — {{date:dddd}}

## Summary

## Key Decisions

## Tasks
- [ ]

## Notes

EOF

cat > ~/.openclaw/workspace/templates/research.md << 'EOF'
# Research: {{title}}

**Date:** {{date:YYYY-MM-DD}}
**Status:** draft | in-progress | complete

## Objective

## Sources

## Findings

## Conclusions

EOF

cat > ~/.openclaw/workspace/templates/project.md << 'EOF'
# Project: {{title}}

**Created:** {{date:YYYY-MM-DD}}
**Status:** ideation | spec | design | implementation | qa | deployed

## Overview

## Requirements

## Architecture

## Progress

## Links

EOF
```

## Step 6: Get Device ID and Pair

Run the setup helper:

```bash
~/scripts/syncthing-setup.sh
```

Or get the device ID directly:

```bash
syncthing -device-id
```

Access the web UI via SSH tunnel:

```bash
# On your MacBook:
ssh -i terraform/id_ed25519 -L 8384:127.0.0.1:8384 molt@<server-ip>
# Then open: http://127.0.0.1:8384
```

## Step 7: Pair with Your Devices

### Mac

1. Install Syncthing on your Mac (`brew install syncthing`)
2. Add the server as a remote device using its Device ID
3. Share the workspace folder (path: `~/.openclaw/workspace`, folder ID: `openclaw-workspace`)
4. Accept the share on your device and point it to your local Obsidian vault directory

### iPhone (SyncTrain)

> ⚠️ iOS setup has several gotchas — read carefully.

1. Install **SyncTrain** from the App Store
2. **Bidirectional pairing required:** Add devices on BOTH sides:
   - Mac Syncthing: Add Remote Device → paste iPhone's device ID
   - SyncTrain on iPhone: Add Device → paste Mac's device ID
   - ⚠️ Both must add each other or they won't connect
3. On Mac Syncthing: edit the shared folder → Sharing tab → check the iPhone
4. On iPhone in SyncTrain: go to **Folders** tab → tap the folder under **"Discovered folders"** to add it (it won't auto-accept)
5. ⚠️ **Change sync mode to "All files"** — default "Selected files" syncs nothing
6. ⚠️ **Keep SyncTrain in foreground** for initial sync — iOS suspends background network (0 B/s otherwise)
7. After sync completes, open the synced folder as an Obsidian vault

## Verification

```bash
# Syncthing running?
systemctl --user status syncthing.service

# Device ID?
syncthing -device-id

# .stignore in place?
cat ~/.openclaw/workspace/.stignore

# Obsidian config?
ls ~/.openclaw/workspace/.obsidian/

# Firewall rules applied?
# Check Hetzner Console or: terraform -chdir=terraform show | grep -A5 "22000"
```
