---
name: claudex
description: >
  En-masse parallel research via `claudex` — Claude Code routed to
  token-efficient MiMo models. Use for any breadth task (scouring a codebase,
  surveying docs, reading many files/repos) where fan-out reading would burn
  the main context or Anthropic quota: shell out headless (`claudex -p "..."`)
  and let it spawn many subagents on the cheap plan. Gather-only — claudex
  collects and reports; the main agent makes all decisions and does all
  editing. Trigger: /claudex, or proactively for broad scouring tasks.
compatibility: claude-code
allowed-tools:
  - Bash
  - Read
---

# claudex — en-masse parallel research harness

`/usr/local/bin/claudex` is Claude Code with the API rerouted to Xiaomi MiMo's
token plan (`sonnet`/`haiku` map to `mimo-v2.5`; `opus`/`fable` map to
`mimo-v2.5-pro`). Tokens
it burns come off the MiMo plan, **not** the main Anthropic quota — that is the
entire point. Treat it as a disposable search harness: cheap context, cheap
subagents, cheap re-runs.

## The contract

- **Gather-only.** claudex researches and reports. It does NOT make decisions,
  weigh trade-offs, or edit files. The main agent reads its report and decides.
- **Prefer it for breadth.** Any task shaped like "read a lot, return a
  little" — mapping a codebase, surveying docs, finding every call site,
  summarizing many files — goes to claudex instead of reading in main context.
- **Keep depth here.** Single-file lookups you can answer in one Read/Grep are
  faster done directly.

## Preflight

- Token: `MIMO_API_KEY` env var, else `~/.claude/mimo_token`. The wrapper
  errors clearly if neither exists.
- Plan exhausted? claudex can run on MiMo pay-as-you-go instead (same
  `sk-...` key as the search bridge: `MIMO_PAYGO_KEY` or
  `~/.claude/mimo_paygo_token`). Per run: `claudex --paygo -p "..."`.
  Persistent: `echo paygo > ~/.claude/claudex_backend` (write `plan` or
  delete the file to switch back when the plan renews). If no plan token
  exists at all, it falls back to PAYG automatically.
- Web search: MiMo has no server-side WebSearch. The wrapper auto-loads
  `~/.claude/search_mcp.json` as an MCP search tool and disables the dead
  built-in — web research works, no extra flags needed.
- **Both backends dead (402 Insufficient account balance on plan AND paygo)?**
  Don't retry and don't block the task — fall back to Anthropic-side subagents
  via the Agent tool (user-approved standing policy, 2026-08-11): spawn
  `general-purpose`/`Explore` agents with `model: "haiku"` for mechanical
  breadth (file sweeps, call-site hunts, doc scans) or `model: "sonnet"` when
  the gathering needs judgment (web research synthesis, summarizing subtle
  material). Same contract applies: gather-only, report back, main agent
  decides. Fan out several in one message for independent questions. Mention
  to the user that claudex is out of balance so they can top it up.

## Headless cookbook

**Basic one-shot** (prints the answer and exits):
```bash
claudex -p "Map every place this repo touches the Telegram API. Return file:line + one-line role for each."
```

**Read-only research run** — headless mode can't prompt for permissions, so
allowlist the read tools it needs; anything else silently fails:
```bash
claudex -p "Survey how error handling works across src/. Report patterns with file:line evidence." \
  --allowedTools "Read Glob Grep WebFetch Bash(rg:*) Bash(fd:*) Bash(ls:*) Bash(git log:*) Bash(git show:*) Bash(git diff:*)"
```
Belt-and-braces if the task tempts it to fix things:
`--disallowedTools "Edit Write NotebookEdit"`.

**GOTCHA — prompt position.** `--allowedTools` and `--disallowedTools` are
*variadic*: they greedily consume every following bare argument as a tool
rule. A prompt placed after them is eaten word-by-word ("Permission deny rule
"Scan" matches no known tool" × every word, exit 1, empty output). Always put
the prompt **immediately after `-p`**, all flags after the prompt.

**Fan-out inside one claudex** — tell it explicitly to parallelize; subagent
spawning needs no permission grants:
```bash
claudex -p "Spawn one Explore subagent per top-level directory in this repo, in parallel.
Each maps its directory's purpose, key files, and external dependencies.
Synthesize into a single markdown report."
```

**Fan-out of claudex processes** — for independent research questions, launch
several in the background, each writing to the scratchpad, then read the files:
```bash
d="$SCRATCHPAD"   # session scratchpad dir
claudex -p "Research question A..." --no-session-persistence > "$d/a.md" 2>"$d/a.err" &
claudex -p "Research question B..." --no-session-persistence > "$d/b.md" 2>"$d/b.err" &
wait
```
From inside Claude Code, prefer one Bash call per claudex with
`run_in_background: true` over `&`/`wait` — you get notified as each finishes.
Long runs: raise the Bash `timeout` (max 600000 ms) or background them.

**Structured output** for parsing instead of prose:
```bash
claudex -p --output-format json "..." | jq -r .result      # answer text
claudex -p --output-format json "..." | jq .total_cost_usd  # spend check
```
Or force a shape: `--json-schema '{"type":"object",...}'`.

**Pipe context in** rather than describing it:
```bash
git diff main... | claudex -p "Summarize what this change does, file by file."
```

**Model choice**: the default (and `--model sonnet`/`haiku`) is `mimo-v2.5` —
keep fan-out and mechanical breadth there. `--model opus` or `--model fable`
escalates to `mimo-v2.5-pro`: use it sparingly, for a synthesis pass or a run
that needs stronger judgment, not for wide fan-outs.

**Follow-ups** reuse the previous run's context instead of re-reading:
```bash
claudex -p -c "Now list only the call sites that lack a timeout."
```
(Continues the most recent conversation in the cwd — don't combine with
`--no-session-persistence` on the first run if you'll want this.)

**Scope**: claudex sees the directory it's launched from. `cd` to the target
repo root first; add extra roots with `--add-dir /path/other-repo`.

## Prompting claudex well

Every prompt should state, in one block: the question, where to look, how to
parallelize ("spawn N subagents, one per X"), and the **output contract** —
structured markdown or JSON with `file:line` references so the main agent can
spot-verify claims cheaply without re-reading. claudex output is a lead
sheet, not ground truth: verify load-bearing claims before acting on them.
