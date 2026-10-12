# OpenCode adapter
- Load personal skills through `skill({ name: "learn" })` or the corresponding skill name. Personal slash commands are wrappers around those same skills.
- Translate legacy Claude `Skill`, `Read`, `Bash`, `Task`/`Agent`, and `AskUserQuestion` references to native available tools. If interactive questions are unavailable, ask in the conversation; never treat a missing tool as approval.
- OpenCode's native task/subagent tools run its configured models; for a Claude or Codex worker, or when Derick names one, use Paseo `create_agent`. Claude model names are not portable provider/model identifiers.
- Shared personal skills may retain existing CLI and credential paths under `~/.claude`; those paths remain valid on this machine.
