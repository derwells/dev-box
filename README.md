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

This creates the server and runs cloud-init, which installs everything. Takes ~5 minutes.

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
tier mapping: all tiers (Opus/Sonnet/Haiku) → `mimo-v2.5`. The pricier `mimo-v2.5-pro` is
deliberately unmapped so fan-out runs can't escalate to it. Plain `claude` is unaffected.

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
The `gws` binary is installed at provision time; the accounts and secrets are a **manual,
one-time post-deploy step** (nothing personal is baked into the image):

```bash
# Google: create a personal-account OAuth desktop client, drop it at
#   ~/.config/gws/client_secret.json, then:
gws auth login --services gmail,calendar,tasks
# Telegram: create a bot via @BotFather, then:
echo "<bot-token>" > ~/.claude/telegram_bot_token && chmod 600 ~/.claude/telegram_bot_token
echo "<chat-id>"   > ~/.claude/telegram_chat_id  && chmod 600 ~/.claude/telegram_chat_id
```

The skill reads those secrets from disk at runtime and gates every write (send/insert/delete)
behind an explicit confirmation. Keep the OAuth consent screen in **Testing** mode (refresh
tokens then expire ~weekly — re-run `gws auth login`); the skill documents the recovery flow,
including the Tailscale localhost-callback gotcha.

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
  `|`/`-` splits, and the Claude Code attention icons (🔔 needs input, ✅ finished) in the status
  bar. Non-interactive shells (`ssh dev-box <cmd>`, provisioning) skip the attach.
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
