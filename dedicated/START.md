# Start working on dev-box

Checklist after `up.sh lockdown`. Run as the login user on `dev-box` unless noted. No repo copy and
no cutover: ongoing work finishes on `dev-box-1`; `dev-box` clones fresh from remotes. Nothing here
is committed to this repo: secrets, manifests and `.env` files stay private.

## a) Logins and secrets (you move or recreate these)

- [ ] `claude login` (headless URL flow).
- [ ] `codex login`.
- [ ] `gh auth login`, then `gh auth setup-git`.
- [ ] Git identity: `git config --global user.name; git config --global user.email` (set by `setup.sh`).
- [ ] `~/.ssh`: generate fresh keys where possible (`ssh-keygen -t ed25519`) and register the public
  keys with the services that need them. Do not copy the whole directory. Keep the key that
  `ssh dev-box` uses in `authorized_keys`.
- [ ] Google slots (`personal`, `angkin`, `pymc`, `ce`). `gws` and `gwsa` are installed and each
  slot holds only `email` + `scopes`. Run this yourself on `dev-box-1`; it copies only the
  credential files (they are encrypted with each slot's own `.encryption_key`, so they move together):
  ```
  for s in personal angkin pymc ce; do
    rsync -a --ignore-missing-args --chmod=D700,F600 \
      ~/.config/gws-accounts/$s/{client_secret.json,credentials.enc,.encryption_key,token_cache.json} \
      dev-box:.config/gws-accounts/$s/
  done
  ssh dev-box gwsa status --verify
  ```
  Any slot that does not verify (or has no `credentials.enc`), run `gwsa login <slot>` on `dev-box`.
  Both boxes run the daily `gwsa check --notify` cron, so expect duplicate pings until `dev-box-1`
  is retired (or remove its line with `crontab -e`).
- [ ] Token files under `~/.claude` (mode 600): `mimo_token`, `mimo_paygo_token` (only if used),
  `telegram_bot_token`, `telegram_chat_id`. Run one Telegram poller at a time.
- [ ] Per-repo `.env` files: recreate by hand in each repo after cloning (`.env.example` is in git).
- [ ] sieve key: from `dev-box-1`, `scp ~/.config/sieve/env dev-box:.config/sieve/env` (mode 600;
  `ssh dev-box mkdir -p -m 700 .config/sieve` first), then `ssh dev-box systemctl --user restart sieve`.
- [ ] Optional noVNC: `vncpasswd` (stored in `~/.vnc/passwd`).

## b) Clone `~/dev`

- [ ] From `dev-box-1`, copy the private manifest (never committed):
  `ssh dev-box mkdir -p -m 700 .config/dev-box && scp ~/.config/dev-box/repos.tsv dev-box:.config/dev-box/`
- [ ] On `dev-box`: `gh repo clone derwells/dev-box ~/dev/dev-box`, then
  `~/dev/dev-box/dedicated/clone-dev.sh --dry-run` and `~/dev/dev-box/dedicated/clone-dev.sh`
  (needs `gh` auth from (a); skips anything already present, so `dev-box` itself is skipped).
- [ ] Repos the inventory marks as having no remote are not in the manifest: push them to a new
  private remote from `dev-box-1` first, or decide to leave them behind.

## c) hq and fleet (deferred until the Rust port of fleet lands)

Do not install or run fleet on `dev-box` yet. When the port is ready:

- [ ] `~/dev/dev-box/dedicated/post-hq.sh ~/dev/hq`: installs `fleet.slice` and the hygiene timers
  (runs `fleet.py up`); fleet state starts fresh.
- [ ] `python3 ~/dev/hq/fleet/fleet.py doctor`.

## c2) Private services (user units, tailnet or loopback only)

- [ ] hqweb: `uv sync --project ~/dev/hq/web/server`, `pnpm install && pnpm build` in
  `~/dev/hq/web/client`, `sh ~/dev/hq/web/server/deploy/renew-cert.sh`, copy the three units from
  `~/dev/hq/web/server/deploy/` to `~/.config/systemd/user/`, then
  `systemctl --user enable --now hqweb.service hqweb-cert.timer`. Re-install the phone app from the
  new `https://dev-box.<tailnet>.ts.net:8766` address (push subscriptions are per address).
- [ ] sieve: `uv sync` in `~/dev/sieve`, render `contrib/sieve.service` per its README (PATH must
  reach uv, claude and fnm's codex), `systemctl --user enable --now sieve`, then after the logins in
  (a): `claude mcp add --scope user --transport http sieve http://127.0.0.1:8723/mcp` and the
  `[mcp_servers.sieve]` block in `~/.codex/config.toml`.

## d) Rebuild environments

- [ ] Per repo as needed: `uv sync` (Python) or `pnpm install` (Node); `playwright install` if its tests
  need a browser. Docker services and databases are recreated from each repo's own config.
- [ ] Targeted tests only, at most `pytest -n 2`.

## e) Smoke

- [ ] `tests/smoke-dedicated.sh` (as the user, on the box). From `dev-box-1`:
  `tests/smoke-dedicated.sh --probe <public-ip>` must show public ports closed.
- [ ] Reboot once and re-run the smoke.
