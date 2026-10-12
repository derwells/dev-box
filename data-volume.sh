#!/usr/bin/env bash
# data-volume.sh — mount the Hetzner data volume at /mnt/data and move bulky,
# rebuildable data off the root disk. Run as root on the box.
#
#   data-volume.sh [--dry-run] mount <device>        # fstab + mount at /mnt/data
#   data-volume.sh [--dry-run] home <user> <dir>...  # ~/<dir> -> /mnt/data/home/<user>/<dir>, symlinked back
#   data-volume.sh [--dry-run] docker                # /var/lib/{docker,containerd} -> bind mounts from the volume
#
# MNT=/some/dir overrides /mnt/data (dry runs against a fake mount).
#
# Not moved, on purpose:
# - ~/.cache/uv: its archive is hard-linked into venvs under ~/dev. Across
#   filesystems the links would split and the space stays on root, so it is
#   renamed to ~/.uv-cache (same filesystem) and symlinked back in.
# - the fleet worktree trash: fleet retires worktrees with `git worktree move`,
#   which is a rename(2) and fails across filesystems.
# - ~/dev: live agent worktrees.
set -euo pipefail

DRY=0
[ "${1:-}" = "--dry-run" ] && { DRY=1; shift; }
MNT="${MNT:-/mnt/data}"

run() { echo "+ $*"; [ "$DRY" = 1 ] || "$@"; }
say() { echo "== $*"; }

fstab_add() {  # fstab_add <line>: append unless the mount point is already listed
  local mp; mp=$(awk '{print $2}' <<<"$1")
  if awk -v mp="$mp" '$2==mp {found=1} END {exit !found}' /etc/fstab; then
    say "fstab already has $mp"
  else
    echo "+ append to /etc/fstab: $1"
    [ "$DRY" = 1 ] || echo "$1" >> /etc/fstab
  fi
}

cmd_mount() {
  local dev=$1 uuid
  uuid=$(blkid -s UUID -o value "$dev")
  [ "$(blkid -s TYPE -o value "$dev")" = ext4 ] || { echo "$dev is not ext4" >&2; exit 1; }
  run mkdir -p "$MNT"
  # nofail: a detached volume must never block boot (sshd and tailscale first).
  fstab_add "UUID=$uuid $MNT ext4 defaults,nofail,discard,x-systemd.device-timeout=30s 0 2"
  run systemctl daemon-reload
  mountpoint -q "$MNT" || run mount "$MNT"
}

# Move one home directory: copy live, swap in a symlink, copy again to catch
# writes made during the first pass, then drop the old copy.
move_home_dir() {
  local user=$1 rel=$2 h src dst old
  h=$(getent passwd "$user" | cut -d: -f6)
  src="$h/$rel"; dst="$MNT/home/$user/$rel"; old="$src.pre-volume"
  if [ -L "$src" ]; then say "$src is already a symlink -> $(readlink "$src")"; return; fi
  [ -d "$src" ] || { say "skip $src (missing)"; return; }
  say "move $src -> $dst"
  run mkdir -p "$dst"
  local excl=()
  if [ "$rel" = .cache ] && [ -d "$src/uv" ]; then
    excl=(--exclude=/uv)
    run ln -sfn "$h/.uv-cache" "$dst/uv"
  fi
  run rsync -aHAX "${excl[@]}" "$src/" "$dst/"
  run chown "$user:$user" "$MNT/home/$user" "$dst"
  # The swap: a few ms where the path is mid-rename.
  [ ${#excl[@]} -eq 0 ] || run mv "$src/uv" "$h/.uv-cache"
  run mv "$src" "$old"
  run ln -s "$dst" "$src"
  run chown -h "$user:$user" "$src"
  run rsync -aHAX "${excl[@]}" "$old/" "$dst/"
  run rm -rf "$old"
}

cmd_home() {
  local user=$1; shift
  mountpoint -q "$MNT" || [ "$DRY" = 1 ] || { echo "$MNT is not mounted" >&2; exit 1; }
  for rel in "$@"; do move_home_dir "$user" "$rel"; done
}

cmd_docker() {
  mountpoint -q "$MNT" || [ "$DRY" = 1 ] || { echo "$MNT is not mounted" >&2; exit 1; }
  local d running
  # Pass 1 while running: the bulk of the bytes, no downtime.
  for d in docker containerd; do
    run mkdir -p "$MNT/$d"
    run rsync -aHAX --numeric-ids --delete "/var/lib/$d/" "$MNT/$d/"
  done
  running=$(docker ps -q --no-trunc | tr '\n' ' ')
  echo "running containers: $(wc -w <<<"$running")"
  run systemctl stop docker.socket docker.service containerd.service
  # Pass 2 stopped: only the delta.
  for d in docker containerd; do
    run rsync -aHAX --numeric-ids --delete "/var/lib/$d/" "$MNT/$d/"
    run mv "/var/lib/$d" "/var/lib/$d.pre-volume"
    run mkdir "/var/lib/$d"
    fstab_add "$MNT/$d /var/lib/$d none bind,nofail,x-systemd.requires-mounts-for=$MNT 0 0"
  done
  # Never start docker/containerd on the empty root dirs if the volume is missing.
  for u in docker containerd; do
    run mkdir -p "/etc/systemd/system/$u.service.d"
    echo "+ write /etc/systemd/system/$u.service.d/90-data-volume.conf"
    [ "$DRY" = 1 ] || printf '[Unit]\nRequiresMountsFor=/var/lib/docker /var/lib/containerd\n' \
      > "/etc/systemd/system/$u.service.d/90-data-volume.conf"
  done
  run systemctl daemon-reload
  run mount /var/lib/docker
  run mount /var/lib/containerd
  run systemctl start containerd.service docker.service
  # Containers without a restart policy stay down after a daemon restart.
  [ -z "$running" ] || run docker start $running
  say "check, then: rm -rf /var/lib/docker.pre-volume /var/lib/containerd.pre-volume"
}

case "${1:-}" in
  mount)  shift; cmd_mount "$@" ;;
  home)   shift; cmd_home "$@" ;;
  docker) shift; cmd_docker "$@" ;;
  *) sed -n '2,8p' "$0"; exit 2 ;;
esac
