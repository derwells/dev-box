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
  name         = "dev-box"
  server_type  = var.server_type
  image        = "ubuntu-24.04"
  location     = var.location
  ssh_keys     = [hcloud_ssh_key.main.id]
  firewall_ids = [hcloud_firewall.dev_box.id]

  # Bootstrap only — Hetzner caps user_data at 32KiB, so the bulk of the
  # provisioning runs via setup.sh over SSH (provisioners below).
  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    username           = var.username
    ssh_public_key     = trimspace(file(var.ssh_public_key_path))
    tailscale_auth_key = var.tailscale_auth_key
    github_token       = var.github_token
  })

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  # Hetzner installs the SSH key for root, so provisioners connect as root
  # even though day-to-day access is the non-root user Tailscale SSH.
  connection {
    type        = "ssh"
    user        = "root"
    private_key = file(var.ssh_private_key_path)
    host        = self.ipv4_address
  }

  # Static provisioning payload (configs, skills, the gwsa tool — no secrets).
  provisioner "remote-exec" {
    inline = ["mkdir -p /root/provision"]
  }

  provisioner "file" {
    source      = "${path.module}/files/"
    destination = "/root/provision"
  }

  provisioner "file" {
    source      = "${path.module}/setup.sh"
    destination = "/root/setup.sh"
  }

  provisioner "remote-exec" {
    inline = [
      # cloud-init must finish first (user, packages, tailscale, ufw).
      # Exit 2 = "done with recoverable warnings" — acceptable.
      "cloud-init status --wait >/dev/null || [ $? -eq 2 ]",
      "bash /root/setup.sh '${var.username}' '${var.git_user_name}' '${var.git_user_email}'",
    ]
  }
}
