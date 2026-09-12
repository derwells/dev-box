# Agent attention for tmux

Validated 2026-09-12 with tmux 3.4, Python 3.12, Claude Code 2.1.269, and Codex CLI 0.154.0.
The existing sessions are observed without restarting the coding agents.
No model calls, network requests, or Telegram messages are made.

## Provisioning

`setup.sh` installs this directory under `~/.local/share/agent-attention/`, links the
`agent-attention` command into `~/.local/bin/`, and enables the user systemd service
on login. If the user's service manager is already running, provisioning restarts
the watcher immediately. The tmux include and systemd unit use the configured
user's home directory. Python 3 is provided by cloud-init; there are no pip dependencies.

The base configuration is in `../home/tmux.conf`. The compatibility hook is in
`../claude/hooks/tmux-attention.sh`; `../claude/claude-settings-patch.js` wires it into
Notification/Stop while preserving unrelated hooks. Codex itself is optional and
is not installed by this component. Its absence or an unused fresh installation
does not prevent Claude sessions from appearing.

From the repository, run checks with:

```sh
cd files/agent-attention
python3 -m unittest -v test_attention.py
python3 test_panel_ui.py
```

The UI test runs its own tmux server and points all callbacks to this checkout.
It never sends keys to the running coding-agent sessions.

## Use

- **F12**, **Alt+w**, **prefix w**, or tap the session/count on the top status row: open the full-screen panel.
- Ready sessions and input requests appear first. Enter or tap a row to open its exact pane.
- **Alt+a**: jump through unread alerts. **Alt+d** marks the current pane read without opening F12.
- Inside the panel, **a** toggles unread-only; arrows or j/k move; **d** marks the selected alert read; **q**, Escape, or F12 closes it. Both lines of each entry are clickable, including held phone taps.
- Opening a pane from F12, Alt+a, the window bar, or normal tmux window/pane navigation marks its current alert read. READY stays visible in green; the `+` badge and unread count clear. A new completion creates a fresh unread alert. If completion arrives while you are already in the pane, Alt+d marks it read. A new prompt changes READY to WORKING.
- **prefix Shift+w** retains tmux's original tree and previews.
- F1–F11, Alt+digits, padded window tap targets, and status-bar swipes retain their existing behavior.

Colors carry the state in both the panel and window bar: green READY, amber INPUT, blue WORKING / waiting for agents, red interrupted/error, gray unknown/shell. The panel also spells out the state and shows a small color legend. The SSH terminal's background is retained; the current row uses `>` and bold, not reverse video.

Glyphs supplement color: `+` new completion, `?` new input request, `!` new interruption/error, `~` work in progress, `-` unknown. Once viewed, the alert glyph disappears but the state/color remains. The top row counts **new** alerts, not every idle agent. The panel's row order stays stable while it is open so a live status update cannot move a tap target.

Custom window names stay as they are. Generic `node`/`claude`/shell names get a folder label for display; the panel also shows the agent's existing session title. No naming model or automatic tmux renames are used.

## Completion rules

Codex: identify the root transcript by the live process's open files and its **first** metadata record. Forked transcripts contain copied parent metadata, which must not replace the child's identity. Read explicit task-start/task-complete/interruption events and recursively inspect open child relationships in the local SQLite index. The root becomes ready only after it finishes, all tracked descendants finish, and no active goal is continuing it. Recorded user-input requests get priority. A three-second settling period suppresses rapid automatic continuations.

Claude: combine the live session registry (`busy`, `waiting`, `idle`) with root and child transcript events. `waiting` needs input immediately. Root completion while a tracked background agent is running stays in the waiting-for-agents state. A turn-duration record with zero pending background agents retires old child entries. This prevents historical or interrupted child logs from blocking later turns. The existing Notification/Stop script remains as a compatibility entry point for running clients; it no longer sends Telegram requests.

Read status is separate from lifecycle status and is per pane, so split windows cannot clear each other's alerts. Selecting a row submits the entire jump to stable tmux pane/window IDs in one tmux request; changing the client session last prevents the popup from closing before navigation finishes. Read acknowledgement is keyed to the session and event; a later turn creates a new alert. It does not send a reply or stop any agent.

These checks report lifecycle readiness, not whether the agent's answer is correct or its project is finished. An explicit question may need your attention while other agents continue working. Arbitrary background servers and jobs launched outside the coding agent lifecycle are not counted.

## Operation and limitations

`agent-attention.service` is a user systemd service, enabled on login, sampling every two seconds. JSONL files are read incrementally. The snapshot and dismissal files live in `~/.local/state/agent-attention/` with user-only permissions. Nothing is written into Codex's databases or transcripts. No Codex hook approval or agent restart is required.

This adapter uses local client state formats, which can change after upgrades. Unknown or unreadable states are shown as unknown, not complete; an unavailable/stale watcher is reported in the top bar and panel. Codex completion and recorded question calls are covered; unrecorded Codex permission dialogs are not guaranteed to appear as INPUT. The currently running Codex clients use `--yolo`. Other agent brands show as unknown/shell until an adapter is added.

The configured tmux server is the default local server. This is an in-terminal inbox, not a phone push service; disconnecting and reconnecting retains status.

```sh
agent-attention list                         # current JSON snapshot
agent-attention status                       # compact count
systemctl --user status agent-attention
journalctl --user -u agent-attention -n 30
systemctl --user restart agent-attention
cd ~/.local/share/agent-attention
python3 -m unittest -v test_attention.py
python3 test_panel_ui.py
```

Files: `attention.py` (observer and panel), `tmux.conf` (included from `~/.tmux.conf`), `~/.config/systemd/user/agent-attention.service`, and the compatibility script at `~/.claude/hooks/tmux-attention.sh`.

## Validation

Ten regression tests cover lifecycle completion, read acknowledgements, and a fresh box without Codex. `test_panel_ui.py` uses an isolated tmux server to check both row lines, held taps, exact pane targeting, live list reordering during a gesture, F12/Escape/q, and acknowledging alerts through normal window navigation, at 44 and 120 columns.

Responsiveness investigation: local popup opening measured roughly 70–90 ms, and a stable open panel emitted zero terminal bytes over a one-second idle measurement. The observed SSH transport RTT was about 31–33 ms. The old mouse click synthesis dropped held taps (~300 ms); handling release directly fixes this and removes its 180 ms click-recognition delay. The former three-command window jump could terminate its popup midway through navigation; the single-request jump fixes that separately. These measurements are from this server, not an end-to-end phone benchmark.

## Undo

Back up your tmux configuration before updating an existing box. To undo, disable
the service with `systemctl --user disable --now agent-attention`, restore the
previous `.tmux.conf`, and run `tmux source-file ~/.tmux.conf`. Keep the replacement
Claude hook if you want Telegram to remain disabled. No Telegram credentials are
deleted. Local snapshots, transcripts, credentials, and installation backups are
not part of this repository.
