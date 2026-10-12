#!/usr/bin/env bash
# bootstrap.sh — replaces cloud-init on the dedicated (Hetzner Robot) path.
# Runs as root on the freshly installed box, after up.sh uploads the payload.
#
# Usage: bootstrap.sh <username> <ssh_pubkey_file> [git_name] [git_email] [--force-data-disk] [--allow-ip=IP]
#
# Public SSH (22/tcp) is allowed in UFW only from BOOTSTRAP_ALLOW_IP (--allow-ip=IP
# or env; required, the operator public IP), never from anywhere. `up.sh lockdown`
# removes it. Docker publishes on 127.0.0.1 by default and a DOCKER-USER rule drops
# new inbound on the public interface (Docker otherwise bypasses UFW).
#
# Idempotent: safe to re-run by hand. Does NOT run `tailscale up` (needs an
# interactive login); it prints the command instead.
set -euo pipefail

USERNAME="${1:?usage: bootstrap.sh <username> <ssh_pubkey_file> [git_name] [git_email] [--force-data-disk]}"
PUBKEY_FILE="${2:?missing ssh_pubkey_file}"
GIT_USER_NAME="${3:-derwells}"
GIT_USER_EMAIL="${4:-drckwells@gmail.com}"
FORCE=""
ALLOW_IP="${BOOTSTRAP_ALLOW_IP:-}"
for a in "$@"; do
  case "$a" in
    --force-data-disk) FORCE="--force-data-disk" ;;
    --allow-ip=*) ALLOW_IP="${a#--allow-ip=}" ;;
  esac
done
case "$GIT_USER_NAME" in --*) GIT_USER_NAME=derwells ;; esac
case "$GIT_USER_EMAIL" in --*) GIT_USER_EMAIL=drckwells@gmail.com ;; esac
[[ "$ALLOW_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]] || { echo "bootstrap.sh: bad allow IP '$ALLOW_IP'" >&2; exit 1; }

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ "$(id -u)" = 0 ] || { echo "bootstrap.sh: run as root" >&2; exit 1; }
[ -f "$PUBKEY_FILE" ] || { echo "bootstrap.sh: $PUBKEY_FILE not found" >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive

echo "=== user $USERNAME (uid/gid 1000) ==="
if ! getent group "$USERNAME" >/dev/null; then groupadd -g 1000 "$USERNAME"; fi
if ! id "$USERNAME" >/dev/null 2>&1; then
  # Ubuntu images ship a uid-1000 'ubuntu' user on some clouds; not on installimage, but be safe.
  useradd -m -u 1000 -g "$USERNAME" -G sudo -s /bin/bash "$USERNAME"
fi
usermod -aG sudo "$USERNAME"
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$USERNAME"
chmod 0440 "/etc/sudoers.d/90-$USERNAME"
visudo -cf "/etc/sudoers.d/90-$USERNAME" >/dev/null
install -d -m 0700 -o "$USERNAME" -g "$USERNAME" "/home/$USERNAME/.ssh"
touch "/home/$USERNAME/.ssh/authorized_keys"
# Append only the public key lines not already present (works for a pubkey file or root's authorized_keys).
while IFS= read -r line; do
  [ -n "$line" ] || continue
  grep -qxF "$line" "/home/$USERNAME/.ssh/authorized_keys" || echo "$line" >> "/home/$USERNAME/.ssh/authorized_keys"
done < "$PUBKEY_FILE"
chown "$USERNAME:$USERNAME" "/home/$USERNAME/.ssh/authorized_keys"
chmod 0600 "/home/$USERNAME/.ssh/authorized_keys"

echo "=== apt packages ==="
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
  ca-certificates gnupg \
  ufw xfce4 xfce4-goodies dbus-x11 tigervnc-standalone-server tigervnc-common novnc websockify \
  chromium-browser git curl unzip jq tmux python3 zsh fzf bat zoxide \
  git-delta build-essential rsync htop ncdu unattended-upgrades mosh

echo "=== Docker (apt repo) ==="
# Publish on localhost by default (set before docker first starts).
install -d /etc/docker
if [ -s /etc/docker/daemon.json ]; then
  tmp=$(mktemp); jq '.ip = "127.0.0.1"' /etc/docker/daemon.json > "$tmp" && install -m 0644 "$tmp" /etc/docker/daemon.json; rm -f "$tmp"
else
  printf '{\n  "ip": "127.0.0.1"\n}\n' > /etc/docker/daemon.json
fi
install -m 0755 -d /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/docker.asc ]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
fi
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -qq
# Packages start docker/containerd on install; data-disk.sh stops them before the bind mounts.
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
usermod -aG docker "$USERNAME"

echo "=== GitHub CLI ==="
if [ ! -f /usr/share/keyrings/githubcli-archive-keyring.gpg ]; then
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg
  chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
fi
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  > /etc/apt/sources.list.d/github-cli.list
apt-get update -qq
apt-get install -y -qq gh

echo "=== Tailscale ==="
command -v tailscale >/dev/null 2>&1 || curl -fsSL https://tailscale.com/install.sh | sh

echo "=== UFW ==="
ufw default deny incoming
ufw default allow outgoing
ufw allow in on tailscale0
# Drop any blanket 22 rule from an earlier run (no-op if absent), then allow 22 only from the bootstrap IP.
ufw --force delete allow 22/tcp >/dev/null 2>&1 || true
ufw allow from "$ALLOW_IP" to any port 22 proto tcp   # removed by `dedicated/up.sh lockdown`
ufw --force enable

echo "=== sshd hardening ==="
# 00- sorts first and sshd keeps the first value seen, so this wins over sshd_config.
cat > /etc/ssh/sshd_config.d/00-devbox-hardening.conf << 'SSHD'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
SSHD
sshd -t
systemctl try-reload-or-restart ssh

echo "=== Docker vs the public interface (DOCKER-USER) ==="
cat > /usr/local/sbin/devbox-docker-user << 'DUSER'
#!/bin/sh
# Drop new inbound connections arriving on the public interface to published container ports.
# Container-originated traffic and its replies are unaffected (-i is the ingress interface).
for ipt in iptables ip6tables; do
  command -v "$ipt" >/dev/null 2>&1 || continue
  pub=$(ip $([ "$ipt" = ip6tables ] && echo -6) route show default 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}')
  [ -n "$pub" ] || continue
  "$ipt" -N DOCKER-USER 2>/dev/null || true
  while "$ipt" -D DOCKER-USER -m comment --comment devbox-public-drop -j DROP 2>/dev/null; do :; done
  while "$ipt" -D DOCKER-USER -i "$pub" -m conntrack --ctstate NEW -m comment --comment devbox-public-drop -j DROP 2>/dev/null; do :; done
  "$ipt" -I DOCKER-USER 1 -i "$pub" -m conntrack --ctstate NEW -m comment --comment devbox-public-drop -j DROP
done
DUSER
chmod 0755 /usr/local/sbin/devbox-docker-user
cat > /etc/systemd/system/devbox-docker-user.service << 'DUNIT'
[Unit]
Description=Drop new inbound on the public interface for Docker published ports
After=docker.service network-online.target
Wants=network-online.target
PartOf=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/devbox-docker-user

[Install]
WantedBy=multi-user.target docker.service
DUNIT
systemctl daemon-reload
systemctl enable devbox-docker-user.service

echo "=== no printing services ==="
# The desktop packages pull in CUPS, which listens on 0.0.0.0:631; a dev box needs no printers.
systemctl disable --now cups.socket cups.service cups-browsed.service 2>/dev/null || true
systemctl mask cups.socket cups.service cups-browsed.service 2>/dev/null || true
# Ubuntu 24.04 also ships CUPS as a snap alongside the chromium snap.
snap remove --purge cups 2>/dev/null || true

echo "=== UTC clock (hq timer schedules assume UTC, like dev-box-1) ==="
timedatectl set-timezone UTC

echo "=== headless: no display manager ==="
# xfce4 pulls in lightdm, which fails without a monitor; VNC runs its own X session.
systemctl disable lightdm.service 2>/dev/null || true
systemctl set-default multi-user.target

echo "=== unattended-upgrades ==="
printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' > /etc/apt/apt.conf.d/20auto-upgrades
systemctl enable --now unattended-upgrades.service

echo "=== Swap + data disk + bind mounts ==="
# shellcheck disable=SC2086  # $FORCE is an optional flag
bash "$HERE/data-disk.sh" $FORCE all "$USERNAME"
systemctl enable docker containerd
systemctl restart devbox-docker-user.service

echo "=== setup.sh ==="
bash /root/setup.sh "$USERNAME" "$GIT_USER_NAME" "$GIT_USER_EMAIL"

cat << MSG

=== bootstrap done ===
Tailscale is installed but not logged in. As root on this box run:

  tailscale up --hostname dev-box

Open the login URL it prints, approve the node, then from the operator machine:

  dedicated/up.sh lockdown <public-ip>

Until then 22/tcp is open only from $ALLOW_IP.

MSG
