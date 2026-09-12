# graphify
- **graphify** (`~/.claude/skills/graphify/SKILL.md`) - any input to knowledge graph. Trigger: `/graphify`
When the user types `/graphify`, invoke the Skill tool with `skill: "graphify"` before doing anything else.

# claudex
- **claudex** (`~/.claude/skills/claudex/SKILL.md`) - en-masse parallel research via `claudex -p` on token-efficient models; prefer it for any broad scouring/docs/codebase-survey task to spare main context and quota. Gather-only — the main agent makes the decisions. Trigger: `/claudex`, or proactively for breadth tasks.
When the user types `/claudex`, or a task needs broad fan-out research, invoke the Skill tool with `skill: "claudex"` before doing anything else.

# brain
- **brain** (`~/.claude/skills/brain/SKILL.md`) - personal command center: Gmail/Calendar/Tasks via the global `gws` CLI + Telegram push (secrets: `~/.claude/telegram_bot_token`, `~/.claude/telegram_chat_id`). Trigger: `/brain`
When the user types `/brain`, invoke the Skill tool with `skill: "brain"` before doing anything else.

# Google accounts on this machine (multi-account gws, 2026-08-25)
Four Google accounts, each with an isolated `gws` credential store under
`~/.config/gws-accounts/<slot>`: `personal`=drckwells@gmail.com (default),
`angkin`=derick@angkin.ph, `pymc`=derick.wells@pymc-labs.com,
`ce`=dwells@consumer-edge.com. Use the `gwsa` executable (on PATH, works in
tool calls): `gwsa <slot> <gws args...>`, `gwsa status [--verify]`,
`gwsa login <slot>`, `gwsa token <slot>`. Bare `gws` = personal (symlink).
NEVER run bare `gws auth login` for a non-personal account — it overwrites
personal's credentials; always `gwsa login <slot>`. Route account by project
context; if ambiguous on a write, ask. Docs:
`~/.config/gws-accounts/README.md`; ops manual: brain SKILL.md.

# Standing defaults (mined from session history, 2026-08-16)
- **Discuss ≠ implement.** When I say "let's discuss / think about / talk about" or ask "what do you think", do NOT write code, post anything, or make changes — discuss and (at most) document.
- **Prod safety.** Never deploy to production without my explicit approval in this session. Default deploys to staging. Before merging/pushing to a branch that may trigger a prod deploy, say so and ask.
- **Verify, don't assert.** After deploys, gh operations, table/issue edits, or anything external: run a check command and show the evidence (URL, status, diff) instead of claiming success. I shouldn't have to ask "are you sure".
- **Delegate breadth by default.** Broad research (codebase surveys, doc sweeps, web research, asset hunts) goes to /claudex or haiku/sonnet subagents without me asking.
- **Commits.** "ok commit" = conventional message, my authorship only (no Claude attribution/co-author). Push only where I said. When work spans repos, ask which unless I said "both".
- **Plain language.** Spell things out; define jargon on first use (I'm not a statistician). I should be able to follow even tired.
- **User-facing text and PR descriptions** get /humanizer treatment: direct, terse, no AI-slop phrasing.
- **Public repos:** scrub internal titles, names of executives, client identifiers, and anything confidential before writing docs.
