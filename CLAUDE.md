# Dev Box

Remote development server for coding agents. The **dedicated Hetzner Robot server `dev-box`** (EX44, Tailscale-only) is the primary path; the OpenTofu/hcloud path for the Cloud VM `dev-box-1` is legacy, removed once dev-box-1 is retired (October 2026). **This repo is public** (see Conventions).

## Stack

- **Primary:** Hetzner Robot EX44-1-LTD (i5-13500, 64 GB, 2 x NVMe), Ubuntu 24.04, `dedicated/up.sh install|provision|lockdown`
- **Legacy:** OpenTofu with `hetznercloud/hcloud` for `dev-box-1`
- **Networking:** Tailscale mesh; OpenSSH over the tailnet (`tailscale up --hostname dev-box`, no `--ssh`); no public ports after lockdown
- **Provisioning:** `setup.sh` + `files/` uploaded and run over SSH. Dedicated: `dedicated/bootstrap.sh` first. hcloud: `cloud-init.yaml.tftpl` first (Hetzner hard-caps `user_data` at 32KiB, so the bulk cannot live there)
- **Desktop:** XFCE4 + TigerVNC + noVNC (tailnet address only)
- **Shell:** zsh (login shell) + oh-my-zsh + Starship, tmux auto-attach to `fleet` if present, else `main`

## Files

- **Legacy hcloud, leave in place until dev-box-1 is destroyed, then delete** (October 2026): `main.tf` (server, key, firewall, provisioners), `variables.tf`, `outputs.tf`, `cloud-init.yaml.tftpl` (must stay under 32KiB rendered), `terraform.tfvars.example`, `data-volume.sh`
- `setup.sh` — everything else: Node/fnm, Claude Code (native installer) + plugins (superpowers, context7), claudex + `claudex-mimo-search`, gws/gwsa, skills, shell env, Playwright, VNC, devbox-guard. Idempotent-ish; re-runnable by hand as root if an apply fails partway
- `files/` — verbatim payload uploaded to `/root/provision` (no secrets): `bin/claudex`, `bin/claudex-mimo-search`, `agent-shared/` (instruction sources, `skills/model-check`, `sync.py`; renders `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, `~/.config/opencode/AGENTS.md`), `claude/` (statusline, settings patch, hooks, `skills/claudex` + `skills/brain`), `gws-accounts/` (gwsa tool + per-slot email/scopes manifests), `home/` (zshrc, zshenv, tmux.conf, starship.toml)
- `terraform.tfvars` — secrets for the legacy path (gitignored)
- `files/agent-attention/` — local Claude/Codex lifecycle observer, F12 panel, tmux include, user systemd unit, and tests. `setup.sh` installs it; no session data, credentials, or Telegram sending. See its README for state semantics and regression tests.
- `files/devbox-guard/` — contention guard: systemd drop-ins giving `ssh`/`tailscaled` high CPU/IO weight and `MemoryMin` (plus `system.slice` `MemoryMin` so that protection is effective), sshd `Nice=-5` reset to 0 for login sessions via `limits.conf`, `io` delegated to user managers, and `devbox-iocost.service` enabling blk-iocost so `IOWeight` is enforced. The tmux server starts in the user `fleet.slice` (zshrc / hq `fleet.py up`), so every pane inherits its low weight.
- `data-volume.sh` — mounts the Hetzner data volume (`hcloud_volume.data`, 200 GB) at `/mnt/data` (`nofail`) and moves bulky, rebuildable data onto it: `~/.cache` and `~/.npm` become symlinks (uv's hard-linked cache stays on root as `~/.uv-cache`), and `/var/lib/docker` + `/var/lib/containerd` become bind mounts. `--dry-run` prints the steps. Never move `~/dev` or the fleet worktree trash (`git worktree move` can't cross filesystems).
- `dedicated/` — primary Robot path for `dev-box` (EX44, 2 x NVMe): `installimage.conf`, `up.sh` (install/provision/lockdown), `bootstrap.sh` (replaces cloud-init), `data-disk.sh`, `post-hq.sh`, `clone-dev.sh` + `dev-inventory.py` (private repo manifest, never committed), `START.md` (first steps), `DESIGN.md` (decisions), `README.md`. Tailscale-only after lockdown. `tests/smoke-dedicated.sh` is its acceptance smoke; `tests/check-public.sh` guards the public repo.

## Commands (legacy hcloud path)

```bash
tofu init          # install providers
tofu plan          # preview changes
tofu apply         # create/update server
tofu destroy       # tear down everything
hcloud server list # check server status via Hetzner CLI
hcloud server ssh dev-box-1 # SSH via hcloud (requires hcloud context)
```

## Dedicated (Robot) path (primary)

The dedicated server `dev-box` skips OpenTofu and cloud-init: `dedicated/up.sh install|provision|lockdown <ip>` runs installimage from Robot rescue, uploads the same `files/` + `setup.sh` payload, runs `dedicated/bootstrap.sh`, then drops public SSH once OpenSSH over the tailnet works (no Tailscale SSH). SSH key default `~/.ssh/dev-box_ed25519` (`DEVBOX_KEY`). `setup.sh` is shared with the hcloud path. See `dedicated/README.md`; first steps after lockdown are in `dedicated/START.md`.

## Post-deploy login (one-time on server)

```bash
gh auth login      # GitHub auth (hcloud: skip if github_token is set in tfvars)
claude login       # Claude Code auth (headless URL flow)
codex login
```

hcloud only: `github_token` in `terraform.tfvars` (fine-grained, repo-scoped PAT) lets `gh` clone private repos without a login. The token lands in cloud-init user-data, so scope it tightly and rotate it.

`claudex` is a provisioned wrapper (`/usr/local/bin/claudex`) that runs Claude Code against Xiaomi MiMo. The default and every tier, including subagents, map to `mimo-v2.6-flash`; `--model opus|fable` (or `CLAUDEX_MODEL=mimo-v2.6-pro`) selects `mimo-v2.6-pro` for deliberate synthesis runs. Default backend is the token plan (`MIMO_API_KEY` or `~/.claude/mimo_token`; add manually post-deploy, never in tfvars or the repo). Pay-as-you-go fallback: `claudex --paygo`, or persistently `echo paygo > ~/.claude/claudex_backend` (key from `MIMO_PAYGO_KEY` or `~/.claude/mimo_paygo_token`; flag > file; PAYG is used automatically if no plan token exists). Plain `claude` stays on Anthropic.

Web search under `claudex` comes from `/usr/local/bin/claudex-mimo-search` (Python stdlib MCP server, source `files/bin/claudex-mimo-search`, installed by `setup.sh`). The wrapper adds it as `mcp__mimo__web_search` and denies the Anthropic-only built-in `WebSearch`. It tries the plan route first, then PAYG, billed per search; `CLAUDEX_SEARCH=0` omits it. The old Node bridge (`mimo-search-mcp.mjs` + `search_mcp.json`) is gone.

A `/claudex` **skill** ships alongside the wrapper (`~/.claude/skills/claudex/SKILL.md`, registered in `files/agent-shared/instructions/common.md`). It teaches the main Claude Code agent to offload broad "read a lot, return a little" work — codebase surveys, docs sweeps, finding every call site — to headless `claudex -p` runs so fan-out reading burns the MiMo plan instead of the main Anthropic context/quota. It's gather-only: `claudex` reports, the main agent decides and edits.

A `/brain` **skill** (`~/.claude/skills/brain/SKILL.md`) turns the box into a personal command center: Gmail/Calendar/Tasks via the provisioned `gws` CLI (`@googleworkspace/cli`) plus Telegram push/receive via a BotFather bot. Auth is **manual post-deploy** (like the MiMo token): per Google account, drop the shared OAuth client JSON into its slot dir and run `gwsa login <slot>`; drop a bot token at `~/.claude/telegram_bot_token` (+ chat id). No secrets live in the repo — the skill reads them from files at runtime. Writes (send/insert/delete) are gated behind explicit confirmation; reads run freely.

**gwsa (multi-account gws).** Provisioning lays down `~/.config/gws-accounts/` with one credential slot per Google account (`personal` = default, `angkin`, `pymc`, `ce`), each holding an `email` manifest and a `scopes` file; the `gwsa` wrapper (Python, zero deps, symlinked onto `PATH`) scopes every `gws` call to a slot via `GOOGLE_WORKSPACE_CLI_CONFIG_DIR` + a per-dir file keyring. `gwsa <slot> <gws args>`, `gwsa status [--verify]`, `gwsa login <slot>`, `gwsa token <slot>`, `gwsa check [--notify]`. Bare `gws` = `personal` (`~/.config/gws` symlink); never bare-login a work account. All slots share one OAuth client in Testing mode, so refresh tokens die ~weekly per account; a provisioned daily cron (`gwsa check --notify`, 08:30) Telegram-pings when a slot needs `gwsa login <slot>`. The dir is a git repo (config tracked, secrets gitignored). Docs: `files/gws-accounts/README.md` (provisioned to `~/.config/gws-accounts/README.md`); GCP bootstrap history: `files/claude/skills/brain/SETUP.md`.

## Shell environment

The interactive setup: zsh + oh-my-zsh (`git` plugin) + Starship
(Catppuccin Latte, `~/.config/starship.toml`), with fzf, zoxide, bat (aliased to `cat`), delta as
the git pager, and uv/pnpm/fnm on `PATH`. Interactive logins auto-attach to the tmux session
`fleet` if it exists, else `main`; non-interactive shells (`ssh box <cmd>`, setup.sh's `su - user -c`) skip it. `chsh` to
zsh runs LAST in `setup.sh` so earlier provisioning steps keep running under bash.

Git identity is set from the `git_user_name` / `git_user_email` variables (hcloud) or `setup.sh` arguments (dedicated).

## Conventions

- Use OpenTofu, not Terraform (legacy path only)
- **This repo is public.** No secrets, tokens, IPs, tailnet names, private skill content or client names. Run `tests/check-public.sh` before every commit. Private material (repo manifests, `.env` files, hq skills) stays out; hq-owned skills live in the private hq repo
- Secrets go in `terraform.tfvars` (gitignored), never hardcoded — and never in `files/` (it's uploaded verbatim)
- Server config: anything needing template vars or secrets goes in `cloud-init.yaml.tftpl` (keep it small — 32KiB rendered cap); static file content goes in `files/`; orchestration goes in `setup.sh`
- The live box is the source of truth for `files/` content — when the box config evolves, back-port it here so the next rebuild reproduces it
- Keep it single-server simple — no modules, no workspaces
