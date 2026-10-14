#!/usr/bin/env bash
# post-hq.sh — run as the user on dev-box after ~/dev/hq is cloned. Builds the
# native `fleet` (the only implementation) from hq main's fleet-rs, installs it
# to ~/.local/bin, then installs fleet-watch and the delegation hooks. It does
# NOT run `fleet up`: that starts the chief and writes fleet.slice, and the
# chief starts fresh as its own step (START.md). Idempotent.
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
[ "$(git -C "$HQ" rev-parse --abbrev-ref HEAD)" = main ] || { echo "post-hq.sh: $HQ is not on main" >&2; exit 1; }

echo "=== rust (rustup; fleet-rs/rust-toolchain.toml pins the version) ==="
if ! command -v cargo >/dev/null && [ ! -x "$HOME/.cargo/bin/cargo" ]; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --no-modify-path
fi
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:$PATH"

echo "=== build and install ~/.local/bin/fleet ==="
# Target off the root fs (never inside a worktree); /data is the second NVMe.
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/data/home/$USER/cargo-target/hq}"
mkdir -p "$CARGO_TARGET_DIR" "$HOME/.local/bin"
(cd "$HQ/fleet-rs" && cargo build --release --locked -p fleet)
install -m 755 "$CARGO_TARGET_DIR/release/fleet" "$HOME/.local/bin/fleet"
sha256sum "$HOME/.local/bin/fleet"

echo "=== fleet-watch (state loop service) ==="
fleet service install

echo "=== delegation hooks (Claude settings, Codex hooks) ==="
fleet delegation install --native

if [ "$HYGIENE_TIMERS" = 1 ]; then
  echo "=== hygiene timers ==="
  python3 "$HQ/fleet/hygiene.py" install-timer
  python3 "$HQ/fleet/hygiene.py" install-uv-timer
fi

echo "=== doctor ==="
fleet doctor || true
