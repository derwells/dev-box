const fs = require('fs');
const settingsPath = process.env.HOME + '/.claude/settings.json';
let settings = {};
try { settings = JSON.parse(fs.readFileSync(settingsPath, 'utf8')); } catch {}
Object.assign(settings, {
  effortLevel: "medium",
  promptSuggestionEnabled: false,
  tui: "fullscreen",
  autoMemoryEnabled: false,
  skipDangerousModePermissionPrompt: true,
  theme: "light",
  statusLine: {
    type: "command",
    command: "bash " + process.env.HOME + "/.claude/statusline-command.sh"
  }
});
// Claude Code attention icons: set a tmux window var that ~/.tmux.conf
// renders (🔔 = needs input, ✅ = finished). Merge into hooks without
// clobbering GSD's own hooks (SessionStart/PreToolUse/PostToolUse).
settings.hooks = settings.hooks || {};
settings.hooks.Notification = [
  { hooks: [{ type: "command", command: "[ -n \"$TMUX_PANE\" ] && tmux set -w -t \"$TMUX_PANE\" @ci '🔔 ' || true" }] }
];
settings.hooks.Stop = [
  { hooks: [{ type: "command", command: "[ -n \"$TMUX_PANE\" ] && tmux set -w -t \"$TMUX_PANE\" @ci '✅ ' || true" }] }
];
fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2));
