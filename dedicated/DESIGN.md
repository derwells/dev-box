# Dedicated (Hetzner Robot) path: decisions

Target: Hetzner EX44-1-LTD (i5-13500, 64 GB, 2 x 512 GB NVMe), Robot-managed, no cloud-init, no
OpenTofu resource. Tailscale name `dev-box`. The legacy hcloud path (`main.tf`,
`cloud-init.yaml.tftpl`) stays intact and is not applied here. Usage is in [`README.md`](README.md);
first steps after lockdown are in [`START.md`](START.md).

## Amendments (newest first)

- `hq-devbox-setup-12` (2026-10-12): applied. Order: update all repos first (push the safe
  ones from `dev-box-1`, list the rest for Derick), then clone and verify on `dev-box`. Do not install or
  run fleet on `dev-box` until hq's Rust port lands; smoke reports those checks as `DEFER`. Supersedes
  the fleet part of -11 (fleet units, hygiene timers and hqweb were removed from `dev-box`).
- `hq-devbox-setup-11` (2026-10-12): applied. gh, Claude and Codex logged in on `dev-box`.
- `hq-devbox-setup-10` (2026-10-12): applied. `gws` on PATH for non-interactive shells; smoke checks
  `gws` and the four `gwsa` slots.
- Derick, 2026-10-12: agents may copy static secret files between his machines, without reading or
  printing them (supersedes the brief's "Derick transfers secrets himself"); the sieve key was copied.
- `hq-devbox-setup-9` (2026-10-12): applied. Node approved as `dev-box`; public 22 locked down.
- `hq-devbox-setup-8` (2026-10-12): applied. This branch's history was rewritten to drop an IP and a
  tailnet name; `main` was checked and left alone.
- `hq-devbox-setup-7` (2026-10-12): applied. No rsync of repos or state; ongoing work finishes on
  `dev-box-1`. On `dev-box`, repos are cloned fresh from their remotes by `clone-dev.sh` from a
  private manifest (`~/.config/dev-box/repos.tsv`, made by `dev-inventory.py`, never committed).
  No cutover runbook or freeze window. Supersedes the payload part of -6.
- `hq-devbox-setup-6` (2026-10-12): applied. Only git repos move; no session history, logs,
  Docker volumes or database data. Superseded by -7 except the two-filesystem layout, which stays.
- `hq-devbox-setup-3` (2026-10-12): applied. `dev-box-1` OS hostname is `dev-box-1`, so
  `ssh dev-box` from it reaches the new node once it joins; bootstrap keeps the SSH key in the
  login user's `authorized_keys`.
- `hq-devbox-setup-2` (2026-10-12): applied. SSH key file is `~/.ssh/dev-box_ed25519`.
- `hq-devbox-setup-1` (2026-10-12): applied. New server is `dev-box` (hostname, Tailscale node,
  Robot key name, docs); the old Cloud machine is `dev-box-1`.

## Decisions

**Flow.** Three phases from any machine holding the key: `up.sh install` (rescue system,
installimage), `up.sh provision` (upload `files/`, `setup.sh`, `dedicated/`; run `bootstrap.sh`
then `setup.sh`), `up.sh lockdown` (drop public 22 once Tailscale works).

**Disk layout.** Two filesystems, no RAID0, no mirror. `installimage.conf` partitions DRIVE1 only
(`/boot` 1G, `/` ext4). Root holds `/home`, `~/dev`, worktrees, the uv cache (`~/.uv-cache`, same fs
so hard links work) and a 16 GiB `/swapfile` (`vm.swappiness=10`). The second NVMe mounts at `/data`
(ext4 by UUID, `nofail`) and holds Docker/containerd (bind mounts) and `~/.cache`, `~/.npm`
(symlinks); `/mnt/data` -> `/data` keeps paths from the cloud box valid. `data-disk.sh` finds the
root disk with `findmnt` and refuses a disk with a partition table or filesystem unless
`--force-data-disk`.

**bootstrap.sh replaces cloud-init.** User with UID/GID 1000, sudo NOPASSWD, same apt packages
plus Docker, gh, Tailscale. It never runs `tailscale up` non-interactively; it prints
`tailscale up --hostname dev-box` for the operator.

**setup.sh stays shared** with the hcloud path. Dedicated-driven changes: Codex CLI with
`[tui] alternate_screen = "never"` merged without clobbering; noVNC binds the tailnet address, not
0.0.0.0.

**Not in this repo.** The private hq repo installs `fleet.slice` and the hygiene timers after it is
cloned; `post-hq.sh` runs those installers.

**Tailscale-only security.** Nothing on the public IP accepts connections after lockdown.
1. Robot firewall (set by hand): inbound TCP 22 from the operator IP during bootstrap only.
2. UFW: deny incoming, allow in on `tailscale0`; 22/tcp only from `BOOTSTRAP_ALLOW_IP` until
   lockdown deletes it.
3. Docker bypasses UFW: `daemon.json` `"ip": "127.0.0.1"` plus a `DOCKER-USER` drop rule for new
   inbound on the public interface, re-applied after each docker start.
4. sshd keys only; `PermitRootLogin prohibit-password` until lockdown, then `no`.
5. Services (noVNC, VNC and others) bind the tailnet IP or localhost, never 0.0.0.0.
6. `unattended-upgrades` on. Recovery if Tailscale breaks: Robot rescue system.

**OpenSSH over the tailnet, not Tailscale SSH** (lead decision, 2026-10-12). `tailscale up
--hostname dev-box` without `--ssh`, matching `dev-box-1`. Tailscale SSH's default ACL action
`check` needs periodic browser re-auth and would block unattended agent ssh/rsync.

**Smoke** (`tests/smoke-dedicated.sh`, as the user): hostname, tailscale, swap, distinct `/` and
`/data`, docker data-root, UFW without public 22, no 0.0.0.0 listeners except sshd, DOCKER-USER
rule, sshd password auth off, devbox-guard active, tool versions. `--probe <public-ip>` from
another machine checks public ports are closed.
