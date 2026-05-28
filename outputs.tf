output "server_ip" {
  description = "Public IPv4 address (use for initial SSH before Tailscale is up)"
  value       = hcloud_server.dev_box.ipv4_address
}

output "server_status" {
  description = "Server status"
  value       = hcloud_server.dev_box.status
}

output "ssh_command" {
  description = "SSH command to connect (before Tailscale)"
  value       = "ssh ${var.username}@${hcloud_server.dev_box.ipv4_address}"
}
