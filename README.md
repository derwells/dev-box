# Dev Box

Remote development server for coding agents (Claude Code, Codex), reached over Tailscale from a
laptop or phone. A desktop session is available through noVNC for visual checks.

**This repository is public.** It holds no secrets, tokens, IPs or tailnet names; those live in
gitignored files or on the box. `tests/check-public.sh` enforces that.

## Two paths

| Path | Server | Status |
|------|--------|--------|
| **Dedicated (Robot)** | Hetzner EX44-1-LTD (i5-13500, 64 GB, 2 x 512 GB NVMe), `dev-box` | Primary. Tailscale-only after lockdown. See [`dedicated/README.md`](dedicated/README.md), [`dedicated/START.md`](dedicated/START.md), [`dedicated/DESIGN.md`](dedicated/DESIGN.md). |
| **hcloud (legacy)** | Cloud VM `dev-box-1`, provisioned with OpenTofu | Legacy, removed once dev-box-1 is retired (October 2026). Until the server is destroyed, leave `main.tf`, `variables.tf`, `outputs.tf`, `cloud-init.yaml.tftpl`, `terraform.tfvars.example` and `data-volume.sh` in place. |

Both paths upload the same `files/` payload and run the same `setup.sh`.

## What gets installed

```
Ubuntu Server 24.04
├── Tailscale          — private mesh; OpenSSH over the tailnet (no `--ssh`), no public ports after lockdown
├── Claude Code        — native installer (~/.local/bin)
│   ├── Superpowers    — plugin (official marketplace)
│   ├── Context7       — plugin (official marketplace)
│   ├── Humanizer      — writing skill
│   └── skills         — claudex, brain, model-check
├── claudex            — Claude Code on Xiaomi MiMo, plus a MiMo web-search MCP bridge
├── gws + gwsa         — Google Workspace CLI, one credential slot per account
├── agent-shared       — one instruction source rendered for Claude, Codex and OpenCode
├── agent-attention    — Claude/Codex status panel in tmux (F12)
├── devbox-guard       — keeps ssh and tailscaled responsive under load
├── zsh + oh-my-zsh    — login shell with Starship, fzf, zoxide, bat, delta, uv, pnpm, fnm
├── tmux               — auto-attaches on login
├── GitHub CLI, Playwright
└── XFCE4 + TigerVNC + noVNC — desktop in a browser tab, bound to the tailnet address
```

The dedicated path adds Docker, Codex CLI, a second-disk `/data` layout and a 16 GiB swapfile
(see `dedicated/`).

## Dedicated path (summary)

```bash
dedicated/up.sh install   <public-ip>   # from Robot rescue: installimage + reboot
dedicated/up.sh provision <public-ip>   # bootstrap.sh, then setup.sh
# on the box: tailscale up --hostname dev-box   (approve the node)
dedicated/up.sh lockdown  <public-ip>   # drop public 22 once tailnet SSH works
```

Then follow [`dedicated/START.md`](dedicated/START.md) (logins, Google slots, cloning `~/dev`).
Run `tests/smoke-dedicated.sh` on the box to verify.

## hcloud path (legacy, removed once dev-box-1 is retired, October 2026)

OpenTofu + cloud-init for the Cloud VM `dev-box-1`: `cp terraform.tfvars.example terraform.tfvars`,
then `tofu init && tofu apply`. Cloud-init bootstraps; OpenTofu then uploads `files/` and runs
`setup.sh`, which can be re-run by hand as root. These files are deleted after the server is
destroyed; nothing new should depend on them.

## Post-install logins (one-time)

```bash
gh auth login      # GitHub (skipped if github_token was set in tfvars on the hcloud path)
claude login       # Claude Code (headless URL flow)
codex login        # dedicated path only
```

### Optional: `claudex` (Claude Code on Xiaomi MiMo)

`claudex` runs the same Claude Code binary against MiMo's token-plan endpoint. Everything,
including subagents, runs on `mimo-v2.6-flash` unless a run asks for the high tier with
`--model opus|fable` (or `CLAUDEX_MODEL=mimo-v2.6-pro`). Plain `claude` is unaffected.

Add your token-plan key once, never to tfvars or the repo:

```bash
echo "<plan-token>" > ~/.claude/mimo_token && chmod 600 ~/.claude/mimo_token
claudex                       # interactive
claudex -p "..."              # headless
```

`MIMO_API_KEY` in the environment overrides the file. **Plan ran out?** Fall back to pay-as-you-go:

```bash
claudex --paygo -p "..."                    # one run
echo paygo > ~/.claude/claudex_backend      # persistent (echo plan, or delete the file, to undo)
```

The PAYG key comes from `MIMO_PAYGO_KEY` or `~/.claude/mimo_paygo_token`. Precedence is flag >
`~/.claude/claudex_backend`; with no plan token, `claudex` uses PAYG automatically.

**Web search.** Claude Code's built-in `WebSearch` is Anthropic-only, so `claudex` denies it and,
when `/usr/local/bin/claudex-mimo-search` is present (installed by `setup.sh`), adds it as the MCP
tool `mcp__mimo__web_search`. The bridge calls MiMo's search over the OpenAI-compatible protocol,
tries the token plan first and then PAYG, and is billed per search. `CLAUDEX_SEARCH=0` leaves it out.

**`/claudex` skill.** `~/.claude/skills/claudex/SKILL.md` teaches your main `claude` session to
offload broad "read a lot, return a little" research to headless `claudex -p` runs, so fan-out
reading burns the MiMo plan instead of your main quota. It is gather-only: claudex reports, the
main agent decides and edits.

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

### Optional: VNC desktop

```bash
vncpasswd                     # set password, say "no" to view-only
sudo systemctl enable --now vncserver@1 novnc
```

noVNC listens on the tailnet address only, port 6080.

## Connecting

Use plain OpenSSH over the tailnet. In `~/.ssh/config` on your laptop:

```
Host dev-box
    HostName <tailscale-ip-or-hostname>
    User <username>
    IdentityFile ~/.ssh/dev-box_ed25519
    ForwardAgent yes
```

| From   | Method                                  | Use case                      |
|--------|-----------------------------------------|-------------------------------|
| Laptop | `ssh dev-box`                           | Claude Code, terminal work    |
| Laptop | `http://<tailscale-ip>:6080` in browser | Visual verification, browsing |
| Phone  | SSH app via Tailscale                   | Quick checks, monitoring      |

## Shell environment

`ssh dev-box` lands you in a ready interactive shell:

- **zsh** is the login shell, with oh-my-zsh (`git` plugin) and a **Starship** prompt using the
  Catppuccin Latte palette (`~/.config/starship.toml`).
- **tmux** auto-attaches to a session named `fleet` if one exists, else `main` (created if
  needed), on every interactive login, so disconnects never lose work. Config is `~/.tmux.conf` — mouse on, 1-indexed windows,
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

## Costs

Dedicated: the Hetzner EX44 monthly fee (see Hetzner's current pricing). Tailscale is free for personal use.
