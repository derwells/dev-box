"""Regression cases for premature completion and incorrect pane attribution."""
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch
import attention as a


def event(kind, turn='turn'):
    return {'timestamp': '2026-09-12T01:00:00Z', 'type': 'event_msg', 'payload': {'type': kind, 'turn_id': turn}}


def meta(sid, source='cli'):
    return {'type': 'session_meta', 'payload': {'id': sid, 'source': source, 'cwd': '/tmp/project'}}


class LifecycleTests(unittest.TestCase):
    def test_codex_is_optional_on_a_fresh_box(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(a, 'CODEX', Path(tmp)):
            self.assertEqual(a.Observer().codex_rows(), {})

    def test_copied_parent_metadata_does_not_turn_child_into_root(self):
        t = a.Transcript('/unused', 'codex')
        t.consume(meta('child', {'subagent': {}}))
        t.consume(meta('parent'))
        self.assertEqual(t.meta['id'], 'child')

    def test_old_completion_does_not_finish_current_turn(self):
        t = a.Transcript('/unused', 'codex')
        t.consume(event('task_started', 'new'))
        t.consume(event('task_complete', 'old'))
        self.assertEqual(t.status, 'working')

    def test_partial_record_waits_for_newline(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / 'rollout.jsonl'
            text = json.dumps(event('task_complete'))
            p.write_text(json.dumps(event('task_started')) + '\n' + text[:-5])
            t = a.Transcript(p, 'codex').update()
            self.assertEqual(t.status, 'working')
            with p.open('a') as f:
                f.write(text[-5:] + '\n')
            self.assertEqual(t.update().status, 'ready')
            p.write_text(json.dumps(event('task_started')) + '\n')
            self.assertEqual(t.update().status, 'working')

    def test_question_is_cleared_when_answered(self):
        t = a.Transcript('/unused', 'codex')
        t.consume(event('task_started'))
        t.consume({'type': 'response_item', 'payload': {'type': 'function_call', 'name': 'request_user_input', 'call_id': 'q'}})
        self.assertTrue(t.questions)
        t.consume({'type': 'response_item', 'payload': {'type': 'function_call_output', 'call_id': 'q'}})
        self.assertFalse(t.questions)

    def test_claude_zero_pending_retires_old_children(self):
        t = a.Transcript('/unused', 'claude')
        t.consume({'type': 'user', 'toolUseResult': {'isAsync': True, 'agentId': 'old'}})
        t.consume({'type': 'system', 'subtype': 'turn_duration', 'pendingBackgroundAgentCount': 0})
        self.assertFalse(t.children)
        t.consume({'type': 'user', 'toolUseResult': {'isAsync': True, 'agentId': 'new'}})
        t.consume({'type': 'system', 'subtype': 'turn_duration', 'pendingBackgroundAgentCount': 1})
        self.assertEqual(t.children, {'new'})

    def test_claude_tool_use_is_not_completion(self):
        t = a.Transcript('/unused/subagents/agent-x.jsonl', 'claude')
        t.consume({'type': 'assistant', 'message': {'stop_reason': 'tool_use'}})
        self.assertEqual(t.status, 'working')
        t.consume({'type': 'assistant', 'message': {'stop_reason': 'end_turn'}})
        self.assertEqual(t.status, 'ready')

    def test_root_waits_for_nested_children_and_goal(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(a, 'CODEX', Path(tmp)):
            root, child, grandchild = [Path(tmp) / (x + '.jsonl') for x in ['root', 'child', 'grandchild']]
            root.write_text('\n'.join(map(json.dumps, [meta('root'), event('task_started'), event('task_complete')])) + '\n')
            child.write_text('\n'.join(map(json.dumps, [meta('child', {'subagent': {}}), meta('root'), event('task_started'), event('task_complete')])) + '\n')
            grandchild.write_text('\n'.join(map(json.dumps, [meta('grandchild', {'subagent': {}}), event('task_started')])) + '\n')
            with sqlite3.connect(Path(tmp) / 'state_5.sqlite') as db:
                db.execute('create table threads (id, rollout_path, source, cwd, title, name)')
                db.executemany('insert into threads values (?,?,?,?,?,?)', [(p.stem,str(p),'cli' if p==root else 'subagent','/tmp','Title',None) for p in [root,child,grandchild]])
                db.execute('create table thread_spawn_edges (parent_thread_id,child_thread_id,status)')
                db.executemany('insert into thread_spawn_edges values (?,?,?)', [('root','child','open'),('child','grandchild','open')])
            observer = a.Observer()
            with patch.object(observer, 'processes', return_value=[(123, {'TMUX_PANE':'%1'}, [str(root), str(child), str(grandchild)])]):
                row = observer.codex_rows()['%1']
                self.assertEqual((row['state'], row['children']), ('children',1))
                with grandchild.open('a') as f:
                    f.write(json.dumps(event('task_complete'))+'\n')
                self.assertEqual(observer.codex_rows()['%1']['state'], 'ready')
                with sqlite3.connect(Path(tmp) / 'goals_1.sqlite') as db:
                    db.execute('create table thread_goals (thread_id,status)')
                    db.execute("insert into thread_goals values ('root','active')")
                self.assertEqual(observer.codex_rows()['%1']['state'], 'working')

    def test_display_text_cannot_inject_tmux_formats(self):
        self.assertNotIn('#', a.clean('#(touch /tmp/nope)\n\x1b'))
        self.assertNotIn('\x1b', a.clean('hello\x1b'))

    def test_visiting_marks_only_that_event_read_and_preserves_ready(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(a, 'STATE', Path(tmp)):
            import time
            rows = [dict(pane=pane, state='ready', token='turn-1') for pane in ['%1', '%2']]
            a.atomic(a.STATE / 'snapshot.json', dict(rows=rows, updated=time.time(), errors=[]))
            a.mark_read('%1')
            first, second = a.snapshot()['rows']
            self.assertEqual(first['state'], 'ready')
            self.assertFalse(a.needs_attention(first))
            self.assertTrue(a.needs_attention(second))
            rows[0]['token'] = 'turn-2'
            a.atomic(a.STATE / 'snapshot.json', dict(rows=rows, updated=time.time(), errors=[]))
            self.assertTrue(a.needs_attention(a.snapshot()['rows'][0]))


if __name__ == '__main__':
    unittest.main()
