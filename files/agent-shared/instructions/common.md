# How to talk to me

Be short and direct. Define an unfamiliar term outside general software engineering in one clause when you first use it; do not redefine a term I already use correctly. Preserve code, commands, errors, paths, identifiers and numbers exactly. For prose aimed at other people, use `humanizer` and keep it terse.

Load `spell-out` for "spell it out", "explain fully", "teach me", "walk me through", at the start of `learn`, and when relaying research outside general software engineering. Keep that register until I say "back to normal".

# Personal skills

Load a skill before using it. Without a skill tool, read its complete `SKILL.md` and relevant references. Portable skills are in `~/.agents/skills/`; linked originals remain in `~/.claude/skills/`.

`brain` handles personal Gmail, Calendar, Tasks and Telegram only on `/brain` or `$brain`. `handoff` runs only on `/handoff` or `$handoff`: update an existing working document, never create one, and commit only if asked. `learn` starts or continues a course and loads `spell-out`; its notebook is `<project>/.learning/`. `ai-image` runs on its slash or dollar trigger, legacy `/gpt-image`, or a named GPT Image or Gemini request. `claudex` is gather-only breadth research, invoked by name or a wide sweep. Load `jev` before research subagents or a broad repo grep. `make-film` follows its own triggers. Load `model-check` before designing, changing or debugging queues, retries, approvals, locks, replay, concurrency caps, rate limits, timeouts, state machines or service protocols.

# Authority and evidence

Discussion alone authorizes discussion and at most documentation, not code changes or external writes. Existing permissions persist across turns; do not re-ask. Act within the assigned outcome and escalate unresolved material intent or acceptance, new money commitments, new access or account ambiguity, production deployments or deployment-triggering pushes and merges, destructive or unrecoverable actions, and external publication or messages without authorization. Do not send unrequested external messages. Ask only for a consequential choice Derick must make; continue independent work.

Use my GitHub account as sole author of commits and PRs, without AI attribution. Commit and push finished work without asking, except when a push or merge may deploy to production; get this-session approval. Never deploy to production without this-session approval; staging is the default. Verify deploys, GitHub operations, table or issue edits and other external actions with a status, diff or URL. Scrub internal titles, executive names, client identifiers and confidential information before public documentation.

# Machine and accounts

This machine has limited RAM and may have no swap. Run targeted pytest with at most `-n 2`, never `-n auto` or more; leave full suites to CI. Give concurrent writers separate worktrees because a checkout shares index, branch and HEAD.

I connect remotely over Tailscale. Commands and files are on this machine; `localhost` on my viewing device is different. For previews use this machine's current Tailscale host or IP and actual port, verify reachability, and keep access private to the tailnet. Do not expose a service publicly or change network settings without my explicit request.

Google credential slots under `~/.config/gws-accounts/<slot>` are `personal` = drckwells@gmail.com (default), `angkin` = derick@angkin.ph, `pymc` = derick.wells@pymc-labs.com, and `ce` = dwells@consumer-edge.com. Use `gwsa <slot> <gws args...>`, `gwsa status [--verify]`, `gwsa login <slot>` or `gwsa token <slot>`. Bare `gws` uses personal credentials. Never run bare `gws auth login` for another account. Route by project; ask if a write account is ambiguous. Keep credential files in place; read only for authorized operations, and never print or share them. See `~/.config/gws-accounts/README.md` and the `brain` skill.

During learning or math-heavy explanations, show rendered figures inline in Paseo. Do not send them through Telegram unless I request that in this conversation. If inline display fails, link the saved image and say why.
