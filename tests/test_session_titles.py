import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch
from uuid import uuid4

from service.hub import Store
from service.macos import MacSource
from service.push import live_notification, notification_copy
from service.session_titles import (SessionTitles, normalized_title, read_claude_titles,
                                    read_codex_titles, TITLE_REFRESH_INTERVAL)


class TitleTests(unittest.TestCase):
    def test_titles_are_bounded_and_empty_titles_have_no_fallback_to_content(self):
        self.assertEqual(normalized_title("  Fix\n  scrolling\x00 "), "Fix scrolling")
        self.assertIsNone(normalized_title(" \n\x00"))
        self.assertIsNone(normalized_title({"preview": "secret"}))
        self.assertEqual(len(normalized_title("é" * 100)), 80)

    def test_claude_reads_only_explicit_title_records_and_latest_custom_title_wins(self):
        with tempfile.TemporaryDirectory() as temporary:
            projects = Path(temporary)
            folder = projects / "project"
            folder.mkdir()
            session = str(uuid4())
            path = folder / (session + ".jsonl")
            rows = [
                {"type": "user", "message": {"content": "private", "customTitle": "private"}},
                {"type": "summary", "summary": "private"},
                {"type": "last-prompt", "lastPrompt": "private"},
                {"type": "ai-title", "aiTitle": "Generated title", "sessionId": session},
                {"type": "custom-title", "customTitle": "First title", "sessionId": session},
                {"type": "custom-title", "customTitle": "Renamed title", "sessionId": session},
                {"type": "custom-title", "customTitle": "Other session", "sessionId": str(uuid4())},
            ]
            path.write_text("\n".join(json.dumps(row) for row in rows) + "\n")
            self.assertEqual(read_claude_titles([session, "../../escape"], projects=projects), {session: "Renamed title"})
            path.write_text(json.dumps(rows[3]) + "\n")
            self.assertEqual(read_claude_titles([session], projects=projects), {session: "Generated title"})
            path.write_text("\n".join(json.dumps(row) for row in rows[:3]) + "\n")
            self.assertEqual(read_claude_titles([session], projects=projects), {})

    def test_claude_bounded_head_and_tail_ignore_truncated_messages(self):
        with tempfile.TemporaryDirectory() as temporary:
            projects = Path(temporary); folder = projects / "project"; folder.mkdir()
            session = str(uuid4()); path = folder / (session + ".jsonl")
            path.write_text(json.dumps({"type":"custom-title", "customTitle":"Head title"}) + "\n" +
                json.dumps({"type":"user", "message":{"content":"x"*200000}}) + "\n" +
                json.dumps({"type":"custom-title", "customTitle":"Tail title"}) + "\n")
            self.assertEqual(read_claude_titles([session], projects=projects), {session: "Tail title"})

    def test_codex_uses_name_and_never_preview_or_turn_items(self):
        session = str(uuid4())
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / "codex"
            binary.write_text("#!/usr/bin/env python3\nimport json,sys\n"
                "for line in sys.stdin:\n"
                " m=json.loads(line)\n"
                " if m.get('id')==1: result={'userAgent':'test'}\n"
                " elif m.get('id')==2:\n"
                "  assert m['method']=='thread/read' and m['params']['includeTurns'] is False\n"
                "  result={'thread':{'name':'Fix scrolling','preview':'private','turns':[]}}\n"
                " else: continue\n"
                " print(json.dumps({'id':m['id'],'result':result}),flush=True)\n")
            binary.chmod(0o700)
            with patch('service.session_titles.codex_binary', return_value=str(binary)):
                self.assertEqual(read_codex_titles([session, 'invalid', session]), {session:'Fix scrolling'})
            binary.write_text(binary.read_text().replace("'name':'Fix scrolling'", "'name':None"))
            with patch('service.session_titles.codex_binary', return_value=str(binary)):
                self.assertEqual(read_codex_titles([session]), {session:None})

    def test_cache_retries_failures_refreshes_renames_and_invalidates_pending_reads(self):
        clock=[0.0]; changed=[]; results={('codex','one'):'Original'}
        cache=SessionTitles(lambda:changed.append(True), reader=lambda _:results.copy(), monotonic=lambda:clock[0])
        self.addCleanup(cache.close)
        cache.track('key','codex','one'); cache.refresh(); cache.thread.join(2)
        self.assertEqual(cache.name('key'),'Original')
        results.clear(); clock[0]+=TITLE_REFRESH_INTERVAL
        cache.refresh(); cache.thread.join(2)
        self.assertEqual(cache.name('key'),'Original')
        results[('codex','one')]='Renamed'; clock[0]+=TITLE_REFRESH_INTERVAL
        cache.refresh(); cache.thread.join(2)
        self.assertEqual(cache.name('key'),'Renamed')
        results[('codex','one')]=None; clock[0]+=TITLE_REFRESH_INTERVAL
        cache.refresh(); cache.thread.join(2)
        self.assertIsNone(cache.name('key'))
        start, release=threading.Event(), threading.Event()
        def read(_):
            start.set(); release.wait(2); return {('codex','one'):'Old read'}
        cache.reader=read; clock[0]+=TITLE_REFRESH_INTERVAL
        cache.refresh(); self.assertTrue(start.wait(2)); cache.retain([])
        cache.track('key','codex','one'); release.set(); cache.thread.join(2)
        self.assertIsNone(cache.name('key'))
        self.assertEqual(len(changed),3)

    def test_mac_title_changes_are_presentation_only_and_end_clears_lookup(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary); root.chmod(0o700); store=Store(root/'hub.sqlite3')
            clock=[10.0]; titles={('codex','one'):'Fix watch scrolling'}
            with MacSource(store, socket_path=root/'hook.sock', allowance_reader=lambda:None,
                           title_reader=lambda _:titles.copy(), monotonic=lambda:clock[0]) as source:
                event=dict(command='agent-event', session='one', turn='turn', event='working')
                source.receive(event); before=store.snapshot()
                source.titles.refresh(); source.titles.thread.join(2)
                after=store.snapshot()
                self.assertEqual(after['sessions'][0]['name'],'Fix watch scrolling')
                self.assertEqual(after['eventID'],before['eventID'])
                self.assertEqual(after['changedAt'],before['changedAt'])
                self.assertGreater(after['revision'],before['revision'])
                self.assertNotIn('Fix watch scrolling', json.dumps(live_notification(after, after['observedAt'])))
                self.assertNotIn('Fix watch scrolling', json.dumps(notification_copy(
                    {'state': after['state'], 'payload': json.dumps(after)})))
                titles[('codex','one')]='Renamed'; clock[0]+=TITLE_REFRESH_INTERVAL
                source.titles.refresh(); source.titles.thread.join(2)
                self.assertEqual(store.snapshot()['sessions'][0]['name'],'Renamed')
                source.receive(dict(event,event='ended'))
                self.assertFalse(source.titles.refs)
                self.assertFalse(source.titles.names)
                self.assertFalse(store.snapshot()['sessions'])
