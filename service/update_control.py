"""Private local update admission, owned by the preparing client's connection."""
from contextlib import contextmanager
import json
import os
import select
import socket
import socketserver
import threading
import uuid

from service.interactions import BrokerError


class _Handler(socketserver.StreamRequestHandler):
    def _reply(self, value):
        self.wfile.write(json.dumps(value).encode() + b'\n')
        self.wfile.flush()

    def handle(self):
        self.connection.settimeout(3)
        control = self.server.control
        try:
            message = self.rfile.readline(128)
            if not message.endswith(b'\n'):
                raise ValueError('Invalid update command')
            parts = message.decode('ascii').strip().split(' ')
            command = parts[0]
            token = str(uuid.UUID(parts[1])) if len(parts) == 2 else None
            if command == 'prepare' and token is not None:
                try:
                    control.prepare(self.connection, token)
                    self._reply({'ok': True})
                    # EOF (including a lost acknowledgement) relinquishes admission.
                    # Shutdown closes this connection rather than waiting on the client.
                    self.connection.settimeout(None)
                    self.rfile.read(1)
                finally:
                    control.release(self.connection)
                return
            if command == 'resume' and len(parts) <= 2:
                control.resume(token)
            elif parts != ['status']:
                raise ValueError('Invalid update command')
            self._reply({'ok': True})
        except (ValueError, BrokerError, OSError):
            try:
                self._reply({'ok': False, 'error': 'Paceman could not prepare this update. Finish active work or reopen Paceman to retry.'})
            except OSError:
                pass


class _Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


class UpdateControl:
    def __init__(self, path, store, adapter, broker):
        self.path, self.store, self.adapter, self.broker = path, store, adapter, broker
        self.lock = threading.RLock()
        self.active = None
        self.closed = False

    def prepare(self, connection, token):
        # Revalidate after acquiring the potentially delayed adapter lock. Recovery
        # changes/removes this journal before acknowledging cancellation.
        with self.adapter.lock, self.lock:
            journal = json.loads((self.path.parent / 'update-pending.json').read_text())
            if (self.closed or journal.get('schema') != 1 or journal.get('token') != token
                    or journal.get('phase') != 'admitting' or self.active is not None):
                raise ValueError('This update preparation is no longer current')
            if select.select([connection], [], [], 0)[0]:
                raise ValueError('The preparing client disconnected or sent unexpected input')
            if (getattr(self.adapter, 'recovering_sessions', None)
                    or getattr(self.adapter, 'pending_turn_events', None)
                    or any(s.get('state') in ('working', 'needs_input')
                           for s in self.store.snapshot().get('sessions', []))):
                raise ValueError('Finish active work before updating')
            self.broker.prepare_update()
            self.active = connection, token

    def release(self, connection):
        with self.lock:
            if self.active is not None and self.active[0] is connection:
                self.active = None
                self.broker.resume_after_update()

    def resume(self, token):
        with self.lock:
            if self.active is not None:
                connection, owner = self.active
                if token != owner:
                    raise ValueError('Another update owns admission')
                self.release(connection)
                try:
                    connection.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass

    def __enter__(self):
        # hub owns the source lock. Only remove a stale socket, never a file/link.
        if self.path.exists() or self.path.is_symlink():
            import stat
            if not stat.S_ISSOCK(self.path.lstat().st_mode):
                raise ValueError('Update socket is not a socket')
            self.path.unlink()
        self.server = _Server(str(self.path), _Handler)
        os.chmod(self.path, 0o600)
        self.inode = self.path.stat().st_ino
        self.server.control = self
        self.thread = threading.Thread(target=self.server.serve_forever,
                                       kwargs={'poll_interval': .05}, daemon=True)
        self.thread.start()
        return self

    def __exit__(self, *_):
        with self.lock:
            self.closed = True
            if self.active is not None:
                self.resume(self.active[1])
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=4)
        if self.path.exists() and self.path.lstat().st_ino == self.inode:
            self.path.unlink()


def _acknowledge(connection, command, token):
    line = command + (' ' + token if token else '') + '\n'
    connection.sendall(line.encode())
    with connection.makefile('rb') as stream:
        value = json.loads(stream.readline(1024))
    if value.get('ok') is not True:
        raise ValueError(value.get('error', 'Paceman cannot update yet.'))


@contextmanager
def admission(path, token, *, timeout=5):
    """Keep admission closed only while this client is preparing/stopping workers."""
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(timeout)
        connection.connect(str(path))
        _acknowledge(connection, 'prepare', token)
        yield


def request(path, command, *, token=None):
    if command not in ('resume', 'status'):
        raise ValueError('Prepare requires a scoped admission connection')
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(5)
        connection.connect(str(path))
        _acknowledge(connection, command, token)
