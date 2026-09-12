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
// Route attention events to the local Claude/Codex panel. Completion is
// checked against root + subagent lifecycle state; no Telegram is sent.
// Replace our old @ci hooks while retaining unrelated Notification/Stop hooks.
settings.hooks = settings.hooks || {};
for (const [event, action] of [['Notification', 'notify'], ['Stop', 'stop']]) {
  const groups = (settings.hooks[event] || []).map(group => ({
    ...group,
    hooks: (group.hooks || []).filter(hook =>
      !/tmux-attention\.sh|tmux set.*@ci/.test(hook.command || ''))
  })).filter(group => group.hooks.length);
  groups.push({ hooks: [{ type: 'command',
    command: 'bash "$HOME/.claude/hooks/tmux-attention.sh" ' + action,
    timeout: 5 }] });
  settings.hooks[event] = groups;
}
fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2));
