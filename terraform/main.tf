terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.60"
    }
  }

  required_version = ">= 1.5.0"
}

provider "hcloud" {
  token = var.hcloud_token
}

locals {
  user_data = templatefile("${path.module}/user-data.yml", {
    SSH_PUBLIC_KEY = var.ssh_public_key
  })
}

# ──────────────────────────────────────────────
# SSH key
# ──────────────────────────────────────────────

resource "hcloud_ssh_key" "me" {
  name       = "openclaw-key"
  public_key = var.ssh_public_key
}

# ──────────────────────────────────────────────
# Firewall — SSH only (gateway uses SSH tunnel)
# ──────────────────────────────────────────────

resource "hcloud_firewall" "openclaw_fw" {
  name = "openclaw-fw"

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  apply_to {
    label_selector = "role=openclaw"
  }
}

# ──────────────────────────────────────────────
# Server
# ──────────────────────────────────────────────

resource "hcloud_server" "openclaw" {
  name        = var.server_name
  server_type = var.server_type
  image       = "ubuntu-24.04"
  location    = var.location

  ssh_keys = [hcloud_ssh_key.me.id]

  labels = {
    role = "openclaw"
  }

  user_data = local.user_data
}

# ──────────────────────────────────────────────
# Outputs
# ──────────────────────────────────────────────

output "server_ip" {
  value       = hcloud_server.openclaw.ipv4_address
  description = "Public IPv4 address of the OpenClaw server."
}

output "ssh_command" {
  value       = "ssh molt@${hcloud_server.openclaw.ipv4_address}"
  description = "SSH command to connect to the server."
}
