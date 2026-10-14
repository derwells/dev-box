#!/usr/bin/env bash
# data-disk.sh — format and mount the second NVMe at /data, move bulky data onto it,
# add a swapfile. Run as root on the box. Dedicated-path counterpart of data-volume.sh.
#
#   data-disk.sh [--dry-run] [--force-data-disk] disk            # format (if blank) + mount /data
#   data-disk.sh [--dry-run] home <user> <dir>...                # ~/<dir> -> /data/home/<user>/<dir>
#   data-disk.sh [--dry-run] docker                              # bind-mount docker/containerd from /data
#   data-disk.sh [--dry-run] swap [size]                         # /swapfile (default 16G), swappiness 10
#   data-disk.sh [--dry-run] all <user>                          # everything above, in order
#
# MNT=/some/dir overrides /data. DATA_DISK=/dev/nvmeXn1 overrides auto-detection.
# The root disk is derived from `findmnt /` and is never touched. A disk with a
# partition table or filesystem is refused unless --force-data-disk is given.
set -euo pipefail

DRY=0; FORCE=0
while [ "${1:-}" = "--dry-run" ] || [ "${1:-}" = "--force-data-disk" ]; do
  [ "$1" = "--dry-run" ] && DRY=1
  [ "$1" = "--force-data-disk" ] && FORCE=1
  shift
done
MNT="${MNT:-/data}"
OLDMNT=/mnt/data

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

root_disk() {  # whole-disk device that holds /
  local src pk
  src=$(findmnt -no SOURCE /)
  pk=$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1)
  if [ -n "$pk" ]; then echo "/dev/$pk"; else echo "$src"; fi
}

pick_data_disk() {
  local root d found=()
  root=$(root_disk)
  while read -r d; do
    [ "/dev/$d" = "$root" ] && continue
    found+=("/dev/$d")
  done < <(lsblk -dno NAME,TYPE | awk '$2=="disk" && $1 ~ /^nvme/ {print $1}')
  [ ${#found[@]} -eq 1 ] || { echo "expected exactly one non-root NVMe disk, found: ${found[*]:-none} (root: $root); set DATA_DISK" >&2; exit 1; }
  echo "${found[0]}"
}

cmd_disk() {
  local dev root part
  dev="${DATA_DISK:-$(pick_data_disk)}"
  root=$(root_disk)
  [ -b "$dev" ] || { echo "$dev is not a block device" >&2; exit 1; }
  # Never touch the root disk, even via DATA_DISK, partition or symlink.
  [ "$(readlink -f "$dev")" != "$(readlink -f "$root")" ] || { echo "refusing: $dev is the root disk ($root)" >&2; exit 1; }
  if mountpoint -q "$MNT"; then
    say "$MNT already mounted; nothing to format"
  else
    # An existing ext4 filesystem we made earlier (labelled dev-box-data) is reusable.
    part="$dev"
    if [ "$(blkid -s LABEL -o value "$part" 2>/dev/null)" != dev-box-data ]; then
      if [ -n "$(lsblk -no FSTYPE,PTTYPE "$dev" | tr -d ' \n')" ] || blkid "$dev" >/dev/null 2>&1; then
        if [ "$FORCE" != 1 ]; then
          echo "refusing: $dev has a partition table or filesystem (pass --force-data-disk to wipe it)" >&2
          lsblk -o NAME,SIZE,FSTYPE,PTTYPE,MOUNTPOINT "$dev" >&2 || true
          exit 1
        fi
        run wipefs -a "$dev"
      fi
      run mkfs.ext4 -F -L dev-box-data "$dev"
    else
      say "$dev already carries a dev-box-data filesystem"
    fi
    local uuid="<uuid>"
    [ "$DRY" = 1 ] || uuid=$(blkid -s UUID -o value "$dev")
    run mkdir -p "$MNT"
    # nofail: a missing disk must never block boot (sshd and tailscale first).
    fstab_add "UUID=$uuid $MNT ext4 defaults,nofail,discard,x-systemd.device-timeout=30s 0 2"
    run systemctl daemon-reload
    run mount "$MNT"
  fi
  # Absolute paths copied from dev-box-1 (/mnt/data/home/...) keep resolving.
  if [ "$MNT" = /data ] && [ ! -e "$OLDMNT" ]; then
    run ln -s "$MNT" "$OLDMNT"
  fi
}

# Move one home directory: copy live, swap in a symlink, copy again, drop the old copy.
move_home_dir() {
  local user=$1 rel=$2 h src dst old
  h=$(getent passwd "$user" | cut -d: -f6)
  src="$h/$rel"; dst="$MNT/home/$user/$rel"; old="$src.pre-volume"
  if [ -L "$src" ]; then say "$src is already a symlink -> $(readlink "$src")"; return; fi
  if [ ! -d "$src" ]; then
    # Fresh box: nothing to move, just create the target and link it.
    say "create $dst and link $src"
    run mkdir -p "$dst"
    run chown "$user:$user" "$MNT/home/$user" "$dst"
    run ln -s "$dst" "$src"
    run chown -h "$user:$user" "$src"
    return
  fi
  say "move $src -> $dst"
  run mkdir -p "$dst"
  local excl=()
  # uv's archive is hard-linked into venvs under ~/dev: keep it on root as ~/.uv-cache.
  if [ "$rel" = .cache ] && [ -d "$src/uv" ]; then
    excl=(--exclude=/uv)
    run ln -sfn "$h/.uv-cache" "$dst/uv"
  fi
  run rsync -aHAX "${excl[@]}" "$src/" "$dst/"
  run chown "$user:$user" "$MNT/home/$user" "$dst"
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
  local d
  run systemctl stop docker.socket docker.service containerd.service
  for d in docker containerd; do
    run mkdir -p "$MNT/$d" "/var/lib/$d"
    # Bring over whatever the packages already wrote, once; never --delete.
    if [ -z "$(ls -A "$MNT/$d" 2>/dev/null)" ] && [ -n "$(ls -A "/var/lib/$d" 2>/dev/null)" ] && ! mountpoint -q "/var/lib/$d"; then
      run rsync -aHAX --numeric-ids "/var/lib/$d/" "$MNT/$d/"
    fi
    fstab_add "$MNT/$d /var/lib/$d none bind,nofail,x-systemd.requires-mounts-for=$MNT 0 0"
  done
  # Never start docker/containerd on the empty root dirs if the disk is missing.
  for d in docker containerd; do
    run mkdir -p "/etc/systemd/system/$d.service.d"
    echo "+ write /etc/systemd/system/$d.service.d/90-data-volume.conf"
    [ "$DRY" = 1 ] || printf '[Unit]\nRequiresMountsFor=/var/lib/docker /var/lib/containerd\n' \
      > "/etc/systemd/system/$d.service.d/90-data-volume.conf"
  done
  run systemctl daemon-reload
  for d in docker containerd; do
    mountpoint -q "/var/lib/$d" || run mount "/var/lib/$d"
  done
  run systemctl start containerd.service docker.service
}

cmd_swap() {
  local size=${1:-16G}
  if swapon --show=NAME --noheadings | grep -qx /swapfile; then
    say "/swapfile already active"
  else
    [ -e /swapfile ] || run fallocate -l "$size" /swapfile
    run chmod 600 /swapfile
    blkid /swapfile 2>/dev/null | grep -q swap || run mkswap /swapfile
    run swapon /swapfile
  fi
  fstab_add "/swapfile none swap sw 0 0"
  echo "+ write /etc/sysctl.d/90-devbox-swap.conf (vm.swappiness=10)"
  [ "$DRY" = 1 ] || { echo 'vm.swappiness=10' > /etc/sysctl.d/90-devbox-swap.conf; sysctl -q -p /etc/sysctl.d/90-devbox-swap.conf; }
}

case "${1:-}" in
  disk)   cmd_disk ;;
  home)   shift; cmd_home "$@" ;;
  docker) cmd_docker ;;
  swap)   shift; cmd_swap "$@" ;;
  all)    shift; u=${1:?usage: all <user>}
          cmd_swap; cmd_disk; cmd_home "$u" .cache .npm; cmd_docker ;;
  *) sed -n '2,12p' "$0"; exit 2 ;;
esac
