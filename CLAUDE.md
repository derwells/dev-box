# Dev Box

Remote development server provisioned with OpenTofu on Hetzner Cloud. One command to create, one to destroy.

## Stack

- **Infrastructure:** OpenTofu with `hetznercloud/hcloud` provider
- **Server:** Hetzner CPX31 (4 vCPU, 8GB RAM, Ubuntu 24.04)
- **Networking:** Tailscale mesh (no public ports except SSH fallback)
- **Provisioning:** cloud-init via `cloud-init.yaml.tftpl` (templatefile)
- **Desktop:** XFCE4 + TigerVNC + noVNC for browser-based visual verification
- **Shell:** zsh (login shell) + oh-my-zsh + Starship, tmux auto-attach to session `main`

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

`claudex` is a provisioned wrapper that runs Claude Code against Xiaomi MiMo: all tiers (Opus/Sonnet/Haiku) → `mimo-v2.5` (`mimo-v2.5-pro` is deliberately unmapped). Default backend is the token plan (`MIMO_API_KEY` or `~/.claude/mimo_token`; add manually post-deploy — never in tfvars). When the plan runs out it can fall back to pay-as-you-go (`https://api.xiaomimimo.com/anthropic`, same `sk-...` key as the search bridge): `claudex --paygo`, `CLAUDEX_BACKEND=paygo`, or persistently via `echo paygo > ~/.claude/claudex_backend` (flag > env > file; auto-falls back if no plan token exists). Plain `claude` stays on Anthropic.

Web search under `claudex` goes through a provisioned MCP bridge (`~/.claude/mimo-search-mcp.mjs` + `search_mcp.json`) that calls MiMo's pay-as-you-go search plugin — Claude Code's built-in `WebSearch` is Anthropic-only and doesn't work via MiMo. The bridge is dormant until you add a separate PAYG key at `~/.claude/mimo_paygo_token` (`sk-...`, billed outside the token plan). When present, `claudex` loads the bridge and disables the built-in `WebSearch`.

A `/claudex` **skill** ships alongside the wrapper (`~/.claude/skills/claudex/SKILL.md`, registered in `~/.claude/CLAUDE.md`). It teaches the main Claude Code agent to offload broad "read a lot, return a little" work — codebase surveys, docs sweeps, finding every call site — to headless `claudex -p` runs so fan-out reading burns the MiMo plan instead of the main Anthropic context/quota. It's gather-only: `claudex` reports, the main agent decides and edits.

A `/brain` **skill** (`~/.claude/skills/brain/SKILL.md`) turns the box into a personal command center: Gmail/Calendar/Tasks via the provisioned `gws` CLI (`@googleworkspace/cli`) plus Telegram push/receive via a BotFather bot. The `gws` binary is provisioned, but auth is **manual post-deploy** (like the MiMo token): create a personal Google Cloud OAuth client and run `gws auth login`, and drop a bot token at `~/.claude/telegram_bot_token` (+ chat id). No secrets live in the repo — the skill reads them from files at runtime. Writes (send/insert/delete) are gated behind explicit confirmation; reads run freely.

## Shell environment

The interactive setup mirrors the local WSL box: zsh + oh-my-zsh (`git` plugin) + Starship
(Catppuccin Latte, `~/.config/starship.toml`), with fzf, zoxide, bat (aliased to `cat`), delta as
the git pager, and uv/pnpm/fnm on `PATH`. Interactive logins auto-attach to the tmux session
`main`; non-interactive shells (`ssh box <cmd>`, cloud-init's `su - user -c`) skip it. `chsh` to
zsh runs LAST in `runcmd` so earlier provisioning steps keep running under bash. WSL-only bits
(adb bridge, Edge `$BROWSER`, deno, opencode, flyctl) are intentionally omitted.

Git identity is set from the `git_user_name` / `git_user_email` variables.

## Conventions

- Use OpenTofu, not Terraform
- Secrets go in `terraform.tfvars` (gitignored), never hardcoded
- Server config goes in `cloud-init.yaml.tftpl`, not in separate scripts
- Keep it single-server simple — no modules, no workspaces
