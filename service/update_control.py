"""Private local update admission. Never answers or interrupts the native agent."""
import json
import os
import socket
import socketserver
import threading

from service.interactions import BrokerError


class _Handler(socketserver.StreamRequestHandler):
    def handle(self):
        self.connection.settimeout(3)
        try:
            message = self.rfile.readline(128)
            if message not in (b'prepare\n', b'resume\n', b'status\n'):
                raise ValueError('Invalid update command')
            control = self.server.control
            if message == b'prepare\n':
                # The adapter's hook/native writers take this same lock.
                with control.adapter.lock:
                    if (getattr(control.adapter, 'recovering_sessions', None)
                            or getattr(control.adapter, 'pending_turn_events', None)
                            or any(s.get('state') in ('working', 'needs_input')
                                   for s in control.store.snapshot().get('sessions', []))):
                        raise ValueError('Finish active work and pending questions before updating Paceman.')
                    control.broker.prepare_update()
            elif message == b'resume\n':
                control.broker.resume_after_update()
            result = {'ok': True}
        except (ValueError, BrokerError, TimeoutError):
            result = {'ok': False, 'error': 'Finish active work and pending responses before updating Paceman.'}
        try:
            self.wfile.write(json.dumps(result).encode() + b'\n')
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass


class UpdateControl:
    def __init__(self, path, store, adapter, broker):
        self.path, self.store, self.adapter, self.broker = path, store, adapter, broker

    def __enter__(self):
        # hub owns the source lock. Only remove a stale socket, never a file/link.
        if self.path.exists() or self.path.is_symlink():
            import stat
            if not stat.S_ISSOCK(self.path.lstat().st_mode):
                raise ValueError('Update socket is not a socket')
            self.path.unlink()
        self.server = socketserver.UnixStreamServer(str(self.path), _Handler)
        os.chmod(self.path, 0o600)
        self.inode = self.path.stat().st_ino
        self.server.control = self
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=4)
        if self.path.exists() and self.path.lstat().st_ino == self.inode:
            self.path.unlink()


def request(path, command):
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(5)
        connection.connect(str(path))
        connection.sendall(command.encode() + b'\n')
        with connection.makefile('rb') as stream:
            value = json.loads(stream.readline(1024))
        if value.get('ok') is not True:
            raise ValueError(value.get('error', 'Paceman cannot update yet.'))
