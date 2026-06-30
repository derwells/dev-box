# Dev Box

Remote development server provisioned with OpenTofu on Hetzner Cloud. One command to create, one to destroy.

## Stack

- **Infrastructure:** OpenTofu with `hetznercloud/hcloud` provider
- **Server:** Hetzner CPX31 (4 vCPU, 8GB RAM, Ubuntu 24.04)
- **Networking:** Tailscale mesh (no public ports except SSH fallback)
- **Provisioning:** cloud-init via `cloud-init.yaml.tftpl` (templatefile)
- **Desktop:** XFCE4 + TigerVNC + noVNC for browser-based visual verification

## Files

- `main.tf` — server, SSH key, firewall resources
- `variables.tf` — all configurable inputs
- `outputs.tf` — public IP, SSH command after deploy
- `cloud-init.yaml.tftpl` — full server provisioning (Tailscale, Node.js, Claude Code, GSD, Playwright, desktop env)
- `terraform.tfvars` — secrets (gitignored)
- `terraform.tfvars.example` — template for secrets

## Commands

```bash
tofu init          # install providers
tofu plan          # preview changes
tofu apply         # create/update server
tofu destroy       # tear down everything
hcloud server list # check server status via Hetzner CLI
hcloud server ssh dev-box # SSH via hcloud (requires hcloud context)
```

## Post-deploy login (one-time on server)

```bash
gh auth login      # GitHub auth — SKIP if github_token is set in tfvars (gh is auto-authed at provision)
claude login       # Claude Code auth (headless URL flow)
```

Set `github_token` in `terraform.tfvars` (fine-grained, repo-scoped PAT) to clone private repos without an interactive login. The token lands in cloud-init user-data, so scope it tightly and rotate it.

`claudex` is a provisioned wrapper that runs Claude Code against Xiaomi MiMo (token plan): Opus → `mimo-v2.5-pro`, Sonnet/Haiku → `mimo-v2.5`. It reads the key from `MIMO_API_KEY` or `~/.claude/mimo_token` (add it manually post-deploy — never in tfvars). Plain `claude` stays on Anthropic.

## Conventions

- Use OpenTofu, not Terraform
- Secrets go in `terraform.tfvars` (gitignored), never hardcoded
- Server config goes in `cloud-init.yaml.tftpl`, not in separate scripts
- Keep it single-server simple — no modules, no workspaces
