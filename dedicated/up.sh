#!/usr/bin/env bash
# up.sh — drive the dedicated (Hetzner Robot) provisioning path from any machine
# holding the SSH key. See dedicated/README.md.
#
#   up.sh install   <public-ip>   # in Robot rescue: installimage, then reboot
#   up.sh provision <public-ip>   # after reboot: bootstrap.sh then setup.sh
#   up.sh lockdown  <public-ip>   # after `tailscale up` is approved: drop public 22
#
# Env: DEVBOX_KEY (default ~/.ssh/dev-box_ed25519), DEVBOX_USER (default derick),
#      GIT_USER_NAME / GIT_USER_EMAIL (default derwells / drckwells@gmail.com),
#      DEVBOX_TS_HOST (Tailscale name used by lockdown, default dev-box; set to the
#      MagicDNS FQDN or tailnet IP when a bare name resolves elsewhere),
#      BOOTSTRAP_ALLOW_IP (only public source allowed on 22, default <dev-box-1-public-ip>),
#      FORCE_DATA_DISK=1 (pass --force-data-disk to data-disk.sh).
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$HERE")
KEY="${DEVBOX_KEY:-$HOME/.ssh/dev-box_ed25519}"
DEVBOX_USER="${DEVBOX_USER:-derick}"
GIT_USER_NAME="${GIT_USER_NAME:-derwells}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-drckwells@gmail.com}"
TS_HOST="${DEVBOX_TS_HOST:-dev-box}"
ALLOW_IP="${BOOTSTRAP_ALLOW_IP:-<dev-box-1-public-ip>}"

usage() { sed -n '2,15p' "${BASH_SOURCE[0]}"; exit 2; }
[ $# -eq 2 ] || usage
PHASE=$1; IP=$2
[ -f "$KEY" ] || { echo "up.sh: ssh key $KEY not found (set DEVBOX_KEY)" >&2; exit 1; }

# Host keys change when rescue hands over to the installed OS; do not pin them.
SSH_OPTS=(-i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new
          -o UserKnownHostsFile="$HOME/.ssh/known_hosts.dev-box" -o ConnectTimeout=15)
ssh_root() { ssh "${SSH_OPTS[@]}" "root@$IP" "$@"; }
scp_root() { scp -q "${SSH_OPTS[@]}" "$@"; }

upload_payload() {
  ssh_root 'mkdir -p /root/provision /root/dedicated'
  # Same payload main.tf uploads: files/ -> /root/provision, setup.sh -> /root/.
  tar -C "$ROOT/files" -cf - . | ssh_root 'tar -C /root/provision -xf -'
  scp_root "$ROOT/setup.sh" "root@$IP:/root/setup.sh"
  scp_root "$HERE"/*.sh "$HERE/installimage.conf" "root@$IP:/root/dedicated/"
  ssh_root 'chmod 0755 /root/dedicated/*.sh'
}

case "$PHASE" in
  install)
    scp_root "$HERE/installimage.conf" "root@$IP:/root/installimage.conf"
    ssh_root 'test -x "$(command -v installimage)"' \
      || { echo "up.sh: installimage not found; is the server in Robot rescue?" >&2; exit 1; }
    # Only the rescue system has installimage; refuse anywhere else (it wipes disks).
    ssh_root 'grep -qi rescue /etc/hostname /etc/motd 2>/dev/null' \
      || { echo "up.sh: $IP is not the Hetzner rescue system; refusing to install" >&2; exit 1; }
    # UEFI boot needs an ESP; installimage does not add one by itself.
    ssh_root '[ ! -d /sys/firmware/efi ] || grep -q "^PART /boot/efi" /root/installimage.conf \
      || sed -i "s#^PART /boot ext4 1G#PART /boot/efi esp 256M\nPART /boot ext4 1G#" /root/installimage.conf'
    # The second NVMe is not in installimage.conf. Stop arrays left by Hetzner's
    # preinstall (RAID1 across both disks) and wipe it so data-disk.sh finds it blank.
    ssh_root 'mdadm --stop --scan || true
      for p in $(lsblk -lnpo NAME /dev/nvme1n1 | tail -n +2); do wipefs -a "$p"; done
      wipefs -a /dev/nvme1n1'
    ssh_root 'installimage -a -c /root/installimage.conf'
    echo "installimage done; rebooting (run 'provision' once ssh is back)"
    ssh_root 'reboot' || true   # connection drops as the host goes down
    ;;
  provision)
    upload_payload
    pub=/root/.ssh/authorized_keys
    force=""; [ "${FORCE_DATA_DISK:-0}" = 1 ] && force="--force-data-disk"
    # Run detached so a dropped ssh session does not kill a 20-minute bootstrap.
    ssh_root "systemctl reset-failed devbox-bootstrap 2>/dev/null; systemd-run --unit=devbox-bootstrap --collect \
      bash -c \"bash /root/dedicated/bootstrap.sh '$DEVBOX_USER' '$pub' '$GIT_USER_NAME' '$GIT_USER_EMAIL' --allow-ip='$ALLOW_IP' $force > /root/bootstrap.log 2>&1\""
    echo "bootstrap running as devbox-bootstrap.service; log: /root/bootstrap.log"
    ssh_root 'while systemctl is-active -q devbox-bootstrap; do sleep 20; done; tail -n 25 /root/bootstrap.log; grep -q "=== bootstrap done ===" /root/bootstrap.log'
    echo
    echo "Next: ssh root@$IP, run 'tailscale up --hostname dev-box', open the login URL,"
    echo "approve the node, then: dedicated/up.sh lockdown $IP"
    ;;
  lockdown)
    ssh_root 'tailscale status --self=true >/dev/null' \
      || { echo "up.sh: tailscale is not up on the box" >&2; exit 1; }
    # Prove Tailscale SSH works before removing the public path.
    ssh -o BatchMode=yes -o ConnectTimeout=15 "$DEVBOX_USER@$TS_HOST" true \
      || { echo "up.sh: ssh $DEVBOX_USER@$TS_HOST over Tailscale failed; not locking down" >&2; exit 1; }
    # Remove the public 22 rule(s), then turn root login off. Done over the already-established
    # session, which survives the rule removal; reload (not restart) keeps it alive too.
    ssh_root "ufw --force delete allow from '$ALLOW_IP' to any port 22 proto tcp || true
      ufw --force delete allow 22/tcp || true
      ufw status
      sed -i 's/^PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config.d/00-devbox-hardening.conf
      sshd -t && systemctl try-reload-or-restart ssh"
    ssh -o BatchMode=yes -o ConnectTimeout=15 "$DEVBOX_USER@$TS_HOST" true \
      || { echo "up.sh: tailscale ssh broke after lockdown; recover via Robot rescue" >&2; exit 1; }
    echo "lockdown ok: public 22 closed, tailscale ssh works"
    ;;
  *) usage ;;
esac
