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
- [ ] Google slots: for each of `personal`, `angkin`, `pymc`, `ce`, drop the shared OAuth client JSON
  into `~/.config/gws-accounts/<slot>/`, then `gwsa login <slot>`. Check with `gwsa status --verify`.
- [ ] Token files under `~/.claude` (mode 600): `mimo_token`, `mimo_paygo_token` (only if used),
  `telegram_bot_token`, `telegram_chat_id`. Run one Telegram poller at a time.
- [ ] Per-repo `.env` files: recreate by hand in each repo after cloning (`.env.example` is in git).
- [ ] Optional noVNC: `vncpasswd` (stored in `~/.vnc/passwd`).

## b) Clone `~/dev`

- [ ] From `dev-box-1`, copy the private manifest (never committed):
  `ssh dev-box mkdir -p -m 700 .config/dev-box && scp ~/.config/dev-box/repos.tsv dev-box:.config/dev-box/`
- [ ] On `dev-box`: `gh repo clone derwells/dev-box ~/dev/dev-box`, then
  `~/dev/dev-box/dedicated/clone-dev.sh --dry-run` and `~/dev/dev-box/dedicated/clone-dev.sh`
  (needs `gh` auth from (a); skips anything already present, so `dev-box` itself is skipped).
- [ ] Repos the inventory marks as having no remote are not in the manifest: push them to a new
  private remote from `dev-box-1` first, or decide to leave them behind.

## c) hq and fleet

- [ ] `~/dev/dev-box/dedicated/post-hq.sh ~/dev/hq`: installs `fleet.slice` and the hygiene timers
  (runs `fleet.py up`); fleet state starts fresh.
- [ ] `python3 ~/dev/hq/fleet/fleet.py doctor`.

## d) Rebuild environments

- [ ] Per repo as needed: `uv sync` (Python) or `pnpm install` (Node); `playwright install` if its tests
  need a browser. Docker services and databases are recreated from each repo's own config.
- [ ] Targeted tests only, at most `pytest -n 2`.

## e) Smoke

- [ ] `tests/smoke-dedicated.sh` (as the user, on the box). From `dev-box-1`:
  `tests/smoke-dedicated.sh --probe <public-ip>` must show public ports closed.
- [ ] Reboot once and re-run the smoke.
