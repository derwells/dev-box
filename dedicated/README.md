# Dedicated (Hetzner Robot) path

Provisions `dev-box` on a Hetzner Robot server (EX44-1-LTD, 2 x NVMe) with no cloud-init and no
OpenTofu resource. Design and rationale: [`DESIGN.md`](DESIGN.md). The hcloud path (`main.tf`) is
unchanged. The current machine is `dev-box-1`.

SSH identity: `DEVBOX_KEY` (default `~/.ssh/dev-box_ed25519`).

## Layer 1: Robot firewall (set by hand in Robot, not scripted)

Network-level, survives OS mistakes. Before bootstrap, in Robot → Server → Firewall:

- Inbound allow TCP 22 from dev-box-1's public IP only, plus established/related.
- Allow outbound; everything else inbound is dropped.
- Delete the 22 rule after `up.sh lockdown` succeeds. Tailscale needs no inbound port.

## Phases

```bash
# 1. Robot: activate the rescue system for the server (add your key), reset the server.
dedicated/up.sh install   <public-ip>   # installimage.conf -> installimage -> reboot
dedicated/up.sh provision <public-ip>   # uploads files/, setup.sh, dedicated/; runs bootstrap.sh -> setup.sh
# 2. On the box as root:  tailscale up --hostname dev-box   (open the URL, approve the node)
dedicated/up.sh lockdown  <public-ip>   # removes public 22, sets PermitRootLogin no, verifies Tailscale ssh
```

Env knobs: `DEVBOX_USER` (default `derick`), `GIT_USER_NAME` / `GIT_USER_EMAIL`,
`BOOTSTRAP_ALLOW_IP` (required: the operator machine's public IP, the only public source allowed on 22),
`DEVBOX_TS_HOST` (Tailscale name or FQDN used by lockdown; set it where a bare `dev-box` resolves
to the local machine, as on dev-box-1), `FORCE_DATA_DISK=1`.

`install` formats the first NVMe. `provision` is re-runnable: every step is idempotent.

## Files

- `installimage.conf`: Ubuntu 24.04, `SWRAID 0`, DRIVE1 only, `/boot` 1G + `/` ext4, hostname `dev-box`.
- `up.sh`: the three phases above.
- `bootstrap.sh`: user (uid 1000), apt packages, Docker, gh, Tailscale (no `tailscale up`), UFW,
  sshd hardening, DOCKER-USER drop, unattended-upgrades, then `data-disk.sh` and `setup.sh`.
- `data-disk.sh`: second NVMe -> `/data` (+ `/mnt/data` symlink), `~/.cache` and `~/.npm` moved
  there, docker/containerd bind mounts, 16G `/swapfile`. `--dry-run` prints the steps. It derives
  the root disk from `findmnt /`, never touches it, and refuses a disk that already has a partition
  table or filesystem unless `--force-data-disk`.
- `post-hq.sh`: run as the user after `~/dev/hq` is cloned and fleet's Rust port has landed; builds
  the native `fleet` from hq's `fleet-rs` into `~/.local/bin`, then runs `fleet up` (once Claude is
  logged in), `fleet service install` and `fleet doctor`. `--hygiene` also installs the two hygiene
  timers.

## Security: Tailscale-only

Nothing on the public IP accepts connections once lockdown has run.

1. Robot firewall (above).
2. UFW: deny incoming, allow in on `tailscale0`; 22/tcp only from `BOOTSTRAP_ALLOW_IP` until lockdown.
3. Docker bypasses UFW, so `/etc/docker/daemon.json` sets `"ip": "127.0.0.1"` and
   `devbox-docker-user.service` re-applies a `DOCKER-USER` rule dropping new inbound on the public
   interface after each docker start.
4. sshd: keys only; `PermitRootLogin prohibit-password` until lockdown, then `no`.
5. Services (noVNC, VNC) bind the tailnet IP or localhost.
6. `unattended-upgrades` enabled.

Recovery if Tailscale breaks after lockdown: Robot rescue system.

## Smoke

```bash
tests/smoke-dedicated.sh                      # on the box, as the user
tests/smoke-dedicated.sh --probe <public-ip>  # from dev-box-1: public ports must be closed
```
