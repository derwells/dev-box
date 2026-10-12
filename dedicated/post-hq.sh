#!/usr/bin/env bash
# post-hq.sh — run as the user on dev-box AFTER ~/dev/hq is cloned and the Rust
# port of fleet has landed (fleet.py deleted). Builds the native `fleet` from
# hq's fleet-rs, then installs fleet.slice and fleet-watch. Idempotent.
#
# Usage: post-hq.sh [--hygiene] [hq_dir]      (default ~/dev/hq)
#   --hygiene   also install the two hygiene timers (off by default; Derick
#               decides whether they are wanted, and `fleet doctor` flags them)
set -euo pipefail

HYGIENE_TIMERS=0
[ "${1:-}" = "--hygiene" ] && { HYGIENE_TIMERS=1; shift; }
HQ="${1:-$HOME/dev/hq}"
[ "$(id -u)" != 0 ] || { echo "post-hq.sh: run as the user, not root" >&2; exit 1; }
[ -f "$HQ/fleet-rs/Cargo.toml" ] || { echo "post-hq.sh: $HQ/fleet-rs not found (clone hq first)" >&2; exit 1; }

echo "=== rust (rustup; fleet-rs/rust-toolchain.toml pins the version) ==="
if ! command -v cargo >/dev/null && [ ! -x "$HOME/.cargo/bin/cargo" ]; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --no-modify-path
fi
export PATH="$HOME/.cargo/bin:$PATH"

echo "=== build and install ~/.local/bin/fleet ==="
# Target off the root fs (never inside a worktree); /data is the second NVMe.
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/data/home/$USER/cargo-target/hq}"
mkdir -p "$CARGO_TARGET_DIR" "$HOME/.local/bin"
(cd "$HQ/fleet-rs" && cargo build --release --locked -p fleet)
install -m 755 "$CARGO_TARGET_DIR/release/fleet" "$HOME/.local/bin/fleet"
FLEET="$HOME/.local/bin/fleet"

echo "=== fleet.slice (fleet up) ==="
# `fleet up` also launches the chief (claude). Before `claude login` that window
# would sit on the onboarding screen, so wait until Claude is logged in.
if [ -f "$HOME/.claude/.credentials.json" ]; then
  "$FLEET" up
else
  echo "post-hq.sh: claude is not logged in; skipping 'fleet up' (it launches the chief). Re-run after 'claude login'." >&2
fi

echo "=== fleet-watch (state loop service) ==="
"$FLEET" service install

if [ "$HYGIENE_TIMERS" = 1 ]; then
  echo "=== hygiene timers ==="
  python3 "$HQ/fleet/hygiene.py" install-timer
  python3 "$HQ/fleet/hygiene.py" install-uv-timer
fi

echo "=== doctor ==="
"$FLEET" doctor || true
