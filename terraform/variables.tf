variable "hcloud_token" {
  type        = string
  sensitive   = true
  description = "Hetzner Cloud API token. Prefer setting via TF_VAR_hcloud_token env var."
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key to authorize on the server (ed25519 or RSA)."
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
  default     = "cx22"
  description = "Hetzner server type. cx22 = 2 vCPU, 4 GB RAM, 40 GB SSD (shared)."
}
