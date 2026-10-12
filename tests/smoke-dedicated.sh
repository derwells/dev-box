#!/usr/bin/env bash
# smoke-dedicated.sh — acceptance smoke for the dedicated (Robot) dev-box.
#
#   smoke-dedicated.sh                      # on the box, as the user (needs passwordless sudo)
#   smoke-dedicated.sh --probe <public-ip>  # from another machine: public ports must time out
#
# Env: SMOKE_PROBE_PORTS (space list, default "22 80 443 5432 54321 54322 54323 6080 5901 8080")
# Prints PASS/FAIL/SKIP per check; exits non-zero on any FAIL.
set -uo pipefail

FAILS=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; FAILS=$((FAILS + 1)); }
skip() { echo "SKIP  $*"; }
check() {  # check <desc> <cmd...>
  local d=$1; shift
  if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi
}

if [ "${1:-}" = "--probe" ]; then
  IP=${2:?usage: --probe <public-ip>}
  for port in ${SMOKE_PROBE_PORTS:-22 80 443 5432 54321 54322 54323 6080 5901 8080}; do
    if timeout 5 bash -c "exec 3<>/dev/tcp/$IP/$port" 2>/dev/null; then
      fail "public $IP:$port accepts connections"
    else
      pass "public $IP:$port closed/filtered"
    fi
  done
  [ "$FAILS" -eq 0 ] || { echo "$FAILS check(s) failed"; exit 1; }
  exit 0
fi

SUDO=""; [ "$(id -u)" = 0 ] || SUDO="sudo -n"

# --- identity / network
[ "$(hostname)" = dev-box ] && pass "hostname is dev-box" || fail "hostname is $(hostname), want dev-box"
if command -v tailscale >/dev/null 2>&1 && tailscale status --json 2>/dev/null | jq -e '.BackendState=="Running" and (.Self.HostName=="dev-box")' >/dev/null 2>&1; then
  pass "tailscale running as dev-box"
else
  fail "tailscale not running as dev-box"
fi

# --- storage
swapon --show --noheadings --bytes 2>/dev/null | awk '$1=="/swapfile" && $3>=16*1024^3-1048576 {ok=1} END {exit !ok}' \
  && pass "16G /swapfile active" || fail "16G /swapfile not active"
[ "$(findmnt -no SOURCE /)" != "$(findmnt -no SOURCE /data 2>/dev/null)" ] && mountpoint -q /data \
  && pass "/ and /data are distinct mounts" || fail "/ and /data are not distinct devices"
disk_of() {  # whole disk under a mount; /data is a whole-disk filesystem with no PKNAME
  local src pk; src=$(findmnt -no SOURCE "$1" 2>/dev/null) || return 0
  pk=$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1)
  [ -n "$pk" ] && echo "$pk" || basename "$src"
}
root_dev=$(disk_of /); data_dev=$(disk_of /data)
[ -n "$root_dev" ] && [ -n "$data_dev" ] && [ "$root_dev" != "$data_dev" ] \
  && pass "/ ($root_dev) and /data ($data_dev) on different disks" || fail "/ and /data share a disk"
root="$(docker info -f '{{.DockerRootDir}}' 2>/dev/null)"
[ "$root" = /var/lib/docker ] && findmnt -no SOURCE /var/lib/docker 2>/dev/null | grep -q '^/dev/.*\[/docker\]$' \
  && pass "docker data-root bind-mounted from /data" || fail "docker data-root not on /data (root=$root)"
[ "$(readlink -f "$HOME/.cache")" = "$(readlink -f /data/home/$USER/.cache)" ] \
  && pass "~/.cache -> /data" || fail "~/.cache is not on /data"
[ "$(readlink -f "$HOME/.npm")" = "$(readlink -f /data/home/$USER/.npm)" ] \
  && pass "~/.npm -> /data" || fail "~/.npm is not on /data"

# --- security: Tailscale-only
if $SUDO ufw status 2>/dev/null | grep -E '(^|[[:space:]])22(/tcp)?[[:space:]]' | grep -v tailscale0 | grep -q .; then
  fail "UFW still has a public 22 rule (run up.sh lockdown)"
else
  pass "UFW has no public 22 rule"
fi
$SUDO ufw status 2>/dev/null | grep -q 'tailscale0.*ALLOW' && pass "UFW allows tailscale0" || fail "UFW lacks allow on tailscale0"
$SUDO ufw status verbose 2>/dev/null | grep -q 'deny (incoming)' && pass "UFW default deny incoming" || fail "UFW default is not deny incoming"
bad=$(ss -tlnH 2>/dev/null | awk '{print $4}' | grep -E '^(0\.0\.0\.0|\[::\]|\*):' | grep -Ev ':22$' || true)
[ -z "$bad" ] && pass "no wildcard listener except sshd" || fail "wildcard listeners: $(echo "$bad" | tr '\n' ' ')"
ss -tlnH 2>/dev/null | awk '{print $4}' | grep -E '^(0\.0\.0\.0|\[::\]|\*):(6080|5901)$' >/dev/null \
  && fail "noVNC/VNC listening on all interfaces" || pass "noVNC/websockify not on 0.0.0.0"
$SUDO iptables -S DOCKER-USER 2>/dev/null | grep -q 'devbox-public-drop' && pass "DOCKER-USER public drop rule present" || fail "DOCKER-USER drop rule missing"
[ "$(jq -r .ip /etc/docker/daemon.json 2>/dev/null)" = 127.0.0.1 ] && pass "docker default publish ip is 127.0.0.1" || fail "docker daemon.json ip != 127.0.0.1"
sshd_t=$($SUDO sshd -T 2>/dev/null)
echo "$sshd_t" | grep -qx 'passwordauthentication no' && pass "sshd password auth off" || fail "sshd password auth not off"
echo "$sshd_t" | grep -qx 'kbdinteractiveauthentication no' && pass "sshd kbd-interactive off" || fail "sshd kbd-interactive not off"
echo "$sshd_t" | grep -qx 'permitrootlogin no' && pass "sshd root login off" || fail "sshd PermitRootLogin is not no (set by lockdown)"
systemctl is-enabled unattended-upgrades >/dev/null 2>&1 && pass "unattended-upgrades enabled" || fail "unattended-upgrades not enabled"

# --- guard / fleet
for u in ssh tailscaled; do
  [ -f "/etc/systemd/system/$u.service.d/90-devbox-guard.conf" ] && pass "devbox-guard drop-in: $u" || fail "devbox-guard drop-in missing: $u"
done
systemctl is-active devbox-iocost.service >/dev/null 2>&1 && pass "devbox-iocost active" || fail "devbox-iocost not active"
if systemctl --user cat fleet.slice >/dev/null 2>&1; then pass "fleet.slice present"; else fail "fleet.slice missing (run post-hq.sh)"; fi
systemctl --user list-timers --all --no-pager 2>/dev/null | grep -q 'fleet-hygiene' && pass "fleet-hygiene timer present" || fail "fleet-hygiene timer missing (run post-hq.sh)"
systemctl --user list-timers --all --no-pager 2>/dev/null | grep -q 'fleet-hygiene-uv' && pass "fleet-hygiene-uv timer present" || fail "fleet-hygiene-uv timer missing (run post-hq.sh)"

# --- tools
for t in claude codex uv pnpm gh tmux node docker; do
  if command -v "$t" >/dev/null 2>&1; then
    v=--version; [ "$t" = tmux ] && v=-V
    pass "$t: $("$t" "$v" 2>&1 | head -n1)"
  else
    fail "$t not on PATH"
  fi
done
ls "$HOME"/.cache/ms-playwright/chromium-* >/dev/null 2>&1 && pass "Playwright chromium installed" || fail "Playwright chromium missing"
cfg="$HOME/.codex/config.toml"
grep -qE '^alternate_screen *= *"never"' "$cfg" 2>/dev/null && grep -qE '^fullscreen_transcript *= *false' "$cfg" 2>/dev/null \
  && pass "codex [tui] keys set" || fail "codex [tui] keys missing in $cfg"

echo
[ "$FAILS" -eq 0 ] && { echo "all checks passed"; exit 0; }
echo "$FAILS check(s) failed"; exit 1
