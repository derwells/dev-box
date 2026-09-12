const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const code = fs.readFileSync(path.join(__dirname, '../files/claude/claude-settings-patch.js'), 'utf8');
let settings = {
  customPreference: 'keep',
  hooks: {
    PreToolUse: [{ hooks: [{ command: 'check-tool' }] }],
    Notification: [{ matcher: 'permission_prompt', hooks: [
      { command: 'tmux set -w @ci bell' }, { command: 'custom-notification' }
    ] }],
    Stop: [{ hooks: [{ command: 'bash "$HOME/.claude/hooks/tmux-attention.sh" stop' }] },
      { hooks: [{ command: 'custom-stop' }] }]
  }
};
function apply() {
  vm.runInNewContext(code, {
    process: { env: { HOME: '/home/test-user' } },
    require(name) {
      assert.equal(name, 'fs');
      return {
        readFileSync() { return JSON.stringify(settings); },
        writeFileSync(file, contents) {
          assert.equal(file, '/home/test-user/.claude/settings.json');
          settings = JSON.parse(contents);
        }
      };
    }
  });
}
apply();
assert.equal(settings.customPreference, 'keep');
assert.equal(settings.hooks.PreToolUse[0].hooks[0].command, 'check-tool');
assert.equal(settings.hooks.Notification[0].matcher, 'permission_prompt');
assert.equal(settings.hooks.Notification[0].hooks[0].command, 'custom-notification');
assert.equal(settings.hooks.Stop[0].hooks[0].command, 'custom-stop');
for (const event of ['Notification', 'Stop']) {
  const hooks = settings.hooks[event].flatMap(group => group.hooks);
  assert.equal(hooks.filter(hook => hook.command.includes('tmux-attention.sh')).length, 1);
  assert.ok(hooks.every(hook => !hook.command.includes('@ci')));
}
const first = JSON.stringify(settings);
apply();
assert.equal(JSON.stringify(settings), first, 'Repeated provisioning must not duplicate hooks');
console.log('Settings migration preserves unrelated hooks and is idempotent');
