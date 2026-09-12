# Dev Box

Remote development server for Claude Code, accessible via Tailscale SSH from laptop and phone. Includes a desktop environment for visual verification via noVNC in a browser.

Provisioned with OpenTofu on Hetzner Cloud. One command to create, one to destroy.

## Stack

```
Hetzner CPX31 (4 vCPU, 8GB RAM, ~$12/mo)
Ubuntu Server 24.04
├── Tailscale          — private mesh networking, no public ports
├── Claude Code        — Node.js + npm
│   ├── GSD            — get-shit-done workflow skills + hooks
│   ├── Superpowers    — plugin (official marketplace)
│   ├── Context7       — plugin (official marketplace)
│   └── Humanizer      — writing skill
├── gws + gwsa         — Google Workspace CLI, one credential slot per account
├── zsh + oh-my-zsh    — default login shell, mirrors the local WSL config
│   ├── Starship       — prompt (Catppuccin Latte)
│   ├── fzf/zoxide/bat — Ctrl+R, `z`, syntax-highlighted `cat`
│   ├── uv, pnpm, fnm  — Python + Node toolchains
│   └── tmux           — auto-attaches to session "main" on login
├── GitHub CLI         — gh auth, PRs, issues
├── Playwright         — headless browser for automated screenshots
├── XFCE4             — lightweight desktop (~200MB)
├── TigerVNC          — serves the desktop session
├── noVNC             — web-based VNC client (browser tab on laptop/phone)
└── Chromium          — for manual visual verification
```

## Prerequisites

- [OpenTofu](https://opentofu.org/docs/intro/install/) installed locally
- [Hetzner CLI](https://github.com/hetznercloud/cli) (`hcloud`) for server management
- A [Hetzner Cloud](https://console.hetzner.cloud) account with an API token
- [Tailscale](https://tailscale.com) account (free for personal use)
- An SSH key pair (`~/.ssh/id_ed25519` by default)

## Setup

### 1. Create your config

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with:
- Your Hetzner API token (create at Hetzner Console → Security → API Tokens)
- Optionally, a [Tailscale auth key](https://login.tailscale.com/admin/settings/keys) for automatic device registration

### 2. Set up Hetzner CLI

```bash
hcloud context create dev-box    # paste your Hetzner API token when prompted
```

### 3. Deploy

```bash
tofu init
tofu apply
```

This creates the server in two stages: cloud-init bootstraps it (user, packages, Tailscale,
firewall), then OpenTofu uploads `files/` + `setup.sh` over SSH and runs the script to install
everything else. The split exists because Hetzner hard-caps cloud-init `user_data` at 32KiB and
the full payload is far larger. Takes ~10 minutes. The provisioners connect as root with
`ssh_private_key_path` (default `~/.ssh/id_ed25519`).

If `setup.sh` fails partway (e.g. a flaky download), it's safe to re-run by hand:

```bash
ssh root@<public-ip> 'bash /root/setup.sh <username> "<git name>" <git email>'
```

### 4. Post-deploy (one-time)

SSH into the server:

```bash
ssh <username>@<public-ip>    # from tofu output
```

If you didn't provide a Tailscale auth key:

```bash
sudo tailscale up --ssh
```

Approve the device in the [Tailscale admin console](https://login.tailscale.com/admin/machines).

Log in to services (each gives you a URL to open in any browser):

```bash
gh auth login                 # GitHub — clone, push, PRs
claude login                  # Claude Code — AI assistant (Anthropic)
```

#### Optional: `claudex` (Claude Code routed to Xiaomi MiMo)

`claudex` runs the same Claude Code binary against Xiaomi MiMo's token-plan endpoint, with this
tier mapping: Sonnet/Haiku (and the session default) → `mimo-v2.5` for cheap fan-out;
`--model opus` / `--model fable` → `mimo-v2.5-pro` for runs that explicitly ask for the high
tier. Plain `claude` is unaffected.

Add your token-plan key once (looks like `tp-...`):

```bash
echo "tp-xxxxx" > ~/.claude/mimo_token && chmod 600 ~/.claude/mimo_token
```

Then:

```bash
claudex                       # interactive -> mimo-v2.5
claudex -p "..."              # headless (fan-out runs also stay on mimo-v2.5)
```

A `MIMO_API_KEY` in the environment overrides the file.

**Token plan ran out?** `claudex` can fall back to MiMo's pay-as-you-go API
(`https://api.xiaomimimo.com/anthropic`), billed from account balance. It reuses the same
`sk-...` key as the search bridge below (`MIMO_PAYGO_KEY` env or `~/.claude/mimo_paygo_token`):

```bash
claudex --paygo -p "..."                    # one run on PAYG
echo paygo > ~/.claude/claudex_backend      # every run on PAYG until you switch back
echo plan  > ~/.claude/claudex_backend      # back to the token plan (or just delete the file)
```

`CLAUDEX_BACKEND=paygo|plan` in the environment also works (flag > env > file). If there's no
token-plan token at all but a PAYG key exists, `claudex` falls back to PAYG automatically.

**Web search (optional, pay-as-you-go).** Claude Code's built-in `WebSearch` is server-side and
Anthropic-only, so it doesn't work through MiMo. `claudex` instead routes search through a small
MCP bridge (`~/.claude/mimo-search-mcp.mjs`, wired via `~/.claude/search_mcp.json`) that calls
MiMo's web-search plugin. This is **not** covered by the token plan — it needs a separate
pay-as-you-go key (`sk-...`) with account balance (~$5 per 1,000 searches + tokens) and the
web-search plugin enabled in the [MiMo console](https://platform.xiaomimimo.com/#/console/plugin):

```bash
echo "sk-xxxxx" > ~/.claude/mimo_paygo_token && chmod 600 ~/.claude/mimo_paygo_token
```

Once the key is present, `claudex` auto-loads the bridge and disables the dead built-in
`WebSearch`; the model calls `web_search` and gets grounded answers with source URLs. Model
traffic stays on the token plan — only search hits the pay-as-you-go balance. Without the key,
`claudex` still works for everything else.

**`/claudex` skill.** The box also ships a `claudex` skill (`~/.claude/skills/claudex/SKILL.md`)
that teaches your main `claude` session to offload broad "read a lot, return a little" research —
codebase surveys, docs sweeps, finding every call site — to headless `claudex -p` runs. Fan-out
reading then burns the cheap MiMo plan instead of your main Anthropic context and quota. It's
gather-only: `claudex` reports with `file:line` evidence, and your main agent makes the decisions
and does the edits.

#### Optional: `/brain` (personal command center)

The box ships a `brain` skill (`~/.claude/skills/brain/SKILL.md`) that wires Claude Code into
**Gmail, Calendar, and Tasks** (via the provisioned `gws` CLI) plus **Telegram** push/receive.
The `gws` binary is installed at provision time; credentials are a **manual, one-time
post-deploy step** (no secrets are baked into the image):

```bash
# Google — per account slot: drop the shared OAuth desktop client JSON into the
# slot dir, then log in (opens a consent URL; gwsa verifies you picked the right
# account and the scopes from the slot's scopes file):
cp client_secret.json ~/.config/gws-accounts/<slot>/client_secret.json
gwsa login <slot>
# Telegram: create a bot via @BotFather, then:
echo "<bot-token>" > ~/.claude/telegram_bot_token && chmod 600 ~/.claude/telegram_bot_token
echo "<chat-id>"   > ~/.claude/telegram_chat_id  && chmod 600 ~/.claude/telegram_chat_id
```

**Multi-account (`gwsa`).** Provisioning lays down one isolated `gws` credential store
("slot") per Google account under `~/.config/gws-accounts/<slot>/` — `personal` (default),
`angkin`, `pymc`, `ce` — each with an `email` manifest and a `scopes` file. The `gwsa`
wrapper (on `PATH`, symlinked from that dir) is the only interface you need:

```bash
gwsa <slot> <any gws command>   # account-scoped gws
gwsa status --verify            # all-slot health: creds, token, right account, scope drift
gwsa login <slot>               # (re-)auth a slot with its scopes file
gwsa token <slot>               # fresh access token for raw REST (e.g. Admin SDK)
gwsa check --notify             # cron target: Telegram ping when a token dies
```

Bare `gws` = the `personal` slot (`~/.config/gws` is a symlink to it). **Never** run bare
`gws auth login` for a non-personal account — it would overwrite personal's credentials;
always `gwsa login <slot>`. A daily cron (08:30) runs `gwsa check --notify` and pings
Telegram when a previously-working slot needs re-login. Full docs (shared OAuth client,
test users, the ~7-day Testing-mode token expiry and how domain-admin trust lifts it) are
provisioned to `~/.config/gws-accounts/README.md`, and one-time GCP bootstrap history to
`~/.claude/skills/brain/SETUP.md`.

The skill reads secrets from disk at runtime and gates every write (send/insert/delete)
behind an explicit confirmation. Keep the OAuth consent screen in **Testing** mode (refresh
tokens then expire ~weekly — `gwsa login <slot>` revives a slot in ~30s); the skill documents
the recovery flow, including the Tailscale localhost-callback gotcha.

Set a VNC password and start the desktop:

```bash
vncpasswd                     # set password, say "no" to view-only
sudo systemctl enable --now vncserver@1 novnc
```

### 5. Connect

Add to `~/.ssh/config` on your laptop:

```
Host dev-box
    HostName <tailscale-ip-or-hostname>
    User <username>
    ForwardAgent yes
```

| From   | Method                                  | Use case                      |
|--------|-----------------------------------------|-------------------------------|
| Laptop | `ssh dev-box`                           | Claude Code, terminal work    |
| Laptop | `http://<tailscale-ip>:6080` in browser | Visual verification, browsing |
| Phone  | SSH app via Tailscale                   | Quick checks, monitoring      |
| Phone  | `http://<tailscale-ip>:6080` in browser | Visual verification           |

## Shell environment

The box provisions the same interactive setup as the local WSL machine, so `ssh dev-box` lands you
in a familiar shell:

- **zsh** is the login shell, with oh-my-zsh (`git` plugin) and a **Starship** prompt using the
  Catppuccin Latte palette (`~/.config/starship.toml`).
- **tmux** auto-attaches to a session named `main` (creating it if needed) on every interactive
  login, so disconnects never lose work. Config is `~/.tmux.conf` — mouse on, 1-indexed windows,
  `|`/`-` splits, and a shared **Claude Code + Codex attention panel** on F12. Green means
  ready, amber needs input, blue working; completion waits for tracked sub-agents and active
  Codex goals. Tap either line to open its exact pane and mark the alert read; READY stays
  visible. Alt+a jumps to the next unread alert and Alt+d marks the current pane read.
  The panel uses a local user service, with no Telegram sending. See
  [setup details and tests](files/agent-attention/README.md).
  Mobile-friendly touches include a two-line status bar with tap-sized window targets, F1–F11
  and Alt+digit window switching, swipe-to-cycle on the status bar, and OSC 52 clipboard
  forwarding. Non-interactive shells (`ssh dev-box <cmd>`, provisioning) skip the attach.
- **fzf** (Ctrl+R history, Ctrl+T files, Alt+C cd), **zoxide** (`z`), **bat** (aliased to `cat`),
  **delta** as the git pager, plus **uv**, **pnpm**, and **fnm** on `PATH`.
- Git identity comes from the `git_user_name` / `git_user_email` variables (defaults in
  `variables.tf`; override in `terraform.tfvars`).

WSL-only pieces of the local config — the adb/`WSL_HOST_IP` bridge, Edge as `$BROWSER`, deno,
opencode, flyctl — are deliberately left out.

## Server Management

```bash
hcloud server list              # check status
hcloud server ssh dev-box       # SSH via hcloud
hcloud server reboot dev-box    # reboot
tofu destroy                    # tear down everything
```

## Costs

| Item          | Cost        |
|---------------|-------------|
| Hetzner CPX31 | ~$12/mo     |
| Tailscale     | Free        |
| **Total**     | **~$12/mo** |
