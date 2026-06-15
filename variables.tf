variable "hcloud_token" {
  description = "Hetzner Cloud API token"
  type        = string
  sensitive   = true
}

variable "ssh_public_key_path" {
  description = "Path to your SSH public key"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "username" {
  description = "Non-root user to create on the server"
  type        = string
  default     = "derick"
}

variable "server_type" {
  description = "Hetzner server type (e.g. cpx31, cpx41)"
  type        = string
  default     = "cpx31"
}

variable "location" {
  description = "Hetzner datacenter location (e.g. ash, hil, fsn1, nbg1)"
  type        = string
  default     = "ash"
}

variable "tailscale_auth_key" {
  description = "Tailscale auth key for automatic device registration (generate at https://login.tailscale.com/admin/settings/keys)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "github_token" {
  description = "GitHub PAT (fine-grained, repo-scoped, with expiry) for headless `gh` auth so private repos can be cloned. Leave empty to run `gh auth login` manually after deploy."
  type        = string
  sensitive   = true
  default     = ""
}
