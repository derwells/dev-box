# Dedicated (Hetzner Robot) path: design

Agreed brief for the `hq-devbox-setup` effort. Source: `~/dev/hq/docs/briefs/hq-devbox-setup.md`
(Derick, 2026-10-12) and `~/dev/hq/docs/reviews/devbox-upgrade-2026-10.md`.

Amendment `hq-devbox-setup-3` (chief on Derick's OK, 2026-10-12): **applied**, verified. dev-box-1's
OS hostname is `dev-box-1`, `/etc/hosts` line 8 is `127.0.1.1 dev-box-1 dev-box-1`, and dev-box-1's
`~/.ssh/config` maps `Host dev-box` to `dev-box.<tailnet>.ts.net` (user derick, key
`~/.ssh/dev-box_ed25519`). So `ssh dev-box` from dev-box-1 reaches the new node once it joins;
bootstrap must leave that key in derick's authorized_keys. Supersedes the hostname caveat in -1.

Amendment `hq-devbox-setup-2` (chief, 2026-10-12): **applied**. Key file is `~/.ssh/dev-box_ed25519`, same
fingerprint SHA256:916R5RzxOo6mrL4ptGwfm1P2DDZbwbz9AFHf8rN1ydU.

Amendment `hq-devbox-setup-1` (Derick via chief, 2026-10-12 07:5xZ): **applied**. The new server is
named `dev-box` (hostname, Tailscale node, Robot key name, docs); the current machine is `dev-box-1`.

Target: Hetzner EX44-1-LTD (i5-13500, 64 GB, 2 x 512 GB NVMe), Robot-managed, no cloud-init,
no OpenTofu resource. Tailscale name `dev-box`. The hcloud path (`main.tf`,
`cloud-init.yaml.tftpl`) stays intact and is not applied.

## Flow (one command per phase, run from any machine holding the key)

```
dedicated/up.sh install   <public-ip>   # from Robot rescue: installimage + reboot
dedicated/up.sh provision <public-ip>   # after reboot: bootstrap.sh then setup.sh
dedicated/up.sh lockdown  <public-ip>   # after `tailscale up` is approved: drop public 22
```

`DEVBOX_KEY` (default `~/.ssh/dev-box_ed25519`) is the SSH identity. Each phase uploads
`files/`, `setup.sh` and `dedicated/` to `/root/provision` + `/root/` exactly as `main.tf` does.

## Disk layout (lesson 1: two filesystems, no RAID0, no mirror)

- `installimage.conf`: Ubuntu 24.04, `SWRAID 0`, DRIVE1 only partitioned: `/boot` 1G ext4,
  `/` all ext4. Hostname `dev-box`.
- nvme0n1 (`/`): `/home`, `~/dev`, worktrees, uv cache (`~/.uv-cache`, same fs so hard links
  work), `/swapfile` 16 GiB (`chmod 600`, fstab, `vm.swappiness=10`).
- nvme1n1 (`/data`): ext4 by UUID, `nofail`. Holds `/data/docker` and `/data/containerd`
  (bind-mounted onto `/var/lib/docker`, `/var/lib/containerd`, mounted before docker/containerd
  start), and `/data/home/<user>/{.cache,.npm}` with `~/.cache` and `~/.npm` symlinks, mirroring
  `data-volume.sh` paths with `/data` in place of `/mnt/data`. Also symlink `/mnt/data` -> `/data`
  so absolute paths copied from dev-box-1 (`/mnt/data/home/derick/...`) still resolve.
- Device identification must not assume nvme0 is the root disk: find the root disk via
  `findmnt -no SOURCE /`, pick the other NVMe disk, refuse to format if it has a partition table
  or filesystem unless `--force-data-disk` is given.

## bootstrap.sh (replaces cloud-init on this path)

Root, idempotent, args `<username> <ssh_pubkey_file>`:
- User with UID/GID 1000 (match dev-box-1, for rsync `--numeric-ids`), sudo NOPASSWD, zsh
  installed but login shell switched last by setup.sh, authorized_keys from root's.
- Same apt packages as `cloud-init.yaml.tftpl` plus: docker-ce + containerd.io (Docker apt repo,
  user in `docker` group), git-delta, build-essential, rsync, htop, ncdu.
- gh (apt repo), Tailscale (install script). Do not run `tailscale up` non-interactively; print
  the instruction `tailscale up --hostname dev-box` (the operator relays the login URL).
- UFW: deny incoming, allow outgoing, allow in on tailscale0, allow 22/tcp (removed by lockdown).
- Data disk + swap as above, then docker/containerd bind mounts, then `systemctl enable docker`.
- Calls `setup.sh <user> <git name> <git email>` (args passed through by up.sh, defaults
  `derwells` / `drckwells@gmail.com`; read from `terraform.tfvars` only if present - never print it).

## setup.sh changes (shared, must stay valid for the hcloud path)

- Codex CLI: `npm install -g @openai/codex` via run_node, and ensure `~/.codex/config.toml` has
  `[tui] alternate_screen = "never"` and `fullscreen_transcript = false` (lesson 3) without
  clobbering an existing file (append/merge the `[tui]` table keys only).
- noVNC: `vncserver -localhost yes`; websockify binds the tailnet address, not 0.0.0.0
  (wait for `tailscale ip -4` in ExecStartPre / sh -c wrapper). Lesson 4.
- Leave everything else as is.

## lockdown

After Tailscale SSH works: `ufw delete allow 22/tcp`, verify `ufw status`, verify from the
operator's machine that `ssh dev-box` over Tailscale still works before returning. Recovery
if Tailscale breaks: Robot rescue system.

## Not in this repo (installed from hq after migration, step 3/4)

`fleet.slice` (`fleet.py up`), `fleet-hygiene` / `fleet-hygiene-uv` timers
(`hygiene.py install-timer`, `install-uv-timer`), worktree cleanup CLI and codex release pruning
all come from `~/dev/hq` once it is copied. `dedicated/post-hq.sh` (user) runs those installers
and is part of the smoke.

## Smoke (`tests/smoke-dedicated.sh`, run on the box as the user)

Prints PASS/FAIL per check, non-zero exit on any FAIL: hostname, tailscale up as dev-box,
`swapon --show` has 16G `/swapfile`, `/` and `/data` are distinct devices, docker data-root under
`/data`, `~/.cache` -> `/data/...`, UFW has no public 22 (after lockdown), noVNC/websockify not
listening on 0.0.0.0, devbox-guard drop-ins + devbox-iocost active, fleet.slice + hygiene timers
present (after post-hq), and `claude codex uv pnpm gh tmux node docker` on PATH with versions,
Playwright chromium installed, codex `[tui]` keys set.

## Security: Tailscale-only (Derick, 2026-10-12: "secured by tailscale too to avoid hackers")

Goal: nothing on the public IP accepts connections once bootstrap ends. Layers:

1. **Robot firewall** (Derick sets it in Robot, network level, survives OS mistakes): inbound allow
   only TCP 22 from dev-box-1's public IP during bootstrap, plus established/related and
   outbound; delete the 22 rule at lockdown. Tailscale needs no inbound port.
2. **UFW**: deny incoming, allow in on `tailscale0`; bootstrap allows 22 only
   `from <dev-box-1 public IP>`, never from anywhere; lockdown deletes it.
3. **Docker bypasses UFW** (it writes its own iptables rules). dev-box-1 publishes Supabase on
   `0.0.0.0:5432x` and is shielded only by the Hetzner Cloud firewall; the dedicated box has no
   cloud firewall. So: `/etc/docker/daemon.json` `"ip": "127.0.0.1"` (default publish address)
   and a `DOCKER-USER` iptables rule that drops new inbound from the public interface
   (persisted via a small systemd unit after docker.service).
4. **sshd**: keys only (`PasswordAuthentication no`, `KbdInteractiveAuthentication no`),
   `PermitRootLogin prohibit-password` during bootstrap, `no` at lockdown. Day-to-day access is
   Tailscale SSH.
5. **Services** (noVNC, VNC, hqweb, sieve, paseo) bind the tailnet IP or localhost, never 0.0.0.0.
6. `unattended-upgrades` enabled for security updates.

Smoke adds: `ss -tlnH` shows no listener on 0.0.0.0/[::] except sshd (firewalled), `DOCKER-USER`
drop rule present, docker `ip` = 127.0.0.1, sshd password auth off, and an external probe from
dev-box-1 to the public IP on 22 and the Docker ports times out after lockdown.

## Tailnet SSH: OpenSSH, not Tailscale SSH (lead decision, 2026-10-12)

dev-box-1 runs `RunSSH=false`: tailnet ssh is plain OpenSSH with keys. dev-box matches it
(`tailscale up --hostname dev-box`, no `--ssh`). Tailscale SSH's default ACL action is `check`,
which needs a periodic browser re-auth and would block unattended agent ssh/rsync from dev-box-1.
Public 22 is still closed by UFW (and the Robot firewall); sshd is keys-only.
