---
name: brain
description: >
  Personal command center: Gmail, Google Calendar, and Google Tasks via the
  global `gws` CLI, plus Telegram push/receive via a BotFather bot. Use ONLY
  when the user explicitly invokes /brain — do not activate on incidental
  mentions of email, calendar, or tasks.
compatibility: claude-code
allowed-tools:
  - Bash
  - Read
  - AskUserQuestion
---

# brain — personal command center

Gmail / Calendar / Tasks through the `gws` CLI (global npm install, own token
store — works from any directory) and a Telegram bot for push + commands.
Full setup/bootstrap history lives in `~/.claude/skills/brain/SETUP.md`
(terraform bootstrap alongside it in `terraform/`); this skill is the
operating manual.

## Accounts (multi-account since 2026-08-25)

Each Google account has its own isolated `gws` store under
`~/.config/gws-accounts/<slot>`; use the **`gwsa` executable** (on PATH,
works in Bash tool calls) — full docs in `~/.config/gws-accounts/README.md`:

```bash
gwsa <slot> <any gws command>   # account-scoped gws
gwsa status [--verify]          # all-slot health (--verify: live email + scope check)
gwsa login <slot>               # re-auth with the slot's scopes file, verifies identity
gwsa token <slot>               # fresh access token for raw REST
```

| name       | account                    | use for |
|------------|----------------------------|---------|
| `personal` | drckwells@gmail.com        | DEFAULT — brain project, personal mail/cal/tasks |
| `angkin`   | derick@angkin.ph           | angkin.ph business only |
| `pymc`     | derick.wells@pymc-labs.com | PyMC Labs work only |
| `ce`       | dwells@consumer-edge.com   | Consumer Edge client project only |

```bash
gwsa angkin gmail users messages list --params '{"userId":"me"}'
```

(`gwsa` sets `GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file` itself so each slot
keeps its own `.encryption_key` — never bypass it with raw env vars unless
you include that backend setting too.)

- `~/.config/gws` is a **symlink** to the `personal` slot, so bare `gws` =
  personal. Never run bare `gws auth login` for a non-personal account — it
  would overwrite personal's credentials (this happened once; that's why the
  symlink layout exists).
- If the user doesn't say which account, infer from context; when ambiguous
  for a **write**, ask. Cross-account operations (e.g. "check all inboxes")
  are fine — loop over the slots.
- All four share the Brain OAuth client (project `brain-500508`); the three
  non-personal accounts hold `roles/serviceusage.serviceUsageConsumer` on it
  (granted 2026-08-25) — without it every gws call 403s with
  "Caller does not have required permission to use project brain-500508".

## Secrets & preflight

- **Google**: nothing to load. `gws` reads its own encrypted store per account
  as above (independent of `gcloud`/ADC).
- **Telegram**: env var first, else plaintext file, then trim — same pattern
  as `~/.claude/mimo_paygo_token`:
  ```bash
  TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-$(cat ~/.claude/telegram_bot_token)}"
  TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-$(cat ~/.claude/telegram_chat_id)}"
  ```
- **Health check** (run first if anything Google-side misbehaves):
  ```bash
  gws auth status   # want: has_refresh_token: true, project_id: brain-500508
  ```

## Command cookbook (verified syntax)

`+`-prefixed commands are convenience helpers; the rest are generated from
Google's Discovery API.

**Gmail**
```bash
gws gmail users messages list --params '{"userId":"me"}'
gws gmail +send  --to alice@example.com --subject "Hi" --body "..."
gws gmail +reply --message-id <ID> --body "Thanks!"
```

**Calendar**
```bash
gws calendar events list --params '{"calendarId":"primary"}'
gws calendar +agenda --today --timezone <Your/TZ>
gws calendar +insert <event params>
```

**Tasks** — resource is repeated: `gws tasks <resource> <verb>`.
`@default` resolves to the primary "My Tasks" list; other lists use the `id`
from `tasklists list`.
```bash
gws tasks tasklists list
gws tasks tasks list --params '{"tasklist":"@default"}'
gws tasks tasks insert --params '{"tasklist":"@default"}' --body '{"title":"..."}'
```

**Workspace admin (angkin only)** — `gws` has no Admin SDK commands, but the
angkin scopes file carries `admin.directory.user/group` + groups-settings;
call the REST API directly with `gwsa token`. Admin SDK + Groups Settings
APIs are enabled on `brain-500508`. Writes here are gated like any other
write.
```bash
curl -s -H "Authorization: Bearer $(gwsa token angkin)" \
  "https://admin.googleapis.com/admin/directory/v1/groups?domain=angkin.ph"
```

**Telegram** (isolated side-channel: can message you and receive commands sent
to it, but cannot read existing DMs/groups)
```bash
# send (push a message to the user)
curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -H 'Content-Type: application/json' \
  -d "{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":\"...\"}"

# receive (poll for messages the user sent the bot)
curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates"
```

## Safety rules

- **Reads are free**: `list`, `get`, `+agenda`, `auth status`, Telegram
  `getUpdates`. Run these without asking.
- **Writes are gated**: anything that sends, creates, updates, or deletes —
  `+send`, `+reply`, `+insert`, `tasks ... insert`, `events ... delete/patch`,
  Telegram `sendMessage` — requires an explicit user confirm (AskUserQuestion,
  showing exactly what will be sent/changed) before running.

## Auth recovery (recurs ~weekly)

The OAuth consent screen is deliberately kept in **Testing** mode, so refresh
tokens expire after ~7 days — **per account**. Each slot's scopes live in
`~/.config/gws-accounts/<slot>/scopes` (one URL per line, `#` comments; angkin
additionally carries Admin SDK Directory/Groups scopes). When `gws` starts
failing auth for a given account, re-login with that slot's scopes:

```bash
gwsa login <slot>
```

`gwsa status` shows which slots need it. The login verifies the consented
identity against the slot's `email` file and fails loudly on a mismatch.

At the consent screen, pick that slot's account — `gwsa login` catches a
wrong-account consent afterward and prints the fix.

- **Remote/Tailscale gotcha**: the OAuth callback listener runs on
  `localhost:<port>` on THIS box. If the browser is on another machine the
  redirect hits the wrong host and login hangs. Fix: copy the full
  `http://localhost:<port>/?...code=...` redirect URL from the browser and
  `curl` it on this box (or swap `localhost` for this box's Tailscale hostname
  in the browser URL bar).
- **Gmail send 403 on scope**: only `gmail.modify` is granted; it covers
  `messages.send`, but if a send ever 403s re-run login adding `gmail.send`
  to the services list.
- **Never use `gws auth setup`** — it shells out to `gcloud` and would touch
  work-account state. Manual OAuth path only; full re-bootstrap steps are in
  `~/.claude/skills/brain/SETUP.md`.
- Telegram token leak: `@BotFather → /revoke` reissues instantly; update
  `~/.claude/telegram_bot_token`.
