variable "hcloud_token" {
  type        = string
  sensitive   = true
  description = "Hetzner Cloud API token. Prefer setting via TF_VAR_hcloud_token env var."
}

variable "server_name" {
  type        = string
  default     = "moltbot-01"
  description = "Name of the Hetzner Cloud server."
}

variable "location" {
  type        = string
  default     = "nbg1"
  description = "Hetzner datacenter location (nbg1 = Nuremberg, fsn1 = Falkenstein, hel1 = Helsinki)."
}

variable "server_type" {
  type        = string
  default     = "cx32"
  description = "Hetzner server type. cx32 = 4 vCPU (x86), 8 GB RAM, 80 GB SSD (shared, Gen3)."
}

variable "enable_protection" {
  type        = bool
  default     = true
  description = "Enable delete/rebuild protection on the server. Set to false for teardown."
}

# ──────────────────────────────────────────────
# API tokens (optional — for cloud-init bootstrapping)
# ──────────────────────────────────────────────

variable "anthropic_api_key" {
  type        = string
  sensitive   = true
  default     = ""
  description = "Anthropic API key. Used to auto-configure OpenClaw on boot."
}

variable "gemini_api_key" {
  type        = string
  sensitive   = true
  default     = ""
  description = "Gemini API key. Used to auto-configure OpenClaw on boot."
}

variable "notion_api_key" {
  type        = string
  sensitive   = true
  default     = ""
  description = "Notion internal integration token. Used to auto-configure OpenClaw on boot."
}

variable "perplexity_api_key" {
  type        = string
  sensitive   = true
  default     = ""
  description = "Perplexity API key. Used to auto-configure OpenClaw on boot."
}

variable "telegram_bot_token" {
  type        = string
  sensitive   = true
  default     = ""
  description = "Telegram bot token from @BotFather. Used to auto-configure OpenClaw on boot."
}

variable "openclaw_version" {
  type        = string
  default     = "latest"
  description = "OpenClaw version to install. Pin to a specific version (e.g. '1.2.3') for reproducible builds."
}
