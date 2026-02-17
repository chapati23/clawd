# Server Upgrade: CAX21 (8 GB RAM)

## Context

Philip requested an upgrade from the current server plan to **CAX21** to handle multiple parallel OpenClaw sessions better. Currently experiencing slowdowns when running 2-3 sessions in parallel due to memory pressure.

**Current Situation:**
- Server: moltbot-01
- Resources: 2 vCPU, ~3.8 GB RAM, x86_64 architecture
- Issue: Hitting memory limits with parallel sessions (touching swap)
- Gateway process: ~717 MB resident, each session adds 300-500 MB

**Target Plan:**
- **CAX21**: 4 vCPU (ARM64), 8 GB RAM, 80 GB SSD
- Cost: €8.46/month (vs current ~€4.23/month for CAX11 or ~€5.83/month for CX22)
- Benefit: 2x RAM, 2x CPU, better parallel session handling

## Important Decision Point ⚠️

**Current server is x86_64 (`uname -m` shows x86_64).**
**CAX21 is ARM64 architecture.**

**This means:**
1. **Cannot do in-place resize** — requires full rebuild
2. **Potential compatibility issues** with OpenClaw or dependencies on ARM
3. **Alternative option**: Upgrade to CX32 (x86, 4 vCPU, 8 GB RAM, €11.66/month) for safer in-place upgrade

**Question for Philip:**
- Do you want CAX21 (ARM, cheaper, requires rebuild + compatibility check)?
- Or CX32 (x86, more expensive, safer in-place upgrade)?

## Implementation Tasks

### Option A: CAX21 (ARM64, requires rebuild)

1. **Update Terraform config:**
   - File: `terraform/variables.tf`
   - Change: `default = "cx23"` → `default = "cax21"`
   - Update description to: `"cax21 = 4 vCPU (ARM64), 8 GB RAM, 80 GB SSD (Ampere Altra, dedicated)"`

2. **Verify cloud-init compatibility:**
   - File: `terraform/user-data.yml`
   - Check: OpenClaw install script (`npm install -g openclaw@${OPENCLAW_VERSION}`) should work on ARM64
   - Node.js supports ARM64, so likely fine
   - Check any binary dependencies in OpenClaw (Playwright, etc.)

3. **Plan the migration:**
   - This will **destroy and recreate** the server
   - Need to backup: 
     - `~/.openclaw/workspace/` (git push before destroy)
     - `~/.openclaw/config/` (git push clawd config)
     - Credential store (already backed up to GitHub)
   - Downtime: ~10-15 minutes

4. **Update README:**
   - Document the server type change
   - Note ARM64 architecture
   - Update cost estimate

### Option B: CX32 (x86_64, in-place upgrade)

1. **Update Terraform config:**
   - File: `terraform/variables.tf`
   - Change: `default = "cx23"` → `default = "cx32"`
   - Update description to: `"cx32 = 4 vCPU, 8 GB RAM, 80 GB SSD (shared, Gen3)"`

2. **Check if Hetzner allows in-place upgrade:**
   - Some server types allow resize without rebuild
   - If not, same migration steps as Option A

3. **Update README:**
   - Document the server type change
   - Update cost estimate

## Testing Checklist

After upgrade (either option):

- [ ] SSH access works
- [ ] OpenClaw gateway starts: `systemctl status openclaw-gateway`
- [ ] Workspace git repo intact: `ls ~/.openclaw/workspace/`
- [ ] Telegram bot responds
- [ ] Spawn 3 parallel sessions and check memory: `free -h`
- [ ] Verify no swap usage under load
- [ ] Check process memory: `ps aux | grep openclaw-gateway`

## Files to Modify

- `terraform/variables.tf` - Update `server_type` default
- `README.md` - Update server specs and cost info
- This file (`WORK.md`) - Delete after completion

## Cost Impact

- Current: ~€4-6/month
- CAX21: €8.46/month (+€3-4/month)
- CX32: €11.66/month (+€6-8/month)

Philip approved the upgrade for better performance with parallel sessions.

---

## Next Steps

1. **Philip**: Decide CAX21 (ARM, cheaper) vs CX32 (x86, safer)
2. **Claude Code**: Implement the chosen option
3. **Giskard**: Backup workspace, run `terraform apply`, verify post-upgrade
