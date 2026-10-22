"""Verify macOS ownership with native metadata and an isolated agent fixture."""
import ctypes
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock

from service.hub import Store
from service.macos import MacSource
from service.macos_processes import MacAgentProcesses
from service.processes import ProcessIdentity


class MacIdentityTests(unittest.TestCase):
    def processes(self):
        processes = MacAgentProcesses.__new__(MacAgentProcesses)
        processes.boot_id = 'boot'
        processes._read = Mock(side_effect=lambda pid: {
            200: (100, 'hook-start', '/usr/bin/python3'),
            100: (1, 'agent-start', '/opt/claude')}.get(pid))
        return processes

    def test_peer_ancestry_and_exact_identity_are_required(self):
        processes = self.processes()
        owner = processes.identify(200)
        self.assertEqual(owner, ProcessIdentity(100, 'agent-start', 'boot'))
        self.assertTrue(processes.is_alive(owner))
        self.assertFalse(processes.is_alive(ProcessIdentity(100, 'reused', 'boot')))
        self.assertFalse(processes.is_alive(ProcessIdentity(100, 'agent-start', 'other-boot')))
        self.assertIsNone(processes.identify(300))
        processes._read.side_effect = [
            (100, 'original-hook', '/usr/bin/python3'),
            (100, 'original-hook', '/usr/bin/python3'),
            (1, 'agent-start', '/opt/claude'),
            (100, 'reused-hook', '/usr/bin/python3')]
        self.assertIsNone(processes.identify(200), 'The sending PID changed during ancestry inspection')

    def test_only_verified_node_launcher_matches(self):
        processes = self.processes()
        processes._node_launcher = Mock(return_value='/opt/node_modules/@anthropic-ai/claude-code/cli.js')
        self.assertTrue(processes._matches(100, '/opt/node', 'claude'))
        processes._node_launcher.return_value = '/opt/another-tool/cli.js'
        self.assertFalse(processes._matches(100, '/opt/node', 'claude'))
        processes._node_launcher.return_value = 'node_modules/@anthropic-ai/claude-code/cli.js'
        self.assertFalse(processes._matches(100, '/opt/node', 'claude'))
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            script = root / 'node_modules/@anthropic-ai/claude-code/cli.js'
            script.parent.mkdir(parents=True)
            script.touch()
            launcher = root / 'claude'
            launcher.symlink_to(script)
            processes._node_launcher.return_value = str(launcher)
            self.assertTrue(processes._matches(100, '/opt/node', 'claude'), 'npm launcher symlinks retain ownership')

    def test_procargs_parser_returns_only_launcher_and_checks_argc(self):
        processes = self.processes()
        processes.libc = Mock()
        launcher = '/opt/node_modules/@anthropic-ai/claude-code/cli.js'
        raw = (3).to_bytes(4, sys.byteorder) + b'/opt/node\0\0node\0' + launcher.encode() + b'\0PRIVATE ARGUMENT\0SECRET=VALUE\0'
        def sysctl(_mib, _length, buffer, size, *_):
            ctypes.cast(size, ctypes.POINTER(ctypes.c_size_t))[0] = len(raw)
            if buffer is not None:
                ctypes.memmove(buffer, raw, len(raw))
            return 0
        processes.libc.sysctl.side_effect = sysctl
        self.assertEqual(processes._node_launcher(100), launcher)
        raw = (1).to_bytes(4, sys.byteorder) + b'/opt/node\0\0node\0SECRET=VALUE\0'
        self.assertIsNone(processes._node_launcher(100))


@unittest.skipUnless(sys.platform == 'darwin', 'macOS libproc and LOCAL_PEERPID')
class MacNativeProcessTests(unittest.TestCase):
    def test_real_peer_owner_survives_source_restart_and_clears_on_process_exit(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fixture = root / 'owner.c'
            executable = root / 'claude'
            fixture.write_text('''#include <unistd.h>
#include <sys/wait.h>
int main(int argc, char **argv) {
    pid_t child = fork();
    if (child == 0) { execv(argv[1], argv + 1); _exit(127); }
    if (child < 0) return 1;
    close(0);
    int status; waitpid(child, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
''')
            subprocess.run(['xcrun', 'clang', str(fixture), '-o', str(executable)], check=True,
                           capture_output=True, timeout=30)
            hook = Path(__file__).resolve().parents[1] / 'macos/claude_hook.py'
            driver = '''import subprocess, sys
print('READY', flush=True)
for line in sys.stdin:
    subprocess.run([sys.executable, '-I', sys.argv[1]], input=line, text=True, check=True, timeout=4)
    print('SENT', flush=True)
'''
            owner = subprocess.Popen([str(executable), sys.executable, '-c', driver, str(hook)],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                env={**os.environ, 'PACEMAN_HOOK_SOCKET': str(root / 'hook.sock'),
                     'CLAUDE_CODE_BRIDGE_SESSION_ID': 'session_fixture'}, start_new_session=True)
            store, clock = Store(root / 'hub.sqlite3'), [100.0]
            source = None
            def start():
                return MacSource(store, socket_path=root / 'hook.sock', allowance_reader=lambda: [],
                    turn_status_reader=lambda _: {}, turn_metadata_reader=lambda _: {},
                    title_reader=lambda _: {}, monotonic=lambda: clock[0]).__enter__()
            def line():
                self.assertTrue(select.select([owner.stdout], [], [], 5)[0], 'Fixture did not reply')
                return owner.stdout.readline().strip()
            def emit(event, **extra):
                owner.stdin.write(json.dumps(dict(hook_event_name=event, session_id='fixture',
                    prompt_id='turn', **extra)) + '\n')
                owner.stdin.flush()
                self.assertEqual(line(), 'SENT')
            try:
                source = start()
                self.assertEqual(line(), 'READY')
                emit('UserPromptSubmit')
                self.assertEqual(store.snapshot()['state'], 'working')
                binding = next(iter(source.claude_owners.values()))
                self.assertEqual(binding.pid, owner.pid)
                self.assertTrue(source.processes.is_alive(binding))
                emit('PermissionRequest', tool_name='Bash')
                clock[0] += 6
                source.tick()
                self.assertEqual(store.snapshot()['state'], 'needs_input')
                source.__exit__(None, None, None)
                source = start()
                self.assertEqual(store.snapshot()['state'], 'needs_input')
                self.assertEqual(next(iter(source.claude_owners.values())), binding)
                owner.stdin.close()
                owner.stdin = None
                owner.communicate(timeout=5)
                self.assertEqual(owner.returncode, 0)
                clock[0] += 2
                source.tick()
                self.assertEqual(store.snapshot()['state'], 'idle')
                self.assertFalse(source.native_claude_sessions())
            finally:
                if source is not None:
                    source.__exit__(None, None, None)
                if owner.poll() is None:
                    os.killpg(owner.pid, signal.SIGTERM)
                owner.communicate(timeout=5)
