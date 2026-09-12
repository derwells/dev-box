# gws multi-account setup

Four Google accounts on this machine, each with an isolated credential store
("slot") for the `gws` CLI. The `gwsa` command (the `gwsa` script in this
repo, symlinked from `~/.local/bin/gwsa`) is the only interface you need.
Set up 2026-08-25.

| slot       | account                    | use for                              |
|------------|----------------------------|--------------------------------------|
| `personal` | drckwells@gmail.com        | default — brain project, personal    |
| `angkin`   | derick@angkin.ph           | angkin.ph business + Workspace admin |
| `pymc`     | derick.wells@pymc-labs.com | PyMC Labs work                       |
| `ce`       | dwells@consumer-edge.com   | Consumer Edge client project         |

## Daily use

```bash
gwsa <slot> <any gws command>      # gwsa pymc gmail users messages list --params '{"userId":"me"}'
gwsa status --verify               # health of all slots: creds, token, right account, scope drift
gwsa login <slot>                  # (re-)auth a slot; verifies you consented as the right account
gwsa token <slot>                  # fresh access token for raw REST (e.g. Admin SDK)
```

Bare `gws` = personal (`~/.config/gws` is a symlink to `personal/`).
**Never run bare `gws auth login` for a non-personal account** — it would
overwrite personal's credentials. Always `gwsa login <slot>`.

## Per-slot files

- `email` — expected account; `gwsa login`/`status --verify` check reality against it
- `scopes` — one scope URL per line, `#` comments. Edit, then `gwsa login <slot>` to re-consent
- `client_secret.json` — the shared Brain OAuth client (project `brain-500508`)
- `credentials.enc`, `token_cache.json`, `.encryption_key` — gws-managed secrets, per-dir
  (`GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file`, set by gwsa, keeps keys per-dir instead
  of a shared system-keyring entry)

## How it hangs together

- All slots share one OAuth client: the "Brain" app in personal GCP project
  `brain-500508` (External user type, **Testing** status). Accounts must be
  listed as **test users** on its consent screen (console → Audience) before
  they can log in.
- Testing status ⇒ refresh tokens expire ~every 7 days, per account.
  `gwsa status` shows which slots died; `gwsa login <slot>` revives (~30s).
- Non-personal accounts hold `roles/serviceusage.serviceUsageConsumer` on
  `brain-500508` (quota billing only, zero data access). Without it gws calls
  403 with "Caller does not have required permission to use project…".
- Workspace admin for angkin.ph: gws has no Admin SDK commands, so use
  `curl -H "Authorization: Bearer $(gwsa token angkin)" https://admin.googleapis.com/admin/directory/v1/...`
  Admin SDK + Groups Settings APIs are enabled on the project; the angkin
  scopes file carries the directory/groups scopes.
- Remote/Tailscale login gotcha: the OAuth callback listens on localhost on
  THIS box. Browser elsewhere ⇒ copy the localhost redirect URL and `curl` it
  here.

## Login longevity (research verdict, 2026-08-25)

The ~7-day re-login is escapable per account, not globally:

- **Workspace domains (angkin, pymc, ce)**: a domain admin marking the Brain
  app's OAuth client ID as **Trusted** (Admin console → Security → API
  controls → App access control) makes it "treated as an internal application"
  — Google's docs state this *overrides the 7-day refresh token expiration
  limit for apps in Testing status*. Do this for angkin.ph (own domain);
  worth asking PyMC Labs; don't bother the Consumer Edge client.
  Client ID: `648238085316-gjnor5vu6avlblafa6uv4u11gu00e3kr.apps.googleusercontent.com`
- **personal (@gmail.com)**: no clean escape — Internal apps need a Workspace
  org, and Production+unverified is blocked/danger-walled for Gmail's
  restricted scopes. Personal stays on the weekly cycle.
- Source: developers.google.com/identity/protocols/oauth2/production-readiness/overview

**Monitor**: cron runs `gwsa check --notify` daily at 08:30; it Telegram-pings
only when a previously-working slot's token has died, with the exact
`gwsa login <slot>` to run. Remove: `crontab -e`.

## Maintenance recipes

- **Add an account**: `mkdir <slot>`, write `email` + `scopes`, copy any
  slot's `client_secret.json`, add the account as a test user in the console,
  grant it serviceUsageConsumer (below), then `gwsa login <slot>`.
- **Offboard an account** (e.g. leaving the client): delete the slot dir, then
  ```
  gcloud projects remove-iam-policy-binding brain-500508 \
    --member=user:<email> --role=roles/serviceusage.serviceUsageConsumer \
    --account=drckwells@gmail.com --billing-project=brain-500508
  ```
  and remove it from the app's test users in the console.
- **Change scopes**: edit `<slot>/scopes`, run `gwsa login <slot>`. Keep the
  total modest — testing-mode apps cap out around ~25 scopes at consent.
- **This dir is a git repo**: config and docs are tracked; every secret is
  gitignored. Commit when you change scopes/emails/README.

Referenced from `~/.claude/CLAUDE.md` (hint) and
`~/.claude/skills/brain/SKILL.md` (operating manual).
