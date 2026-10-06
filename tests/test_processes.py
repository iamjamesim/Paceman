import dataclasses
import json
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

from service.hub import Store
from service.omarchy import OmarchySource
from service.processes import AgentProcesses, ProcessIdentity
from service.status import DesktopStatus


# A fixture executable named codex owns a short-lived Python hook process. Only
# isolated sockets/databases are used; the user's Codex processes are untouched.
SENDER = """
import socket, sys
with socket.socket(socket.AF_UNIX) as client:
    client.settimeout(2)
    client.connect(sys.argv[1])
    client.sendall(sys.stdin.buffer.read())
    print(client.recv(4096).decode().strip(), flush=True)
"""
DRIVER = """
import fcntl, json, os, signal, subprocess, sys, termios
python, address, sender = sys.argv[1:4]
if len(sys.argv) > 4:
    fd = int(sys.argv[4])
    fcntl.ioctl(fd, termios.TIOCSCTTY, 0)
    os.close(fd)
print('READY', flush=True)
for line in sys.stdin:
    result = subprocess.run([python, '-c', sender, address], input=line,
                            text=True, capture_output=True, timeout=3)
    print(result.stdout.strip() or result.stderr.strip(), flush=True)
"""


@unittest.skipUnless(sys.platform == 'linux', 'Linux /proc and Unix peer credentials')
class ProcessTrackingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.executable = self.root / 'codex'
        shutil.copy2(Path(sys.executable).resolve(), self.executable)
        self.store = Store(self.root / 'hub.sqlite3')
        self.address = self.root / 'agent.sock'
        self.source = OmarchySource(self.store, socket_path=self.address, state_dir=self.root / 'theme', providers=("codex", "claude"))
        self.source.__enter__()
        self.addCleanup(lambda: self.source.__exit__(None, None, None))

    def line(self, process):
        ready, _, _ = select.select([process.stdout], [], [], 4)
        self.assertTrue(ready, 'Fixture process did not answer')
        value = process.stdout.readline().strip()
        self.assertTrue(value, 'Fixture process exited before answering')
        return value

    def spawn(self, terminal=None, executable=None):
        command = [str(executable or self.executable), '-c', DRIVER, sys.executable, str(self.address), SENDER]
        if terminal is not None:
            command.append(str(terminal))
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, start_new_session=True,
                                   pass_fds=() if terminal is None else (terminal,))
        def cleanup():
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=3)
        self.addCleanup(cleanup)
        self.assertEqual(self.line(process), 'READY')
        return process

    def event(self, process, event='working', session='one', turn='turn-1'):
        body = dict(command='agent-event', source='codex', session=session, turn=turn, event=event)
        process.stdin.write(json.dumps(body) + '\n')
        process.stdin.flush()
        self.assertTrue(json.loads(self.line(process))['ok'])
        return self.store.snapshot()

    def restart(self):
        self.source.__exit__(None, None, None)
        self.source = OmarchySource(self.store, socket_path=self.address, state_dir=self.root / 'theme', providers=("codex", "claude"))
        self.source.__enter__()

    def test_installed_claude_hook_runs_under_isolated_python_and_tracks_native_version_owner(self):
        versions = self.root / "home/.local/share/claude/versions"
        versions.mkdir(parents=True)
        executable = versions / "2.1.211"
        shutil.copy2(Path(sys.executable).resolve(), executable)
        self.source.processes = AgentProcesses(home=self.root / "home")
        # Use the production socket path expected by the installed hook.
        self.source.__exit__(None, None, None)
        self.address = self.root / "omarchy-watch.sock"
        self.source = OmarchySource(self.store, socket_path=self.address, state_dir=self.root,
                                   processes=self.source.processes, providers=("codex", "claude"))
        self.source.__enter__()
        hook = Path(__file__).resolve().parents[1] / "omarchy/claude_hook.py"
        driver = """
import subprocess, sys
print('READY', flush=True)
for line in sys.stdin:
    subprocess.run([sys.argv[1], '-I', sys.argv[2]], input=line, text=True, check=True, timeout=3)
    print('SENT', flush=True)
"""
        owner = subprocess.Popen([str(executable), "-c", driver, sys.executable, str(hook)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            env={**os.environ, "XDG_RUNTIME_DIR": str(self.root)}, start_new_session=True)
        def cleanup():
            owner.kill()
            owner.communicate(timeout=3)
        self.addCleanup(cleanup)
        self.assertEqual(self.line(owner), "READY")
        for event, state in (("SessionStart", "idle"), ("UserPromptSubmit", "working"), ("Stop", "finished")):
            owner.stdin.write(json.dumps(dict(hook_event_name=event, session_id="session",
                prompt_id="one", prompt="PRIVATE context", cwd="/secret/path")) + "\n")
            owner.stdin.flush()
            self.assertEqual(self.line(owner), "SENT")
            self.assertEqual(self.store.snapshot()["state"], state)
        public = json.dumps(self.store.snapshot())
        self.assertNotIn("PRIVATE", public)
        self.assertNotIn("secret", public)
        self.assertEqual(self.store.snapshot()["sessions"][0]["provider"], "claude")
        self.assertEqual(self.source.processes.identify(owner.pid, "claude").pid, owner.pid)

    def test_claude_native_hook_delivery_restart_and_owner_exit(self):
        executable = self.root / "claude"
        shutil.copy2(Path(sys.executable).resolve(), executable)
        owner = self.spawn(executable=executable)
        for hook, event in (("UserPromptSubmit", "working"), ("Stop", "completed")):
            message = dict(command="agent-event", provider="claude", session="claude",
                           turn="one", hook=hook, event=event)
            owner.stdin.write(json.dumps(message) + "\n")
            owner.stdin.flush()
            self.assertTrue(json.loads(self.line(owner))["changed"])
        self.restart()
        self.assertEqual(self.store.snapshot()["state"], "finished")
        self.assertEqual(self.store.snapshot()["sessions"][0]["provider"], "claude")
        with self.store.connect() as db:
            self.assertEqual(db.execute("SELECT pid FROM omarchy_processes").fetchone()[0], owner.pid)
        owner.kill()
        owner.wait(timeout=3)
        self.source.tick(force=True)
        self.assertEqual(self.store.snapshot()["sessions"], [])

    def test_short_lived_hook_does_not_close_its_owner_and_finished_stays_visible(self):
        owner = self.spawn()
        self.event(owner)
        value = self.event(owner, 'completed')
        self.source.tick(force=True)
        self.assertEqual(self.store.snapshot()['sessions'], value['sessions'])
        self.assertEqual(value['state'], 'finished')
        with self.store.connect() as db:
            self.assertEqual(db.execute('SELECT pid FROM omarchy_processes').fetchone()[0], owner.pid)
        status = DesktopStatus(self.root / 'status.json', self.store)
        status.publish(self.source, force=True)
        public = json.dumps(self.store.snapshot())
        self.assertNotIn('start_ticks', public)
        self.assertNotIn('boot_id', public)
        self.assertNotIn('"pid"', (self.root / 'status.json').read_text())

    def test_killed_owner_disappears_and_aggregate_change_gets_a_new_identity(self):
        first, second = self.spawn(), self.spawn()
        self.event(first, 'completed', session='one')
        before = self.event(second, 'working', session='two')
        second.kill()
        second.wait(timeout=3)
        self.source.tick(force=True)
        after = self.store.snapshot()
        self.assertEqual(after['state'], 'finished')
        self.assertEqual(len(after['sessions']), 1)
        self.assertNotEqual(after['eventID'], before['eventID'])
        self.assertGreater(after['revision'], before['revision'])
        first.kill()
        first.wait(timeout=3)
        self.source.tick(force=True)
        self.assertEqual(self.store.snapshot()['sessions'], [])

    def test_membership_only_cleanup_does_not_realert_an_unchanged_state(self):
        first, second = self.spawn(), self.spawn()
        self.event(first, 'needs-input', session='one')
        before = self.event(second, 'needs-input', session='two')
        second.kill()
        second.wait(timeout=3)
        self.source.tick(force=True)
        after = self.store.snapshot()
        self.assertEqual(len(after['sessions']), 1)
        self.assertEqual(after['eventID'], before['eventID'])
        self.assertGreater(after['revision'], before['revision'])

    def test_closing_controlling_terminal_removes_session(self):
        master, slave = pty.openpty()
        try:
            owner = self.spawn(terminal=slave)
            os.close(slave)
            slave = None
            self.event(owner, 'needs-input')
            os.close(master)
            master = None
            self.assertEqual(owner.wait(timeout=3), -signal.SIGHUP)
            self.source.tick(force=True)
            self.assertEqual(self.store.snapshot()['state'], 'idle')
            self.assertEqual(self.store.snapshot()['sessions'], [])
        finally:
            for fd in (master, slave):
                if fd is not None:
                    os.close(fd)

    def test_detached_process_binding_survives_completion_expiry_and_restart(self):
        owner = self.spawn()
        before = self.event(owner, 'completed')
        self.assertEqual(os.getsid(owner.pid), owner.pid)
        with self.store.connect() as db:
            db.execute('UPDATE omarchy_sessions SET updated=0')
        self.source.tick(force=True)
        expired = self.store.snapshot()
        self.assertEqual(expired['state'], 'idle')
        self.assertEqual(expired['sessions'], [])
        self.assertNotEqual(expired['eventID'], before['eventID'])
        self.restart()
        after = self.store.snapshot()
        self.assertEqual(after['state'], 'idle')
        self.assertEqual(after['sessions'], [])
        self.assertEqual(after['eventID'], expired['eventID'])
        with self.store.connect() as db:
            self.assertEqual(db.execute('SELECT pid FROM omarchy_processes').fetchone()[0], owner.pid)
        resumed = self.event(owner, 'working', turn='turn-2')
        self.assertEqual(resumed['state'], 'working')
        self.assertEqual(resumed['sessions'][0]['id'], before['sessions'][0]['id'])

    def test_restart_reconciles_process_that_exited_while_source_was_down(self):
        owner = self.spawn()
        self.event(owner)
        self.source.__exit__(None, None, None)
        self.source.thread = None
        owner.kill()
        owner.wait(timeout=3)
        self.source = OmarchySource(self.store, socket_path=self.address, state_dir=self.root / 'theme', providers=("codex", "claude"))
        self.source.__enter__()
        self.assertEqual(self.store.snapshot()['sessions'], [])

    def test_pid_reuse_and_boot_changes_cannot_preserve_a_session(self):
        owner = self.spawn()
        self.event(owner)
        identity = self.source.processes.identify(owner.pid)
        self.assertIsNotNone(identity)
        self.assertFalse(self.source.processes.is_alive(dataclasses.replace(identity, start_ticks='0')))
        self.assertFalse(self.source.processes.is_alive(dataclasses.replace(identity, boot_id='other-boot')))
        with self.store.connect() as db:
            db.execute("UPDATE omarchy_processes SET start_ticks='0'")
        self.source.tick(force=True)
        self.assertEqual(self.store.snapshot()['sessions'], [])

    def test_resuming_another_conversation_does_not_double_count_the_process(self):
        owner = self.spawn()
        first = self.event(owner, session='one')
        second = self.event(owner, session='two')
        self.assertEqual(len(second['sessions']), 1)
        self.assertNotEqual(first['sessions'][0]['id'], second['sessions'][0]['id'])
        delayed = self.event(owner, 'completed', session='one')
        self.assertEqual(delayed['sessions'], second['sessions'])
        resumed = self.event(owner, session='one', turn='turn-2')
        self.assertEqual(resumed['sessions'][0]['id'], first['sessions'][0]['id'])
        self.assertEqual(len(resumed['sessions']), 1)

    def test_session_end_removes_session_and_late_hooks_cannot_reopen_same_turn(self):
        owner = self.spawn()
        self.event(owner)
        self.event(owner, 'ended', turn='')
        self.assertEqual(self.store.snapshot()['sessions'], [])
        self.event(owner, 'completed')
        self.assertEqual(self.store.snapshot()['sessions'], [])

    def test_live_owner_cannot_be_replaced_by_another_process(self):
        first, second = self.spawn(), self.spawn()
        before = self.event(first)
        after = self.event(second, 'needs-input')
        self.assertEqual(after['sessions'], before['sessions'])

    def test_closed_conversation_can_resume_in_another_live_process(self):
        first, second = self.spawn(), self.spawn()
        initial = self.event(first, session='one')
        self.event(first, session='two')
        resumed = self.event(second, session='one', turn='turn-2')
        self.assertEqual(len(resumed['sessions']), 2)
        self.assertIn(initial['sessions'][0]['id'], [row['id'] for row in resumed['sessions']])

    def test_closed_tombstones_expire_without_removing_the_open_conversation(self):
        owner = self.spawn()
        self.event(owner, session='one')
        self.event(owner, session='two')
        with self.store.connect() as db:
            db.execute('UPDATE omarchy_sessions SET updated=0')
        self.source.tick(force=True)
        with self.store.connect() as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM omarchy_processes').fetchone()[0], 1)
            self.assertEqual(db.execute('SELECT COUNT(*) FROM omarchy_sessions').fetchone()[0], 1)
        self.assertEqual(len(self.store.snapshot()['sessions']), 1)

    def test_claimed_owner_without_kernel_peer_identity_is_ignored(self):
        owner = self.spawn()
        body = dict(command='agent-event', source='codex', session='spoof', turn='one',
                    event='working', pid=owner.pid)
        self.assertFalse(self.source.receive(body, peer_pid=None))
        self.assertEqual(self.store.snapshot()['sessions'], [])

    def test_interrupt_preserves_open_session_until_it_is_closed(self):
        owner = self.spawn()
        self.event(owner)
        value = self.event(owner, 'interrupted')
        self.assertEqual(len(value['sessions']), 1)
        self.assertEqual(value['sessions'][0]['state'], 'idle')
        self.event(owner, 'ended', turn='')
        self.assertEqual(self.store.snapshot()['sessions'], [])

    @unittest.skipUnless(shutil.which('tmux'), 'tmux is needed for detached-terminal coverage')
    def test_detached_tmux_keeps_session_until_its_process_exits(self):
        address = self.root / 'tmux.sock'
        prefix = ['tmux', '-S', str(address), '-f', '/dev/null']
        self.addCleanup(lambda: subprocess.run(prefix + ['kill-server'], capture_output=True, timeout=3))
        script = self.root / 'tmux-driver.py'
        body = dict(command='agent-event', source='codex', session='tmux', turn='one', event='completed')
        script.write_text('import signal, subprocess, sys\n'
                          f'subprocess.run([sys.argv[1], "-c", {SENDER!r}, sys.argv[2]], '
                          f'input={json.dumps(body) + chr(10)!r}, text=True, check=True)\n'
                          'while True: signal.pause()\n')
        subprocess.run(prefix + ['new-session', '-d', '-s', 'paceman-test',
                                 str(self.executable), str(script), sys.executable, str(self.address)],
                       capture_output=True, check=True, timeout=3)
        deadline = time.monotonic() + 3
        while not self.store.snapshot()['sessions'] and time.monotonic() < deadline:
            time.sleep(.02)
        self.assertEqual(self.store.snapshot()['state'], 'finished')
        attached = subprocess.run(prefix + ['display-message', '-p', '#{session_attached}'],
                                  text=True, capture_output=True, check=True, timeout=3)
        self.assertEqual(attached.stdout.strip(), '0')
        self.restart()
        self.assertEqual(len(self.store.snapshot()['sessions']), 1)
        subprocess.run(prefix + ['kill-session', '-t', 'paceman-test'], capture_output=True, check=True, timeout=3)
        deadline = time.monotonic() + 3
        while self.store.snapshot()['sessions'] and time.monotonic() < deadline:
            self.source.tick(force=True)
            time.sleep(.02)
        self.assertEqual(self.store.snapshot()['sessions'], [])


class ProcessMetadataTests(unittest.TestCase):
    def test_ancestry_uses_executable_identity_and_handles_parenthesized_names(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            boot = root / 'sys/kernel/random/boot_id'
            boot.parent.mkdir(parents=True)
            boot.write_text('test-boot')
            def process(pid, parent, executable, state='S'):
                base = root / str(pid)
                base.mkdir(exist_ok=True)
                fields = [state, str(parent)] + ['0'] * 17 + ['12345']
                (base / 'stat').write_text(f'{pid} (odd ) name) ' + ' '.join(fields))
                (base / 'exe').unlink(missing_ok=True)
                (base / 'exe').symlink_to(executable)
            process(10, 11, '/usr/bin/python3')
            process(11, 12, '/usr/bin/sh')
            process(12, 1, '/opt/codex (deleted)')
            tracker = AgentProcesses(root)
            self.assertEqual(tracker.identify(10), ProcessIdentity(12, '12345', 'test-boot'))
            process(12, 1, '/usr/bin/python3')
            self.assertIsNone(tracker.identify(10))
            process(12, 1, '/opt/codex', state='Z')
            self.assertIsNone(tracker.identify(10))

    def test_claude_native_and_node_launcher_identity_never_matches_a_prompt_argument(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            boot = root / "sys/kernel/random/boot_id"
            boot.parent.mkdir(parents=True)
            boot.write_text("boot")
            base = root / "20"
            base.mkdir()
            (base / "stat").write_text("20 (node) " + " ".join(["S", "1"] + ["0"] * 17 + ["100"]))
            (base / "exe").symlink_to("/usr/bin/node")
            tracker = AgentProcesses(root, home=root / "home")
            script = b"/usr/lib/node_modules/@anthropic-ai/claude-code/cli.js"
            (base / "cmdline").write_bytes(b"node\0" + script + b"\0PRIVATE prompt\0")
            self.assertEqual(tracker.identify(20, "claude"), ProcessIdentity(20, "100", "boot"))
            (base / "cmdline").write_bytes(b"node\0unrelated.js\0" + script + b"\0")
            self.assertIsNone(tracker.identify(20, "claude"))
            self.assertIsNone(tracker.identify(20, "codex"))
            (base / "exe").unlink()
            (base / "exe").symlink_to(root / "home/.local/share/claude/versions/2.1.211")
            self.assertIsNotNone(tracker.identify(20, "claude"))
