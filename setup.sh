#!/usr/bin/env bash
# setup.sh — post-boot provisioning for the dev box.
#
# Runs as root via Terraform's remote-exec after cloud-init finishes.
# cloud-init.yaml.tftpl only bootstraps (user, packages, gh, Tailscale, UFW);
# everything else lives here because Hetzner caps user_data at 32KiB and the
# full provisioning payload is far larger. Static file content is uploaded
# by a file provisioner to /root/provision (see files/ in the repo).
#
# Usage: setup.sh <username> <git_user_name> <git_user_email>
#
# Safe to re-run: steps are guarded or naturally idempotent, so a failed
# apply can be resumed with
#   ssh root@<ip> 'bash /root/setup.sh <username> "<git name>" <git email>'
set -euo pipefail

USERNAME="$1"
GIT_USER_NAME="$2"
GIT_USER_EMAIL="$3"
H="/home/$USERNAME"
PAYLOAD="/root/provision"

[ -d "$PAYLOAD" ] || { echo "setup.sh: payload dir $PAYLOAD missing" >&2; exit 1; }

# Run a command as the user with fnm's node on PATH (non-interactive shells
# don't source .zshrc/.bashrc, so the PATH must be set explicitly).
run_node() {
  su - "$USERNAME" -c "export PATH=\"$H/.local/share/fnm:\$PATH\" && eval \"\$(fnm env)\" && $*"
}
run_user() {
  su - "$USERNAME" -c "$*"
}

echo "=== Node.js via fnm ==="
run_user "curl -fsSL https://fnm.vercel.app/install | bash"
run_node "fnm install --lts && fnm use --lts"

echo "=== Claude Code + GSD + gws ==="
run_node "npm install -g @anthropic-ai/claude-code get-shit-done-cc"
# gws (Google Workspace CLI) — backs /brain and the gwsa multi-account wrapper.
# Pinned; auth is a manual post-deploy step (gwsa login <slot>).
run_node "npm install -g @googleworkspace/cli@0.22.5"

echo "=== claudex wrapper ==="
install -m 0755 "$PAYLOAD/bin/claudex" /usr/local/bin/claudex

echo "=== ~/.claude payload (search bridge, statusline, CLAUDE.md) ==="
mkdir -p "$H/.claude"
install -m 0644 "$PAYLOAD/claude/mimo-search-mcp.mjs" "$H/.claude/mimo-search-mcp.mjs"
install -m 0644 "$PAYLOAD/claude/CLAUDE.md" "$H/.claude/CLAUDE.md"
install -m 0755 "$PAYLOAD/claude/statusline-command.sh" "$H/.claude/statusline-command.sh"
cat > "$H/.claude/search_mcp.json" << EOF
{
  "mcpServers": {
    "mimo-search": {
      "command": "node",
      "args": ["$H/.claude/mimo-search-mcp.mjs"]
    }
  }
}
EOF
chown -R "$USERNAME:$USERNAME" "$H/.claude"

echo "=== GSD (registers skills + hooks into ~/.claude/) ==="
run_node "GSD_PORTABLE_HOOKS=1 npx get-shit-done-cc@latest --claude --global"

echo "=== Claude Code settings (merge, GSD may have written hooks) ==="
install -m 0644 "$PAYLOAD/claude/claude-settings-patch.js" /tmp/claude-settings-patch.js
run_node "node /tmp/claude-settings-patch.js"
rm -f /tmp/claude-settings-patch.js

echo "=== Shell environment (tmux, zsh, starship) ==="
install -m 0644 "$PAYLOAD/home/tmux.conf" "$H/.tmux.conf"
install -m 0644 "$PAYLOAD/home/zshenv" "$H/.zshenv"
install -m 0644 "$PAYLOAD/home/zshrc" "$H/.zshrc"
mkdir -p "$H/.config"
install -m 0644 "$PAYLOAD/home/config/starship.toml" "$H/.config/starship.toml"

# git-delta (pager). Non-fatal: the gitconfig below only wires it up if present.
apt-get install -y git-delta || true

# starship prompt (installs to /usr/local/bin)
curl -fsSL https://starship.rs/install.sh | sh -s -- -y

# uv (Python) — provides the ~/.local/bin/env that .zshrc sources
run_user "curl -LsSf https://astral.sh/uv/install.sh | sh"

# pnpm
run_node "npm install -g pnpm"

# oh-my-zsh (unattended; keep our own .zshrc, don't chsh here)
if [ ! -d "$H/.oh-my-zsh" ]; then
  run_user 'RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"'
fi

echo "=== git identity + defaults ==="
run_user "git config --global user.name \"$GIT_USER_NAME\" && git config --global user.email \"$GIT_USER_EMAIL\" && git config --global init.defaultBranch main && git config --global merge.conflictstyle diff3 && git config --global diff.colorMoved default"
if command -v delta >/dev/null 2>&1; then
  run_user 'git config --global core.pager delta \
    && git config --global interactive.diffFilter "delta --color-only" \
    && git config --global delta.navigate true \
    && git config --global delta.light true \
    && git config --global delta.syntax-theme GitHub \
    && git config --global delta.side-by-side true \
    && git config --global delta.line-numbers true'
fi
chown -R "$USERNAME:$USERNAME" "$H/.zshrc" "$H/.zshenv" "$H/.tmux.conf" "$H/.config" "$H/.oh-my-zsh" "$H/.gitconfig"

echo "=== Skills: humanizer ==="
if [ ! -d "$H/.claude/skills/humanizer" ]; then
  run_user "git clone https://github.com/blader/humanizer.git $H/.claude/skills/humanizer"
fi

echo "=== Skills: claudex + brain ==="
mkdir -p "$H/.claude/skills/claudex" "$H/.claude/skills/brain/terraform"
install -m 0644 "$PAYLOAD/claude/skills/claudex/SKILL.md" "$H/.claude/skills/claudex/SKILL.md"
install -m 0644 "$PAYLOAD/claude/skills/brain/SKILL.md" "$H/.claude/skills/brain/SKILL.md"
install -m 0644 "$PAYLOAD/claude/skills/brain/SETUP.md" "$H/.claude/skills/brain/SETUP.md"
install -m 0644 "$PAYLOAD/claude/skills/brain/terraform/main.tf" "$H/.claude/skills/brain/terraform/main.tf"
install -m 0644 "$PAYLOAD/claude/skills/brain/terraform/terraform.tfvars.example" "$H/.claude/skills/brain/terraform/terraform.tfvars.example"
chown -R "$USERNAME:$USERNAME" "$H/.claude/skills"

echo "=== gwsa — multi-account gws credential slots ==="
# Config only (tool, docs, per-slot email/scopes manifests). Credentials are
# NOT provisioned: per slot, drop the shared OAuth client_secret.json into
# ~/.config/gws-accounts/<slot>/ and run `gwsa login <slot>` (see its README).
GWSROOT="$H/.config/gws-accounts"
mkdir -p "$GWSROOT"
install -m 0755 "$PAYLOAD/gws-accounts/gwsa" "$GWSROOT/gwsa"
install -m 0644 "$PAYLOAD/gws-accounts/README.md" "$GWSROOT/README.md"
install -m 0644 "$PAYLOAD/gws-accounts/gitignore" "$GWSROOT/.gitignore"
for slot in personal angkin pymc ce; do
  mkdir -p "$GWSROOT/$slot"
  install -m 0644 "$PAYLOAD/gws-accounts/$slot/email" "$GWSROOT/$slot/email"
  install -m 0644 "$PAYLOAD/gws-accounts/$slot/scopes" "$GWSROOT/$slot/scopes"
done
chmod 700 "$GWSROOT" "$GWSROOT"/personal "$GWSROOT"/angkin "$GWSROOT"/pymc "$GWSROOT"/ce
# gwsa on PATH; bare `gws` = the personal slot (guards against a bare
# `gws auth login` for a work account clobbering personal's credentials)
mkdir -p "$H/.local/bin"
ln -sfn "$GWSROOT/gwsa" "$H/.local/bin/gwsa"
ln -sfn "$GWSROOT/personal" "$H/.config/gws"
chown -R "$USERNAME:$USERNAME" "$GWSROOT" "$H/.local"
chown -h "$USERNAME:$USERNAME" "$H/.config/gws"
# The dir is a git repo on the box: config/docs tracked, secrets gitignored
if [ ! -d "$GWSROOT/.git" ]; then
  run_user "git -C $GWSROOT init -b main -q && git -C $GWSROOT add -A && git -C $GWSROOT commit -q -m 'gws multi-account setup (provisioned by dev-box)'"
fi
# Daily token-health monitor: Telegram ping when a slot needs re-login
if ! crontab -u "$USERNAME" -l 2>/dev/null | grep -q 'gwsa check'; then
  { crontab -u "$USERNAME" -l 2>/dev/null || true
    echo "# gws token health — Telegram ping when an account needs gwsa login (see ~/.config/gws-accounts/README.md)"
    echo "30 8 * * * $H/.local/bin/gwsa check --notify >/dev/null 2>&1"
  } | crontab -u "$USERNAME" -
fi

echo "=== Claude Code plugins ==="
run_node "claude plugin marketplace add anthropics/claude-plugins-official" || true
run_node "claude plugin install superpowers@claude-plugins-official" || true
run_node "claude plugin install context7@claude-plugins-official" || true
chown -R "$USERNAME:$USERNAME" "$H/.claude"

echo "=== Playwright ==="
run_node "npx playwright install --with-deps"

echo "=== VNC + noVNC ==="
mkdir -p "$H/.vnc"
cat > "$H/.vnc/xstartup" << 'XSTARTUP'
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec startxfce4
XSTARTUP
chmod +x "$H/.vnc/xstartup"
chown -R "$USERNAME:$USERNAME" "$H/.vnc"

cat > /etc/systemd/system/vncserver@.service << VNCUNIT
[Unit]
Description=TigerVNC server on display %i
After=syslog.target network.target tailscaled.service

[Service]
Type=forking
User=$USERNAME
WorkingDirectory=$H
ExecStartPre=/bin/sh -c 'sleep 5'
ExecStart=/usr/bin/vncserver :%i -localhost no -geometry 1920x1080 -depth 24
ExecStop=/usr/bin/vncserver -kill :%i

[Install]
WantedBy=multi-user.target
VNCUNIT

cat > /etc/systemd/system/novnc.service << NOVNCUNIT
[Unit]
Description=noVNC websocket proxy
After=vncserver@1.service

[Service]
Type=simple
User=$USERNAME
ExecStart=/usr/bin/websockify --web /usr/share/novnc 6080 localhost:5901
Restart=on-failure

[Install]
WantedBy=multi-user.target
NOVNCUNIT

systemctl daemon-reload
# VNC requires a password — run `vncpasswd` before enabling, then:
#   sudo systemctl enable --now vncserver@1 novnc

# Make zsh the login shell. Done LAST: every run_user/run_node above executes
# under the login shell, and switching earlier would change how they run.
chsh -s /usr/bin/zsh "$USERNAME"

echo "=== setup.sh done ==="
