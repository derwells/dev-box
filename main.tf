terraform {
  required_version = ">= 1.6.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.49"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}

resource "hcloud_ssh_key" "main" {
  name       = "dev-box"
  public_key = file(var.ssh_public_key_path)
}

resource "hcloud_firewall" "dev_box" {
  name = "dev-box"

  # SSH — only needed for initial setup before Tailscale is running.
  # Can be removed once Tailscale is confirmed working.
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # Allow all outbound (updates, Tailscale DERP, etc.)
  rule {
    direction       = "out"
    protocol        = "tcp"
    port            = "any"
    destination_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction       = "out"
    protocol        = "udp"
    port            = "any"
    destination_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction       = "out"
    protocol        = "icmp"
    destination_ips = ["0.0.0.0/0", "::/0"]
  }
}

resource "hcloud_server" "dev_box" {
  name        = "dev-box"
  server_type = var.server_type
  image       = "ubuntu-24.04"
  location    = var.location
  ssh_keys    = [hcloud_ssh_key.main.id]
  firewall_ids = [hcloud_firewall.dev_box.id]

  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    username       = var.username
    tailscale_auth_key = var.tailscale_auth_key
    github_token       = var.github_token
  })

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }
}
