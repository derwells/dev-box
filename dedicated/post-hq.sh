#!/usr/bin/env bash
# post-hq.sh — run as the user on dev-box AFTER ~/dev/hq has been copied over.
# Installs the hq-owned pieces: fleet.slice, fleet-watch, hygiene timers. Idempotent.
#
# Usage: post-hq.sh [hq_dir]      (default ~/dev/hq)
set -euo pipefail

HQ="${1:-$HOME/dev/hq}"
[ "$(id -u)" != 0 ] || { echo "post-hq.sh: run as the user, not root" >&2; exit 1; }
[ -d "$HQ" ] || { echo "post-hq.sh: $HQ not found (copy hq first)" >&2; exit 1; }

find_script() {  # find_script <name>: first match under hq
  find "$HQ" -maxdepth 4 -name "$1" -type f -not -path '*/node_modules/*' -not -path '*/.git/*' | head -n1
}

FLEET=$(find_script fleet.py)
HYGIENE=$(find_script hygiene.py)
[ -n "$FLEET" ] || { echo "post-hq.sh: fleet.py not found under $HQ" >&2; exit 1; }
[ -n "$HYGIENE" ] || { echo "post-hq.sh: hygiene.py not found under $HQ" >&2; exit 1; }

echo "=== fleet.slice (fleet.py up) ==="
python3 "$FLEET" up

echo "=== fleet-watch (state loop service) ==="
python3 "$FLEET" service install

echo "=== hygiene timers ==="
python3 "$HYGIENE" install-timer
python3 "$HYGIENE" install-uv-timer

echo "=== status ==="
systemctl --user list-timers --no-pager | grep -i hygiene || echo "no hygiene timers listed" >&2
systemctl --user status fleet.slice --no-pager 2>&1 | head -n 5 || true
