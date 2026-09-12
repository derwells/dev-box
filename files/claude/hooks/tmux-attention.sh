#!/usr/bin/env bash
# Compatibility entry point for already-running Claude sessions.
# No Telegram sending. Completion is checked against the full session lifecycle.
exec /usr/bin/python3 "$HOME/.local/share/agent-attention/attention.py" hook "${1:-notify}"
