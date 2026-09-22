# Dev Box

Remote development server provisioned with OpenTofu on Hetzner Cloud. One command to create, one to destroy.

## Stack

- **Infrastructure:** OpenTofu with `hetznercloud/hcloud` provider
- **Server:** Hetzner CPX31 (4 vCPU, 8GB RAM, Ubuntu 24.04)
- **Networking:** Tailscale mesh (no public ports except SSH fallback)
- **Provisioning:** two-stage — cloud-init bootstrap (`cloud-init.yaml.tftpl`), then `setup.sh` + `files/` uploaded and run over SSH by provisioners in `main.tf`. Hetzner hard-caps `user_data` at 32KiB, so the bulk cannot live in cloud-init.
- **Desktop:** XFCE4 + TigerVNC + noVNC for browser-based visual verification
- **Shell:** zsh (login shell) + oh-my-zsh + Starship, tmux auto-attach to session `main`

## Files

- `main.tf` — server, SSH key, firewall resources + file/remote-exec provisioners that upload `files/` and run `setup.sh`
- `variables.tf` — all configurable inputs
- `outputs.tf` — public IP, SSH command after deploy
- `cloud-init.yaml.tftpl` — bootstrap only: user, packages, GitHub CLI/auth, Tailscale, UFW (must stay under 32KiB rendered)
- `setup.sh` — everything else: Node/fnm, Claude Code + GSD + plugins, claudex, gws/gwsa, skills, shell env, Playwright, VNC. Idempotent-ish; re-runnable by hand as root if an apply fails partway
- `files/` — verbatim payload uploaded to `/root/provision` (no secrets): `bin/claudex`, `agent-shared/` (instruction sources + `sync.py`; renders `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, `~/.config/opencode/AGENTS.md`), `claude/` (statusline, search bridge, settings patch, `skills/claudex` + `skills/brain`), `gws-accounts/` (gwsa tool + per-slot email/scopes manifests), `home/` (zshrc, zshenv, tmux.conf, starship.toml)
- `terraform.tfvars` — secrets (gitignored)
- `files/agent-attention/` — local Claude/Codex lifecycle observer, F12 panel, tmux include, user systemd unit, and tests. `setup.sh` installs it; no session data, credentials, or Telegram sending. See its README for state semantics and regression tests.
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

`claudex` is a provisioned wrapper that runs Claude Code against Xiaomi MiMo: Sonnet/Haiku (and the session default) → `mimo-v2.5`; an explicit `--model opus` or `--model fable` → `mimo-v2.5-pro` (keep fan-out on the cheap tier, escalate only deliberate synthesis runs). Default backend is the token plan (`MIMO_API_KEY` or `~/.claude/mimo_token`; add manually post-deploy — never in tfvars). When the plan runs out it can fall back to pay-as-you-go (`https://api.xiaomimimo.com/anthropic`, same `sk-...` key as the search bridge): `claudex --paygo`, `CLAUDEX_BACKEND=paygo`, or persistently via `echo paygo > ~/.claude/claudex_backend` (flag > env > file; auto-falls back if no plan token exists). Plain `claude` stays on Anthropic.

Web search under `claudex` goes through a provisioned MCP bridge (`~/.claude/mimo-search-mcp.mjs` + `search_mcp.json`) that calls MiMo's pay-as-you-go search plugin — Claude Code's built-in `WebSearch` is Anthropic-only and doesn't work via MiMo. The bridge is dormant until you add a separate PAYG key at `~/.claude/mimo_paygo_token` (`sk-...`, billed outside the token plan). When present, `claudex` loads the bridge and disables the built-in `WebSearch`.

A `/claudex` **skill** ships alongside the wrapper (`~/.claude/skills/claudex/SKILL.md`, registered in `files/agent-shared/instructions/common.md`). It teaches the main Claude Code agent to offload broad "read a lot, return a little" work — codebase surveys, docs sweeps, finding every call site — to headless `claudex -p` runs so fan-out reading burns the MiMo plan instead of the main Anthropic context/quota. It's gather-only: `claudex` reports, the main agent decides and edits.

A `/brain` **skill** (`~/.claude/skills/brain/SKILL.md`) turns the box into a personal command center: Gmail/Calendar/Tasks via the provisioned `gws` CLI (`@googleworkspace/cli`) plus Telegram push/receive via a BotFather bot. Auth is **manual post-deploy** (like the MiMo token): per Google account, drop the shared OAuth client JSON into its slot dir and run `gwsa login <slot>`; drop a bot token at `~/.claude/telegram_bot_token` (+ chat id). No secrets live in the repo — the skill reads them from files at runtime. Writes (send/insert/delete) are gated behind explicit confirmation; reads run freely.

**gwsa (multi-account gws).** Provisioning lays down `~/.config/gws-accounts/` with one credential slot per Google account (`personal` = default, `angkin`, `pymc`, `ce`), each holding an `email` manifest and a `scopes` file; the `gwsa` wrapper (Python, zero deps, symlinked onto `PATH`) scopes every `gws` call to a slot via `GOOGLE_WORKSPACE_CLI_CONFIG_DIR` + a per-dir file keyring. `gwsa <slot> <gws args>`, `gwsa status [--verify]`, `gwsa login <slot>`, `gwsa token <slot>`, `gwsa check [--notify]`. Bare `gws` = `personal` (`~/.config/gws` symlink); never bare-login a work account. All slots share one OAuth client in Testing mode, so refresh tokens die ~weekly per account; a provisioned daily cron (`gwsa check --notify`, 08:30) Telegram-pings when a slot needs `gwsa login <slot>`. The dir is a git repo (config tracked, secrets gitignored). Docs: `files/gws-accounts/README.md` (provisioned to `~/.config/gws-accounts/README.md`); GCP bootstrap history: `files/claude/skills/brain/SETUP.md`.

## Shell environment

The interactive setup mirrors the local WSL box: zsh + oh-my-zsh (`git` plugin) + Starship
(Catppuccin Latte, `~/.config/starship.toml`), with fzf, zoxide, bat (aliased to `cat`), delta as
the git pager, and uv/pnpm/fnm on `PATH`. Interactive logins auto-attach to the tmux session
`main`; non-interactive shells (`ssh box <cmd>`, setup.sh's `su - user -c`) skip it. `chsh` to
zsh runs LAST in `setup.sh` so earlier provisioning steps keep running under bash. WSL-only bits
(adb bridge, Edge `$BROWSER`, deno, opencode, flyctl) are intentionally omitted.

Git identity is set from the `git_user_name` / `git_user_email` variables.

## Conventions

- Use OpenTofu, not Terraform
- Secrets go in `terraform.tfvars` (gitignored), never hardcoded — and never in `files/` (it's uploaded verbatim)
- Server config: anything needing template vars or secrets goes in `cloud-init.yaml.tftpl` (keep it small — 32KiB rendered cap); static file content goes in `files/`; orchestration goes in `setup.sh`
- The live box is the source of truth for `files/` content — when the box config evolves, back-port it here so the next rebuild reproduces it
- Keep it single-server simple — no modules, no workspaces
