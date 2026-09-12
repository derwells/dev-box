#!/usr/bin/python3
"""Local tmux attention inbox. Python stdlib only; never sends session data out."""
import argparse
import collections
import curses
import datetime
import fcntl
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import time

HOME = Path.home()
STATE = Path(os.environ.get('AGENT_ATTENTION_STATE', HOME / '.local/state/agent-attention'))
CODEX = Path(os.environ.get('CODEX_HOME', HOME / '.codex'))
CLAUDE = HOME / '.claude'
ATTENTION = {'input', 'ready', 'interrupted', 'error'}
ORDER = {'input': 0, 'error': 1, 'interrupted': 2, 'ready': 3, 'children': 4, 'working': 5, 'unknown': 6, 'seen': 7, 'shell': 8}
MARK = {'input': '?', 'error': '!', 'interrupted': '!', 'ready': '+', 'children': '~', 'working': '~', 'unknown': '-', 'seen': '.', 'shell': ''}
COLORS = {'input': 130, 'error': 160, 'interrupted': 160, 'ready': 28,
          'children': 25, 'working': 25, 'settling': 25, 'unknown': 240, 'shell': 240}
GENERIC = {'node', 'claude', 'codex', 'zsh', 'bash', 'fish'}


def clean(value, limit=120):
    return ''.join(c for c in str(value or '') if c.isprintable()).replace('#', '').strip()[:limit]


def atomic(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = path.with_name(path.name + '.' + str(os.getpid()))
    tmp.write_text(json.dumps(value))
    tmp.chmod(0o600)
    tmp.replace(path)


def read_json(path, default=None):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


def needs_attention(row):
    return row.get('unread', row['state'] in ATTENTION)


def row_order(row):
    if needs_attention(row):
        return ORDER.get(row['state'], 5)
    if row['state'] in ATTENTION:
        return 7
    return ORDER.get(row['state'], 5)


def apply_read_state(row):
    seen = read_json(STATE / ('seen-' + row['pane'][1:] + '.json'), {})
    row['unread'] = row['state'] in ATTENTION and seen.get('token') != row['token']
    return row


def tmux(*args):
    cmd = ['tmux']
    if os.environ.get('AGENT_ATTENTION_SOCKET'):
        cmd += ['-L', os.environ['AGENT_ATTENTION_SOCKET']]
    p = subprocess.run(cmd + list(args), capture_output=True, text=True, timeout=4)
    if p.returncode:
        raise RuntimeError(p.stderr.strip())
    return p.stdout.strip()


def timestamp(value):
    try:
        return datetime.datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()
    except (ValueError, AttributeError):
        return time.time()


class Transcript:
    """Incrementally consume complete JSONL records, retaining lifecycle data only."""
    def __init__(self, path, kind):
        self.path, self.kind, self.offset, self.inode = Path(path), kind, 0, None
        self.status, self.when, self.turn = 'unknown', 0, ''
        self.meta, self.title, self.pending = {}, '', 0
        self.children, self.questions = set(), {}

    def update(self):
        try:
            stat = self.path.stat()
            if stat.st_ino != self.inode or stat.st_size < self.offset:
                self.__init__(self.path, self.kind)
                self.inode = stat.st_ino
            with self.path.open('rb') as f:
                f.seek(self.offset)
                for line in f:
                    if not line.endswith(b'\n'):
                        break
                    self.offset += len(line)
                    try:
                        self.consume(json.loads(line))
                    except (ValueError, TypeError, KeyError):
                        continue
        except OSError:
            self.status = 'unknown'
        return self

    def set_status(self, status, row):
        self.status, self.when = status, timestamp(row.get('timestamp'))

    def consume(self, row):
        if self.kind == 'codex':
            p = row.get('payload', {})
            if row.get('type') == 'session_meta' and not self.meta:
                self.meta = {k: p.get(k) for k in ['id', 'session_id', 'source', 'cwd', 'agent_path']}
            elif row.get('type') == 'event_msg':
                event = p.get('type')
                if event == 'task_started':
                    self.turn = p.get('turn_id', '')
                    self.questions.clear()
                    self.set_status('working', row)
                elif event in {'task_complete', 'turn_aborted'}:
                    if p.get('turn_id', self.turn) == self.turn:
                        self.set_status('ready' if event == 'task_complete' else 'interrupted', row)
                        self.questions.clear()
                elif event == 'item_completed' and p.get('item', {}).get('type') == 'UserMessage':
                    self.questions.clear()
            elif row.get('type') == 'response_item':
                if p.get('type') == 'function_call' and p.get('name', '').split('.')[-1] in {'request_user_input', 'request_user_input_async'}:
                    self.questions[p.get('call_id', p.get('id'))] = p.get('name', '')
                elif p.get('type') == 'function_call_output':
                    key = p.get('call_id')
                    if not self.questions.get(key, '').endswith('_async'):
                        self.questions.pop(key, None)
        else:
            if row.get('isSidechain') and '/subagents/' not in str(self.path):
                return
            typ = row.get('type')
            if typ == 'ai-title':
                self.title = clean(row.get('aiTitle'))
            elif typ == 'user':
                self.set_status('working', row)
                result = row.get('toolUseResult', {})
                if isinstance(result, dict) and result.get('agentId') and result.get('isAsync'):
                    self.children.add(result['agentId'])
            elif typ == 'assistant':
                self.set_status('ready' if row.get('message', {}).get('stop_reason') == 'end_turn' else 'working', row)
            elif typ == 'system' and row.get('subtype') == 'turn_duration':
                self.pending = row.get('pendingBackgroundAgentCount', 0)
                if not self.pending:
                    self.children.clear()
                self.set_status('ready', row)


class Observer:
    def __init__(self):
        self.cache, self.published = {}, {}
        self.stable = {}
        self.errors = []

    def transcript(self, path, kind):
        key = str(path)
        if key not in self.cache:
            self.cache[key] = Transcript(path, kind)
        return self.cache[key].update()

    def processes(self):
        result = []
        # /proc comm avoids reading command lines containing unrelated credentials.
        for proc in Path('/proc').iterdir():
            if not proc.name.isdigit():
                continue
            try:
                if proc.stat().st_uid != os.getuid():
                    continue
                kind = proc.joinpath('comm').read_text().strip()
                if kind != 'codex':
                    continue
                env = {}
                for field in proc.joinpath('environ').read_bytes().split(b'\0'):
                    if field.startswith((b'TMUX=', b'TMUX_PANE=', b'CODEX_HOME=')):
                        k, v = field.decode().split('=', 1)
                        env[k] = v
                paths = []
                for fd in proc.joinpath('fd').iterdir():
                    try:
                        target = os.readlink(fd)
                        if '/sessions/' in target and '/rollout-' in target and target.endswith('.jsonl'):
                            paths.append(target)
                    except OSError:
                        pass
                result.append((int(proc.name), env, paths))
            except (OSError, ValueError):
                continue
        return result

    def codex_rows(self):
        output = {}
        if not (CODEX / 'state_5.sqlite').exists():
            return output  # Codex is optional and creates its database on first use.
        with sqlite3.connect(f'file:{CODEX / "state_5.sqlite"}?mode=ro', uri=True, timeout=1) as db:
            db.row_factory = sqlite3.Row
            threads = {r['id']: dict(r) for r in db.execute('SELECT id,rollout_path,source,cwd,title,name FROM threads')}
            edges = collections.defaultdict(list)
            for parent, child, status in db.execute('SELECT parent_thread_id,child_thread_id,status FROM thread_spawn_edges'):
                if status == 'open':
                    edges[parent].append(child)
        goals = {}
        if (CODEX / 'goals_1.sqlite').exists():
            with sqlite3.connect(f'file:{CODEX / "goals_1.sqlite"}?mode=ro', uri=True, timeout=1) as db:
                goals = dict(db.execute('SELECT thread_id,status FROM thread_goals'))
        for pid, env, paths in self.processes():
            pane = env.get('TMUX_PANE')
            if not pane:
                continue
            roots = []
            for path in paths:
                t = self.transcript(path, 'codex')
                if t.meta.get('source') == 'cli':
                    roots.append(t)
            if len(roots) != 1:
                continue  # Never guess among ambiguous sessions sharing a process.
            root = roots[0]
            sid = root.meta.get('id') or root.meta.get('session_id')
            info = threads.get(sid, {})
            active, unknown, visited = 0, 0, {sid}
            todo = list(edges[sid])
            while todo:
                child = todo.pop()
                if child in visited:
                    continue
                visited.add(child)
                todo.extend(edges[child])
                child_info = threads.get(child)
                if not child_info:
                    unknown += 1
                    continue
                child_state = self.transcript(child_info['rollout_path'], 'codex').status
                active += child_state == 'working'
                unknown += child_state == 'unknown'
            state = root.status
            if root.questions:
                state = 'input'
            elif state == 'ready':
                if active:
                    state = 'children'
                elif unknown:
                    state = 'unknown'
                elif goals.get(sid) == 'active':
                    state = 'working'
            output[pane] = dict(agent='Codex', sid=sid, pid=pid, state=state, when=root.when,
                                children=active, cwd=info.get('cwd', root.meta.get('cwd', '')),
                                title=clean(info.get('name') or info.get('title')), source='Codex lifecycle')
        return output

    def claude_rows(self):
        output = {}
        for path in (CLAUDE / 'sessions').glob('*.json'):
            data = read_json(path, {})
            pid = data.get('pid')
            try:
                proc = Path('/proc') / str(pid)
                if proc.joinpath('comm').read_text().strip() != 'claude':
                    continue
                # Guard stale registry files after PID reuse.
                start = proc.joinpath('stat').read_text().rsplit(')', 1)[1].split()[19]
                if data.get('procStart') and str(data['procStart']) != start:
                    continue
            except OSError:
                continue
            pane_match = re.search(r'(%\d+)$', data.get('tmux', ''))
            if not pane_match:
                continue
            pane, sid = pane_match[1], data.get('sessionId', '')
            cwd = data.get('cwd', '')
            # Session registry survives cwd changes; search only exact session UUID.
            key = 'claude-path:' + sid
            if key not in self.cache:
                candidates = list((CLAUDE / 'projects').glob('*/' + sid + '.jsonl'))
                if candidates:
                    self.cache[key] = candidates[0]
            root = self.transcript(self.cache[key], 'claude') if key in self.cache else None
            active, unknown = 0, 0
            if root:
                visited, todo = set(), list(root.children)
                while todo:
                    child = todo.pop()
                    if child in visited:
                        continue
                    visited.add(child)
                    child_path = root.path.with_suffix('') / 'subagents' / ('agent-' + child + '.jsonl')
                    child_state = self.transcript(child_path, 'claude')
                    active += child_state.status == 'working'
                    unknown += child_state.status == 'unknown'
                    todo.extend(child_state.children)
            native = data.get('status')
            state = 'working' if native == 'busy' else 'unknown'
            if native == 'idle' and root:
                # Local slash commands also append user records, without an agent turn.
                state = 'ready' if root.when else 'unknown'
            if root and root.status == 'ready' and active:
                state = 'children'
            elif state == 'ready' and (unknown or root.pending > len(root.children)):
                state = 'unknown'
            if native == 'waiting':
                state = 'input'
            when = max(root.when if root else 0, data.get('statusUpdatedAt', 0) / 1000)
            hook = read_json(STATE / ('hook-' + pane[1:] + '.json'), {})
            if hook.get('sid') == sid and hook.get('when', 0) >= when and hook.get('event') == 'input':
                state, when = 'input', hook['when']
            output[pane] = dict(agent='Claude', sid=sid, pid=pid, state=state, when=when,
                                children=active, cwd=cwd, title=root.title if root else '', source='Claude session registry + lifecycle')
        return output

    def sample(self):
        fmt = '\t'.join('#{' + k + '}' for k in ['pane_id', 'session_name', 'window_id', 'window_index', 'pane_index', 'window_name', 'pane_current_path', 'pane_current_command'])
        panes = [line.split('\t') for line in tmux('list-panes', '-a', '-F', fmt).splitlines()]
        agents = {}
        self.errors = []
        for label, collect in [('Codex', self.codex_rows), ('Claude', self.claude_rows)]:
            try:
                agents.update(collect())
            except (OSError, ValueError, sqlite3.Error) as e:
                self.errors.append(label + ': ' + str(e))
        rows = []
        for fields in panes:
            if len(fields) != 8:
                continue
            pane, session, window, wi, pi, name, cwd, command = fields
            row = agents.get(pane, dict(agent='', sid='', state='shell', when=0, children=0, cwd=cwd, title='', source=''))
            row = dict(row, pane=pane, session=session, window=window, index=int(wi), pane_index=int(pi), name=clean(name))
            row['label'] = clean(Path(row['cwd']).name) if name in GENERIC else clean(name)
            row['label'] = row['label'] or clean(name)
            if row['state'] == 'shell' and command in {'node', 'codex', 'claude'}:
                row['state'] = 'unknown'
            signature = (row['sid'], row['state'], row['when'])
            if self.stable.get(pane, (None,))[0] != signature:
                self.stable[pane] = (signature, time.monotonic())
            # Suppress transient root-stop / automatic-continuation races.
            if row['state'] == 'ready' and time.monotonic() - self.stable[pane][1] < 3:
                row['state'] = 'settling'
            row['token'] = f"{row['sid']}:{row['when']}:{row['state']}"
            apply_read_state(row)
            rows.append(row)
        rows.sort(key=lambda r: (row_order(r), r['when'] if needs_attention(r) else 0, r['session'], r['index'], r['pane_index']))
        atomic(STATE / 'snapshot.json', dict(updated=time.time(), rows=rows, errors=self.errors))
        self.publish(rows)
        return rows

    def option(self, scope, target, key, value):
        cache_key = (scope, target, key)
        if self.published.get(cache_key) != value:
            args = ['set-option', scope]
            if target:
                args += ['-t', target]
            tmux(*args, key, str(value))
            self.published[cache_key] = value

    def publish(self, rows):
        windows = collections.defaultdict(list)
        for row in rows:
            windows[row['window']].append(row)
        for window, group in windows.items():
            top = min(group, key=row_order)
            mark = MARK.get(top['state'], '~')
            if top['state'] in ATTENTION and not needs_attention(top):
                mark = ''
            self.option('-w', window, '@agent_mark', mark)
            self.option('-w', window, '@agent_color', 'colour' + str(COLORS.get(top['state'], 240)))
            self.option('-w', window, '@agent_label', top['label'])
        count = sum(needs_attention(r) for r in rows)
        busy = sum(r['state'] in {'working', 'children', 'settling'} for r in rows)
        self.option('-g', '', '@agent_summary', f'{count} new | {busy} working')


def snapshot():
    data = read_json(STATE / 'snapshot.json', {'rows': [], 'updated': 0, 'errors': []})
    for row in data['rows']:
        apply_read_state(row)
    return data


def select(row, client):
    # IDs remain stable when tmux renumbers windows.
    if not client:
        client = tmux('display-message', '-p', '#{client_name}')
    dismiss(row)
    # Changing the client's session can destroy this popup and its process.
    # Submit the complete jump to tmux in one request, with that switch last.
    tmux('select-window', '-t', row['window'], ';',
         'select-pane', '-t', row['pane'], ';',
         'switch-client', '-c', client, '-t', row['session'])


def dismiss(row):
    if row['state'] in ATTENTION:
        atomic(STATE / ('seen-' + row['pane'][1:] + '.json'), {'token': row['token']})


def mark_read(pane):
    if not re.fullmatch(r'%\d+', pane):
        return
    data = snapshot()
    if time.time() - data['updated'] > 12:
        return
    for row in data['rows']:
        if row['pane'] == pane:
            dismiss(row)
            break


def panel(client):
    def run(screen):
        # curses.wrapper starts colors with white-on-black pair zero. Restore
        # the SSH terminal's foreground/background instead of imposing a theme.
        if curses.has_colors():
            curses.use_default_colors()
        colors = {}
        if curses.has_colors():
            for pair, color in enumerate(sorted(set(COLORS.values())), 1):
                fallback = {25: curses.COLOR_BLUE, 28: curses.COLOR_GREEN, 130: curses.COLOR_YELLOW,
                            160: curses.COLOR_RED, 240: -1}
                curses.init_pair(pair, color if curses.COLORS >= 256 else fallback[color], -1)
                colors[color] = curses.color_pair(pair)
        screen.bkgd(' ', curses.A_NORMAL)
        curses.set_escdelay(100)
        curses.curs_set(0)
        screen.timeout(150)
        curses.mousemask(curses.ALL_MOUSE_EVENTS)
        # Handle release directly: click synthesis loses held taps and adds a
        # double-click delay. A release also consumes the entire gesture here.
        curses.mouseinterval(0)
        selected, only, offset = None, False, 0
        positions = {}
        pressed = None
        while True:
            data = snapshot()
            for row in data['rows']:
                positions.setdefault(row['pane'], len(positions))
            rows = sorted([r for r in data['rows'] if not only or needs_attention(r)],
                          key=lambda r: positions[r['pane']])
            index = next((i for i, r in enumerate(rows) if r['pane'] == selected), 0)
            if rows:
                selected = rows[index]['pane']
            screen.erase()
            h, w = screen.getmaxyx()
            def write(y, text, attr=0):
                if 0 <= y < h:
                    try:
                        screen.addnstr(y, 0, clean(text, 1000), max(0, w - 1), attr)
                    except curses.error:
                        pass
            count = sum(needs_attention(r) for r in data['rows'])
            write(0, f'AGENTS  {count} new  |  ' + ('Unread only' if only else 'All panes'), curses.A_BOLD)
            stale = time.time() - data['updated'] > 12
            write(1, 'Status unavailable: watcher needs attention' if stale or data.get('errors') else 'Tap a row to open and mark read')
            if not stale and not data.get('errors'):
                for x, word, color in [(0, 'READY', 28), (8, 'INPUT', 130), (16, 'WORKING', 25)]:
                    try:
                        screen.addnstr(2, x, word, max(0, w - x - 1), colors.get(color, 0))
                    except curses.error:
                        pass
            visible = max(1, (h - 4) // 2)
            offset = max(0, min(offset, index))
            if index >= offset + visible:
                offset = index - visible + 1
            for n, row in enumerate(rows[offset:offset + visible]):
                current = n + offset == index
                attr = curses.A_BOLD if current or needs_attention(row) else curses.A_NORMAL
                state = row['state']
                attr |= colors.get(COLORS.get(state, 240), 0)
                label = {'input': 'INPUT', 'ready': 'READY', 'children': f"WAIT {row['children']} agents", 'working': 'WORKING', 'settling': 'FINISHING', 'unknown': 'UNKNOWN', 'seen': 'SEEN', 'shell': 'SHELL', 'error': 'ERROR', 'interrupted': 'STOPPED'}[state]
                where = f"{row['index']}.{row['pane_index']}" if row['pane_index'] != 1 else str(row['index'])
                badge = MARK.get(state, '') if needs_attention(row) else ''
                write(3 + n * 2, f"{'>' if current else ' '} {where:>3} {badge:1} {label:<10} {row['label']}", attr)
                detail = f"     {row['agent'] or row['session']}  {row['title'] or row['cwd']}"
                write(4 + n * 2, detail)
            if not rows:
                write(3, 'No sessions need your attention.' if only else 'Waiting for session status...')
            write(h - 1, 'q/F12 close | a unread | d mark read' + (' | STALE' if stale else ''))
            screen.refresh()
            key = screen.getch()
            if key in [ord('q'), 27, curses.KEY_F12]:
                return
            if key in [ord('a')]:
                only = not only
                offset = 0
            elif rows and key in [curses.KEY_DOWN, ord('j')]:
                selected = rows[min(len(rows) - 1, index + 1)]['pane']
            elif rows and key in [curses.KEY_UP, ord('k')]:
                selected = rows[max(0, index - 1)]['pane']
            elif rows and key in [10, 13, curses.KEY_ENTER]:
                return rows[index]
            elif rows and key == ord('d') and needs_attention(rows[index]):
                dismiss(rows[index])
            elif key == curses.KEY_MOUSE:
                try:
                    _, x, y, _, buttons = curses.getmouse()
                except curses.error:
                    continue
                target = offset + (y - 3) // 2
                if y >= 3 and y < h - 1 and 0 <= target < len(rows):
                    hit = rows[target]
                    if buttons & curses.BUTTON1_PRESSED:
                        pressed = hit['pane']
                        selected = hit['pane']
                    if buttons & (curses.BUTTON1_RELEASED | curses.BUTTON1_CLICKED):
                        if pressed is None or pressed == hit['pane']:
                            return hit
                        pressed = None
                if buttons & getattr(curses, 'BUTTON4_PRESSED', 0) and rows:
                    selected = rows[max(0, index - 1)]['pane']
                if buttons & getattr(curses, 'BUTTON5_PRESSED', 0) and rows:
                    selected = rows[min(len(rows) - 1, index + 1)]['pane']
    chosen = curses.wrapper(run)
    if chosen:
        select(chosen, client)


def hook(event):
    data = json.load(sys.stdin)
    pane = os.environ.get('TMUX_PANE', '')
    if not re.fullmatch(r'%\d+', pane):
        return
    # Stop is intentionally only a wake-up hint: the observer checks children.
    notification = data.get('notification_type', '')
    needs_input = event == 'notify' and notification in {'permission_prompt', 'elicitation_dialog'}
    if needs_input:
        atomic(STATE / ('hook-' + pane[1:] + '.json'), dict(sid=data.get('session_id'), when=time.time(), event='input'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['watch', 'once', 'list', 'status', 'panel', 'next', 'read', 'hook'])
    parser.add_argument('argument', nargs='?', default='')
    args = parser.parse_args()
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    if args.command == 'watch':
        with (STATE / 'watch.lock').open('w') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return
            observer = Observer()
            while True:
                try:
                    observer.sample()
                except Exception as e:
                    print(f'attention: {type(e).__name__}: {e}', file=sys.stderr, flush=True)
                    observer.published.clear()
                time.sleep(2)
    elif args.command == 'once':
        print(json.dumps(Observer().sample(), indent=2))
    elif args.command == 'list':
        print(json.dumps(snapshot(), indent=2))
    elif args.command == 'status':
        data = snapshot()
        if time.time() - data['updated'] > 12 or data.get('errors'):
            print('Agent status unavailable')
        else:
            count = sum(needs_attention(r) for r in data['rows'])
            busy = sum(r['state'] in {'working', 'children', 'settling'} for r in data['rows'])
            print(f'{count} new | {busy} working')
    elif args.command == 'panel':
        panel(args.argument)
    elif args.command == 'next':
        data = snapshot()
        if time.time() - data['updated'] > 12:
            tmux('display-message', 'Agent status is stale; open F12')
            return
        rows = [r for r in data['rows'] if needs_attention(r)]
        if rows:
            current = tmux('display-message', '-p', '-c', args.argument, '#{pane_id}') if args.argument else os.environ.get('TMUX_PANE')
            index = next((i + 1 for i, r in enumerate(rows) if r['pane'] == current), 0) % len(rows)
            select(rows[index], args.argument)
        else:
            tmux('display-message', 'No agents need your attention')
    elif args.command == 'hook':
        hook(args.argument)
    elif args.command == 'read':
        mark_read(args.argument)


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError) as exc:
        if len(sys.argv) > 1 and sys.argv[1] == 'hook':
            sys.exit(0)  # An observation failure must never block the agent.
        raise SystemExit(str(exc))
