# Switch over to dev-box

The order to follow when moving from `dev-box-1` to `dev-box`, as of 2026-10-12. Each item shows who
does it (**lead** or **Derick**) and when: **now**, or **Rust** (after the Rust port of fleet lands).
`[x]` means done and verified. No logs, session history, fleet state or Docker volumes move. Repos
are cloned fresh. Secrets, manifests and `.env` files never enter this repo.

**How secrets move.** aide's Paste flow (hq `aide/README.md`, "Asking Derick for a key") saves a
value on the machine aide runs on, which is `dev-box-1` until aide moves. A Paste therefore cannot
put a value on `dev-box`. Values that already exist are copied file to file, under Derick's
2026-10-12 permission, and never opened or printed. Paste is only for values that exist nowhere yet
(new or rotated keys). None are needed now. Claude and Codex OAuth logins are never copied.

## 1. Base

- [x] `up.sh install`, `provision`, Tailscale node `dev-box`, `lockdown`. **lead**
- [x] Logins: `claude login`, `codex login`, `gh auth login` + `gh auth setup-git`. **Derick**
- [x] Repos cloned from the private manifest (`~/.config/dev-box/repos.tsv`, `clone-dev.sh`), with
  every HEAD equal to origin and every tree clean. **lead**
- [ ] Settle the push list on `dev-box-1` (`~/.config/dev-box/push-list.md`): repos with no remote,
  client repos, protected branches, one diverged branch. **Derick, now**

## 2. Secrets

- [x] Google slots `personal` and `pymc`: credential files copied, `gwsa status --verify` OK. **lead**
- [ ] `angkin`: its refresh token is expired on both machines. Run `gwsa login angkin` on `dev-box`.
  **Derick, now**
- [ ] `ce`: never logged in (its client secret is copied). Run `gwsa login ce` on `dev-box`. **Derick, now**
- [x] TypeSafe key for sieve: `~/.config/sieve/env` plus the `.env` it sources. **lead**
- [x] SSH keys still in use: the SiteGround key and one other deploy key, mode 600. `dev-box_ed25519`
  stays where it is; `gcloud compute ssh` makes its own key on first use. **lead**
- [x] `~/.claude` token files (Telegram, MiMo, provider and tool API keys). The dead `hcloud_token`
  was left behind. **lead**
- [x] Per-repo `.env` files for every cloned repo where git ignores `.env` (one repo tracks its own).
  Repos with no remote are not cloned, so their `.env` waits on the push list. **lead**
- [ ] aide Discord token (`~/.config/aide/discord_token`) and `~/.config/aide/config.toml`: copy when
  aide moves (section 4). **lead, Rust**
- [ ] Notion MCP: authorize it with `/mcp` inside `claude`. **Derick, now**
- [ ] Optional: `vncpasswd` for noVNC. **Derick, now**

## 3. Config

- [x] `~/.claude/settings.json` (everything except hooks), `output-styles/`, `rules/`; user MCP
  servers `daimon` and `sieve`. **lead**
- [x] Personal skills in `~/.claude/skills`, linked from `~/.agents/skills`. Git-backed skills are
  cloned from their remotes. Paseo skills are left out. **lead**
- [x] `~/.codex/config.toml` top-level settings (model, approvals, sandbox, effort) merged above
  `[tui]`. Codex re-adds project trust entries on first use. **lead**
- [x] `setup.sh` re-run with this branch, so `files/` (claudex search, model-check, shared
  instructions) matches the repo. **lead**
- [ ] hq-owned skills (`chief`, `lead`, `dispatch`, `advise`, `research-fanout`, `discord-catchup`),
  Claude fleet hooks (`readonly_approve`, `delegation_guard`), Codex `hooks.json` and the
  `{low,medium,high}.config.toml` profiles. They call fleet, and the port changes their paths.
  **lead, Rust**
- [ ] Optional: the Android binder module, needed only for Android emulator work:
  `apt install linux-modules-extra-$(uname -r)`, `modprobe binder_linux`, then persist it in
  `/etc/modules-load.d/`. **lead, now on request**

## 4. Services and timers

User units only, bound to loopback or the tailnet address.

- [x] sieve, with its SearXNG container (`bin/sieve-searxng start`, loopback). **lead**
- [x] `gwsa check --notify` cron (08:30), installed by `setup.sh`. Both machines ping until
  `dev-box-1` is gone. **lead**
- [ ] fleet-watch and `fleet.slice`: `dedicated/post-hq.sh ~/dev/hq` (builds the native `fleet`,
  then `fleet up`, `fleet service install`, `fleet doctor`). **lead, Rust**
- [ ] `fleet-hygiene` and `fleet-hygiene-uv` timers. Derick said on 2026-10-12 they are not needed;
  the port keeps them, so `post-hq.sh --hygiene` installs them if wanted. **Derick decides, Rust**
- [ ] hqweb and `hqweb-cert.timer`: merge hq PR #118, `uv sync` in `web/server`,
  `pnpm install && pnpm build` in `web/client`, `deploy/renew-cert.sh`, copy the units from
  `web/server/deploy/`, then enable them. **lead, Rust.** Afterwards, reinstall the phone app from
  the new address (push subscriptions are per address). **Derick**
- [ ] aide: run `aide/install.sh`, copy the token and config (section 2), stop it on `dev-box-1`,
  then enable it on `dev-box`. Never run both, because they would post twice. **lead, Rust**
- [ ] alpha-mill daily timer: it sends a fleet `say`, so its effort recreates it once fleet runs.
  **lead, Rust**
- [ ] The nightly Fly backup timer (`*-fly-backup`): needs `flyctl` (**lead**) and `fly auth login`
  (**Derick**). Keep it only if that app's backups still matter, since its bot is not moving.
  **Derick decides, now**
- Not moving: the one-off `default-*` timers, paseo, and that app's bot.

## 5. Docker

- [ ] Rebuild each stack from its repo's compose or Supabase config when that work starts. No volume
  copy; databases start empty. For example, the discord-bot Supabase stack: install the Supabase
  CLI, then run `supabase start` in its repo. Docker publishes on 127.0.0.1 here, so ports that were
  public on `dev-box-1` stay local. **lead, now (on demand)**
- [ ] Per repo: `uv sync` or `pnpm install`; `playwright install` if needed. Run targeted tests only,
  at most `pytest -n 2`. **lead, now (on demand)**

## 6. Chief

- [ ] Start a fresh chief on `dev-box` with the ported fleet. No fleet state is copied. **Derick, Rust**

## 7. Kill week for dev-box-1

1. [ ] Ongoing efforts finish or hand off. Re-run `dev-inventory.py` on `dev-box-1`, push anything
   safe, and settle the rest of the push list. **lead + Derick**
2. [ ] On `dev-box-1`: stop aide (only after it runs on `dev-box`), remove the `gwsa check` crontab
   line, and disable the remaining timers. **lead**
3. [ ] On `dev-box`: run `tests/smoke-dedicated.sh`, reboot, and run it again. From the laptop:
   `tests/smoke-dedicated.sh --probe <public-ip>` must show every public port closed. **lead**
4. [ ] Delete the Cloud server (`tofu destroy` from the laptop, or the Hetzner console) and remove
   its Tailscale node. **Derick**
5. [ ] Delete the legacy hcloud files from this repo and the local tofu state. **lead**
6. [ ] Laptop: remove `dev-box-1` from `~/.ssh/config`. **Derick**
