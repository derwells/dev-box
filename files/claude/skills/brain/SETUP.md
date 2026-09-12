# Personal Command Center — Setup (plumbing only)

This is the data-layer setup: **Google (Gmail/Calendar/Tasks) via the `gws` CLI** and **Telegram
via a BotFather bot**. No workflows/skills yet — once this is wired up and verified, you decide how
to combine it.

Design constraints baked into these steps:
- **Personal-account first.** Work accounts (pymc-labs.com, consumer-edge.com) are added later and
  may be blocked by their domain admin.
- **Stays off your work `gcloud` state.** `gws` keeps its own encrypted token store and is
  independent of `gcloud`/ADC. We deliberately use the **manual OAuth path**, NOT `gws auth setup`
  (that one shells out to `gcloud` and would create the project under your *active/work* gcloud
  account — exactly what we want to avoid).

Anything below prefixed with `!` you can run directly in this Claude Code session by typing it with
a leading `!`; the browser/Telegram steps you do yourself.

---

## 1. Personal GCP project + OAuth client (browser, ~10 min)

Do this signed in as your **personal Google account** (not a work account).

1. **Project: already created — `brain-500508`** (personal account / no-org, invisible to the work org).
2. **Enable APIs** — ✅ **DONE.** Gmail, Calendar, and Tasks APIs are enabled on `brain-500508`
   (enabled via gcloud as `drckwells@gmail.com`, with the quota project overridden per-command;
   saved config/ADC untouched). The `terraform/` config now no-ops these if ever applied.
   To re-do or verify:
   `gcloud services list --enabled --project brain-500508 --filter="config.name:(gmail.googleapis.com OR calendar-json.googleapis.com OR tasks.googleapis.com)"`
3. **OAuth consent screen** → User type **External**. ✅ done (app name "Brain").
   - **Keep publishing status = "Testing"** and add `drckwells@gmail.com` under **Test users**.
   - ⚠️ Do NOT publish to Production. Gmail/Calendar/Tasks are sensitive/restricted scopes, and
     Production + unverified = a hard "Access blocked: has not completed Google verification" with
     no bypass. The "Advanced → continue (unsafe)" path only exists in **Testing** mode for test
     users. Trade-off: Testing-mode refresh tokens expire after **~7 days**, so you re-run
     `gws auth login` about weekly. (Verification to lift that needs a paid CASA audit — not worth
     it for personal use.)
4. **Credentials → Clients → Create client** → Application type **Desktop app** (e.g. `gws-desktop`).
   Download the JSON. ✅ done
5. Put the downloaded JSON where `gws` looks for it:
   ```
   mkdir -p ~/.config/gws
   mv ~/Downloads/client_secret_*.json ~/.config/gws/client_secret.json
   ```
   (`~/.config/gws/` is gitignored via this repo's `.gitignore` if it ever lives here; the real
   path is your home config dir.)

**Scopes** to grant at login (read+write): Gmail `gmail.modify` + `gmail.send`,
Calendar `calendar`, Tasks `tasks`.

---

## 2. Install `gws` (`googleworkspace/cli`)

Pick one (pin a known-good release rather than floating `latest`):

```
# npm
npm install -g @googleworkspace/cli
# or Homebrew
brew install googleworkspace-cli
# or a pinned prebuilt binary from:
#   https://github.com/googleworkspace/cli/releases
```
Verify: `! gws --version`

### Authorize the personal account first
With `~/.config/gws/client_secret.json` in place:
```
gws auth login --services gmail,calendar,tasks
```
A browser opens → consent as your **personal** account → "Advanced → Go to Brain (unsafe) →
Continue" → Allow. Tokens are stored encrypted at rest in the `gws` config dir.

Check: `gws auth status` (look for `has_refresh_token: true`).

⚠️ **Remote/Tailscale gotcha (recurs on every weekly re-auth):** `gws` runs its OAuth callback
listener on `localhost:<port>` on THIS box. If your browser is on another machine, the
`http://localhost:<port>/?...code=...` redirect hits the wrong machine and the login hangs. Fix:
copy that full redirect URL and `curl` it *on this box* to hand the code to the waiting listener:
```
curl -sS "http://localhost:<port>/?...&code=...&scope=...&authuser=0&prompt=consent"
```
(Or replace `localhost` with this box's Tailscale hostname in the browser URL bar before pressing
enter.) The listener replies "Success" and `gws` completes the token exchange.

### Adding work accounts (later, optional) — multi-account caveat
⚠️ **`gws` 0.22.5 hardcodes its config dir to `~/.config/gws/` and ignores `XDG_CONFIG_HOME`**
(verified — setting it does not move `client_secret.json`/`credentials.enc`). So the "point an env
var at a per-account dir" trick does **not** work on this version. Realistic options for a second
account:

- **Symlink-swap** `~/.config/gws/` between per-account directories you keep elsewhere (e.g.
  `~/.config/gws-personal/`, `~/.config/gws-work/`), re-pointing the `gws` symlink before each run.
  Clunky but reliable.
- Or check whether a newer `gws` adds a `--account <email>` flag or a config-dir override, and use
  that if so.

If a work account's domain admin **blocks unverified apps**, `gws auth login` returns
"Access blocked / not verified." Then either ask that admin to allowlist your OAuth client ID as
Trusted, or leave that account out. The personal account is unaffected.

---

## 3. `gws` command cookbook (verified syntax)

The CLI generates most commands from Google's Discovery API; `+`-prefixed ones are convenience
helpers. Confirmed shapes:

**Gmail**
```
gws gmail users messages list --params '{"userId":"me"}'
gws gmail +send  --to alice@example.com --subject "Hi" --body "..."
gws gmail +reply --message-id <ID> --body "Thanks!"
```
**Calendar**
```
gws calendar events list --params '{"calendarId":"primary"}'
gws calendar +agenda --today --timezone <Your/TZ>
gws calendar +insert <event params>
```
**Tasks** — ✅ verified syntax (resource is repeated: `gws tasks <resource> <verb>`):
```
gws tasks tasklists list                                    # list task lists (find their IDs)
gws tasks tasks list --params '{"tasklist":"@default"}'     # tasks in the default list
gws tasks tasks insert --params '{"tasklist":"@default"}' --body '{"title":"..."}'
```
`@default` resolves to the primary "My Tasks" list; other lists use the `id` from `tasklists list`.

> Suggested safety habit (for when you build workflows): treat `list`/`get`/`+agenda` as free
> reads, and gate anything that sends/deletes/updates (`+send`, `+reply`, `events ... delete/patch`)
> behind an explicit confirm. A Claude Code permission allowlist in `.claude/settings.json` can
> auto-allow the read subcommands and prompt on the write ones — add that when you start combining.

---

## 4. Telegram bot (BotFather, ~3 min)

A Bot-API bot is an **isolated side-channel**: it can push messages to you and receive commands you
type *to it*, but it **cannot read your existing DMs/groups**. Safer than a user session and the
right tool for briefings + commands.

1. In Telegram, message **@BotFather** → `/newbot` → pick a name + a username ending in `bot`.
   Save the **token** it gives you (looks like `123456789:AA...`).
2. Get your **chat_id**: send your new bot any message, then:
   ```
   curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates" | jq '.result[0].message.chat.id'
   ```
   Save that integer.
3. Store both as single-line plaintext files in `~/.claude/` (✅ done — moved here from the
   old `~/brain/.env`, which is deleted; same pattern as `~/.claude/mimo_paygo_token`):
   ```
   ~/.claude/telegram_bot_token   # 123456789:AA...   (chmod 600)
   ~/.claude/telegram_chat_id     # 1057769032        (chmod 600)
   ```
   Consumers read env var first, else the file: `${TELEGRAM_BOT_TOKEN:-$(cat ~/.claude/telegram_bot_token)}`.
   Living outside the repo, they can't be committed or pushed by accident.
4. Send test (on-demand, polling — no webhook needed for a local setup):
   ```
   curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
     -H 'Content-Type: application/json' \
     -d "{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":\"command center online\"}"
   ```
   Optional upgrade later: the official `telegram@claude-plugins-official` plugin wraps this as
   first-class Claude tools.

If a token ever leaks: `@BotFather → /revoke` reissues it instantly.

---

## 5. Verify the plumbing

- ✅ `! gws auth status` → `has_refresh_token: true`, `project_id: brain-500508`, 9 scopes incl.
  `calendar`, `gmail.modify`, `tasks` (note: there is **no** `gws auth list` subcommand — `status`
  is the one that reports the authed account).
- ✅ `! gws calendar events list --params '{"calendarId":"primary"}'` → returns your events.
- ✅ `! gws gmail users messages list --params '{"userId":"me"}'` → returns message IDs.
- ✅ `! gws tasks tasklists list` + `gws tasks tasks list --params '{"tasklist":"@default"}'` → return
  your task lists and tasks.
- ✅ Telegram `sendMessage` curl above → "command center online ✅" delivered to chat_id
  `1057769032` (`"ok": true`).

All five pass — the data layer is done. You can now decide how to combine reads, writes, and
Telegram into whatever workflow you want.

> ⚠️ **Send scope:** only `gmail.modify` is granted, not `gmail.send`. `gmail.modify` *does* cover
> `messages.send`/drafts, so `+send`/`+reply` should work — but if a send ever 403s on scope,
> re-run `gws auth login` adding `gmail.send` to the `--services`/scope set.

## Secrets
`.gitignore` in this repo already excludes `client_secret*.json`, `*credentials*.json`,
`token*.json`, `.secrets/`, `.config/gws/`, `.env*`, and bot-token files. Keep the OAuth client
JSON and the bot token out of git; `gws`'s own store is encrypted but still sensitive.
