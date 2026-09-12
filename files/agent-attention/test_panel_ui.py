"""Real tmux/PTY regression test: tapping both lines, held taps, and read-on-visit.
Runs on an isolated tmux server; never sends keys to a live coding agent.
"""
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import tempfile
import termios
import time

ROOT = Path(__file__).resolve().parent
socket = f'attention-ui-test-{os.getpid()}'
def tm(*args):
    return subprocess.check_output(['tmux', '-L', socket, *args], text=True).strip()


def run():
    tm('-f', '/dev/null', 'new-session', '-d', '-s', 'test', '-x', '100', '-y', '24')
    tm('set-option', '-sg', 'escape-time', '10')
    try:
        with tempfile.TemporaryDirectory() as temp:
            state = Path(temp)
            tm('new-window', '-d', '-t', 'test', '-n', 'second')
            tm('new-window', '-d', '-t', 'test', '-n', 'third')
            panes = [line.split() for line in tm('list-panes', '-a', '-F', '#{pane_id} #{window_id}').splitlines()]
            rows = [dict(pane=pane, window=window, session='test', index=i + 1, pane_index=1,
                         agent='Codex', name=f'project-{i+1}', label=f'project-{i+1}', state='ready',
                         children=0, title=f'Detail line for project {i+1}', cwd='/tmp', when=1,
                         token=f'event-{i+1}') for i, (pane, window) in enumerate(panes)]
            def save(order=None):
                (state / 'snapshot.json').write_text(json.dumps(dict(rows=order or rows, updated=time.time(), errors=[])))
            save()
            tm('set-environment', '-g', 'AGENT_ATTENTION_STATE', temp)
            tm('set-environment', '-g', 'AGENT_ATTENTION_SOCKET', socket)
            test_config = state / 'tmux.conf'
            test_config.write_text((ROOT / 'tmux.conf').read_text().replace('~/.local/bin/agent-attention', str(ROOT / 'attention.py')))
            tm('source-file', str(test_config))
            tm('bind-key', '-n', 'F12', 'display-popup', '-E', '-w', '100%', '-h', '100%',
               f'{ROOT}/attention.py panel "#{{client_name}}"; tmux -L {socket} set -g @test_exit yes')
            for width in [44, 120]:
                master, slave = pty.openpty()
                fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, width, 0, 0))
                env = dict(os.environ, TERM='xterm-256color')
                env.pop('TMUX', None)
                client = subprocess.Popen(['tmux', '-L', socket, 'attach-session', '-t', 'test'],
                                          stdin=slave, stdout=slave, stderr=slave, env=env)
                os.close(slave)
                def read(seconds=.15, until=None):
                    out = b''
                    end = time.perf_counter() + seconds
                    while time.perf_counter() < end:
                        if select.select([master], [], [], .005)[0]:
                            try:
                                out += os.read(master, 65536)
                            except OSError:
                                break
                        if until and until in out:
                            break
                    return out
                try:
                    read()
                    # Both display lines of each row, including a held gesture.
                    for index, detail, hold in [(0, False, .03), (1, True, .3), (2, False, .3)]:
                        save()
                        tm('set', '-g', '@test_exit', 'no')
                        os.write(master, b'\x1b[24~')
                        out = read(2, b'READY')
                        assert b'READY' in out, 'Panel did not open'
                        read()
                        y = 5 + index * 2 + int(detail)
                        os.write(master, f'\x1b[<0;10;{y}M'.encode())
                        time.sleep(hold)
                        # Reordering the observer's snapshot must not move a held target.
                        save(list(reversed(rows)))
                        os.write(master, f'\x1b[<0;10;{y}m'.encode())
                        read(.25)
                        assert tm('show', '-gv', '@test_exit') == 'yes', 'Tap did not exit'
                        assert tm('display-message', '-p', '#{pane_id}') == panes[index][0], 'Wrong pane opened'
                        seen = json.loads((state / f'seen-{panes[index][0][1:]}.json').read_text())
                        assert seen['token'] == rows[index]['token'], 'Visit did not mark alert read'
                    for name, key in [('F12', b'\x1b[24~'), ('Escape', b'\x1b'), ('q', b'q')]:
                        save()
                        tm('set', '-g', '@test_exit', 'no')
                        os.write(master, b'\x1b[24~')
                        read(2, b'READY')
                        os.write(master, key)
                        read(.25)
                        assert tm('show', '-gv', '@test_exit') == 'yes', name + ' failed to close'
                    print(f'{width} columns: exact-row taps, held taps, read acknowledgement, and close keys passed', flush=True)
                finally:
                    tm('detach-client', '-s', 'test')
                    read()
                    client.wait(timeout=3)
                    os.close(master)
            # Window switching outside the panel also acknowledges the pane.
            target = rows[1]
            seen = state / f"seen-{target['pane'][1:]}.json"
            seen.unlink(missing_ok=True)
            tm('select-window', '-t', rows[0]['window'])
            tm('select-window', '-t', target['window'])
            end = time.monotonic() + 2
            while not seen.exists() and time.monotonic() < end:
                time.sleep(.02)
            assert seen.exists(), 'Window navigation hook did not mark read'
            print('Normal tmux window navigation marks the exact pane read', flush=True)
    finally:
        tm('kill-server')


if __name__ == '__main__':
    run()
