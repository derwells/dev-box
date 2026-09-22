# OpenCode adapter
- Load personal skills through `skill({ name: "learn" })` or the corresponding skill name. Personal slash commands are wrappers around those same skills.
- Translate legacy Claude `Skill`, `Read`, `Bash`, `Task`/`Agent`, and `AskUserQuestion` references to native available tools. If interactive questions are unavailable, ask in the conversation; never treat a missing tool as approval.
- OpenCode's native task/subagent tools run its configured models; for a Claude or Codex worker, or when Derick names one, use Paseo `create_agent`. Claude model names are not portable provider/model identifiers.
- Use native OpenCode GSD commands and agents, not Claude GSD agent definitions. Shared personal skills may retain existing CLI and credential paths under `~/.claude`; those paths remain valid on this machine.
- OpenCode may also discover Claude's `gsd-*` skills. Prefer the installed `/gsd-*` commands under `~/.config/opencode/command/`, whose paths and agent calls target OpenCode. For a natural-language GSD request, read the corresponding native command file and follow its workflow.
