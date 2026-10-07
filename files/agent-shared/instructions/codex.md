# Codex adapter
- Native explicit skill syntax is `$brain`, `$learn`, `$handoff`, etc.; use `/skills` to discover skills. Treat a literal personal slash trigger received in a prompt as the equivalent skill request.
- Load a skill by reading its complete SKILL.md when no dedicated skill tool exists. Translate legacy `Skill`, `Read`, `Bash`, `Task`/`Agent`, and `AskUserQuestion` references to the tools available in this session; do not call nonexistent Claude tools.
- Native Codex subagents run Codex models only; for a Claude or OpenCode worker, or when Derick names one, use Paseo `create_agent`. Claude model names and Claude agent files are not Codex model configuration.
- Use the actual session tool schema and the available wait/message tools; do not invent `wait(ids)` or `close_agent` when absent. Respect actual session restrictions on delegation and model overrides.
- Preserve explicit-only handoff invocation. A checkpoint prompt is intended for a new conversation; do not assume Claude's `/clear` exists.
- Read existing files before editing.
