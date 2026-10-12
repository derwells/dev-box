#!/usr/bin/env bash
# clone-dev.sh — recreate ~/dev from the manifest written by dev-inventory.py.
# Run on the new box as the normal user, after git/gh auth is in place.
#
#   clone-dev.sh [--dry-run] [TSV]     # TSV default ~/.config/dev-box/repos.tsv
#
# Each TSV line: relpath <TAB> url <TAB> branch. Existing targets are skipped.
# Exits 1 if any clone or checkout failed.
set -uo pipefail

DRY=0
if [ "${1:-}" = "--dry-run" ]; then DRY=1; shift; fi
TSV="${1:-$HOME/.config/dev-box/repos.tsv}"
[ -f "$TSV" ] || { echo "clone-dev: manifest $TSV not found" >&2; exit 1; }

ok=0; skipped=0; failed=()
while IFS=$'\t' read -r rel url branch; do
  [ -n "$rel" ] && [ -n "$url" ] || continue
  dest="$HOME/dev/$rel"
  if [ -e "$dest" ]; then
    echo "skip   $rel (exists)"; skipped=$((skipped + 1)); continue
  fi
  if [ "$DRY" = 1 ]; then
    echo "would clone $url -> ~/dev/$rel${branch:+ @ $branch}"; continue
  fi
  mkdir -p "$(dirname "$dest")"
  if ! git clone --quiet "$url" "$dest"; then
    echo "FAIL   $rel (clone)" >&2; failed+=("$rel"); continue
  fi
  if [ -n "$branch" ] && [ "$(git -C "$dest" symbolic-ref --short -q HEAD)" != "$branch" ]; then
    if ! git -C "$dest" checkout --quiet "$branch" 2>/dev/null; then
      echo "FAIL   $rel (checkout $branch)" >&2; failed+=("$rel"); continue
    fi
  fi
  echo "ok     $rel"; ok=$((ok + 1))
done < "$TSV"

echo "cloned=$ok skipped=$skipped failed=${#failed[@]}"
if [ "${#failed[@]}" -gt 0 ]; then printf 'failed: %s\n' "${failed[@]}" >&2; exit 1; fi
