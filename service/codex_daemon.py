"""Rejoin live native CLI requests on Codex's existing local app-server.

Only hook-observed active threads already loaded by that server are joined, with
no configuration overrides. No daemon startup, new turns, or credential access.
"""
from copy import deepcopy
import os
from pathlib import Path
import threading
import time
import uuid

from service.codex_desktop import owned_socket
from service.codex_requests import decode_request, session_key
from service.codex_attention import classify_request
from service.native_attention import PendingDecisions
from service.diagnostics import fingerprint
from service.interactions import BrokerError
from service.native_websocket import UnixWebSocket


def native_socket(path):
    # Codex publishes a private user-owned symlink to its per-user runtime
    # socket. Validate both ends, then connect to the resolved owned socket.
    if path.is_symlink():
        link, parent = path.lstat(), path.parent.stat()
        if link.st_uid != os.getuid() or parent.st_uid != os.getuid() or parent.st_mode & 0o077:
            raise OSError('unowned native socket link')
        path = path.resolve(strict=True)
    if not owned_socket(path):
        raise OSError('unowned native socket')
    return path


class DaemonRequests:
    def __init__(self, broker, sessions, *, attention=lambda *_: None, path=None, connect=UnixWebSocket):
        self.broker, self.sessions, self.attention = broker, sessions, attention
        self.path = path or Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex'))) / 'app-server-control/app-server-control.sock'
        self.connect = connect
        self.stop = threading.Event()
        self.lock = threading.RLock()
        self.connection = None
        self.calls, self.joined, self.requests, self.pending, self.items = {}, {}, {}, {}, {}
        self.retired = set()
        self.ready = set()
        self.native_waiting = {}

    def __enter__(self):
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.stop.set()
        with self.lock:
            connection = self.connection
        if connection:
            connection.close()
        self.thread.join(timeout=3)
        self._reset()

    def owns(self, session):
        with self.lock:
            return session in self.joined

    def _call(self, method, params, connection):
        rid, done, result = 'paceman-' + str(uuid.uuid4()), threading.Event(), []
        with self.lock:
            if self.connection is not connection or self.stop.is_set():
                raise OSError('native channel released')
            self.calls[rid] = done, result
        try:
            connection.send(dict(id=rid, method=method, params=params))
            if not done.wait(5) or not result or 'error' in result[0]:
                raise OSError('native request unavailable')
            return result[0]['result']
        finally:
            with self.lock:
                self.calls.pop(rid, None)

    def _forget(self, session):
        for key in [key for key in self.requests if key[0] == session]:
            self._resolve(key)
        self.joined.pop(session, None)
        self.items.pop(session, None)
        self.ready.discard(session)
        self.native_waiting.pop(session, None)
        self.attention(session, None)

    def _set_turn(self, session, turn):
        if self.joined[session] == turn:
            return False
        self.joined[session] = turn
        self.items[session] = {}
        self.native_waiting.pop(session, None)
        for key, raw in list(self.requests.items()):
            if key[0] == session and raw['params'].get('turnId') not in (None, '', turn):
                self._resolve(key)
        return True

    def _reset(self):
        with self.lock:
            for session in list(self.joined):
                self._forget(session)
            for done, _ in self.calls.values():
                done.set()
            self.calls.clear()
            self.connection = None

    def _run(self):
        delay = 1
        while not self.stop.is_set():
            connection = None
            try:
                # A native turn proves a native client has initialized first.
                # Never win the server's process-wide client-originator race.
                if not self.sessions():
                    raise OSError('no active native daemon session')
                connection = self.connect(native_socket(self.path))
                with self.lock:
                    self.connection = connection
                reader = threading.Thread(target=self._read, args=(connection,), daemon=True)
                reader.start()
                self._call('initialize', dict(clientInfo=dict(name='paceman', title='Paceman', version='0.1'),
                    capabilities=dict(experimentalApi=True)), connection)
                connection.send(dict(method='initialized'))
                while not self.stop.is_set() and reader.is_alive():
                    with self.lock:
                        current = dict(self.sessions())
                        if not current:
                            break
                        leaving = [s for s in self.joined if s not in current]
                        for session in self.joined.keys() & current.keys():
                            if self._set_turn(session, current[session]):
                                self._sync(session)
                    for session in leaving:
                        with self.lock:
                            self._forget(session)
                        self._call('thread/unsubscribe', dict(threadId=session), connection)
                    with self.lock:
                        candidates = current.keys() - self.joined.keys()
                    if candidates:
                        loaded, cursor = set(), None
                        for _ in range(8):
                            page = self._call('thread/loaded/list', dict(limit=100, **({'cursor': cursor} if cursor else {})), connection)
                            loaded.update(page['data'])
                            cursor = page.get('nextCursor')
                            if not cursor:
                                break
                        for session in candidates & loaded:
                            summary = self._call('thread/read', dict(threadId=session), connection)['thread']
                            if summary.get('status', {}).get('type') != 'active' or self.sessions().get(session) != current[session]:
                                continue
                            with self.lock:
                                self.joined[session] = current[session]
                                self.items[session] = {}
                            try:
                                result = self._call('thread/resume', dict(threadId=session, excludeTurns=True,
                                    initialTurnsPage=dict(limit=1, sortDirection='desc', itemsView='full')), connection)
                            except OSError:
                                with self.lock:
                                    self._forget(session)
                                continue
                            if self.sessions().get(session) != current[session]:
                                with self.lock:
                                    self._forget(session)
                                self._call('thread/unsubscribe', dict(threadId=session), connection)
                                continue
                            with self.lock:
                                for turn in (result.get('initialTurnsPage') or {}).get('data', []):
                                    if turn.get('id') == current[session]:
                                        for item in turn.get('items', []):
                                            if item.get('id') not in self.items[session]:
                                                self._item(session, item)
                                self.ready.add(session)
                                self._sync(session)
                    delay = 1
                    self.stop.wait(2)
            except (OSError, EOFError, ValueError, KeyError, TypeError, AttributeError, RecursionError):
                pass
            finally:
                if connection:
                    connection.close()
                self._reset()
            self.stop.wait(delay)
            delay = min(30, delay * 2)

    def _read(self, connection):
        try:
            while not self.stop.is_set():
                value = connection.receive()
                with self.lock:
                    if self.connection is not connection:
                        return
                    self.receive(value)
        except (OSError, EOFError, ValueError, KeyError, TypeError, AttributeError, RecursionError):
            connection.close()
            with self.lock:
                if self.connection is connection:
                    self._reset()

    def _item(self, session, item):
        if item.get('type') in ('fileChange', 'commandExecution') and isinstance(item.get('id'), str):
            if len(self.items[session]) >= 64 and item['id'] not in self.items[session]:
                raise ValueError('too many native review items')
            fields = ('id', 'type', 'changes') if item['type'] == 'fileChange' else ('id', 'type', 'command', 'processId')
            self.items[session][item['id']] = {k: deepcopy(item[k]) for k in fields if k in item}

    def _resolve(self, key):
        self.requests.pop(key, None)
        self.retired.discard(key)
        pending = self.pending.pop(key, None)
        if pending:
            self.broker.withdraw(pending[0])

    def receive(self, message):
        method, rid = message.get('method'), message.get('id')
        if method is None:
            if rid in self.calls:
                done, box = self.calls[rid]
                box.append(message)
                done.set()
            return
        params = message.get('params', {})
        session = params.get('threadId')
        if session not in self.joined:
            return
        current = self.sessions()
        if session not in current:
            self._forget(session)
            return
        turn = current[session]
        # The native stream can deliver the next turn's first request before
        # the subscription poll sees its hook. Reconcile before filtering it.
        changed = self._set_turn(session, turn)
        if 'id' in message:
            if (type(rid) not in (str, int) or params.get('turnId') not in (None, '', turn)
                    or classify_request(session, message) != 'human'):
                if self.broker.diagnostics is not None:
                    self.broker.diagnostics.record('native_requests_observed', provider='codex',
                        sessionFingerprint=fingerprint(session_key(session)),
                        **{classify_request(session, message) + 'Count': 1})
                if changed:
                    self._sync(session)
                return
            if len(self.requests) >= 64:
                raise ValueError('too many native requests')
            key = session, type(rid).__name__, str(rid)
            self.requests[key] = deepcopy(message)
        elif method == 'serverRequest/resolved':
            rid = params.get('requestId')
            self._resolve((session, type(rid).__name__, str(rid)))
        elif method in ('thread/closed', 'thread/archived', 'thread/deleted'):
            self._forget(session)
            return
        elif method == 'turn/completed' and params.get('turn', {}).get('id') == turn:
            pass  # Outcome does not resolve pending native decisions.
        elif method == 'thread/status/changed':
            status = params.get('status', {})
            self.native_waiting[session] = bool(set(status.get('activeFlags', [])) & {'waitingOnApproval', 'waitingOnUserInput'})
        elif method in ('item/started', 'item/completed') and params.get('turnId') == turn:
            self._item(session, params.get('item', {}))
        elif method == 'item/fileChange/patchUpdated' and params.get('turnId') == turn:
            self._item(session, dict(id=params.get('itemId'), type='fileChange', changes=params['changes']))
        self._sync(session)

    def _sync(self, session):
        if session not in self.ready:
            return
        for key, raw in list(self.requests.items()):
            if key[0] != session:
                continue
            decoded = decode_request(session, raw, self.items.get(session, {}).values())
            previous = self.pending.get(key)
            if previous and (previous[1] != raw or decoded is None or previous[2] != decoded[0]):
                self.broker.withdraw(self.pending.pop(key)[0])
                self.retired.add(key)
            if decoded is None or key in self.pending or key in self.retired:
                continue
            public, encode = decoded
            try:
                handle = self.broker.publish_live(public)
            except BrokerError:
                continue
            self.pending[key] = handle, deepcopy(raw), deepcopy(public)
            threading.Thread(target=self._answer, args=(key, handle, encode, self.connection), daemon=True).start()
        pending = {(raw['params'].get('turnId') or None, key[1], key[2])
                   for key, raw in self.requests.items() if key[0] == session}
        if self.native_waiting.get(session, False):
            pending.add((self.joined[session], 'status', 'waitingOnHuman'))
        self.attention(session, PendingDecisions('daemon-' + str(id(self.connection)), frozenset(pending),
            known_turns=frozenset({self.joined[session]})))

    def _answer(self, key, handle, encode, connection):
        handle.ready.wait()
        with self.lock:
            entry = self.pending.get(key)
            if (self.stop.is_set() or self.connection is not connection or not entry or entry[0] is not handle
                    or self.sessions().get(key[0]) != self.joined.get(key[0])):
                return
            self.retired.add(key)
            encoded = encode(handle.response or {'action': 'release'})
            if encoded is None:
                self.broker.withdraw(handle)
                return
            _, payload = encoded
            result = payload.get('response', payload)
            frame = dict(id=entry[1]['id'], result=result)
            try:
                connection.send(frame)
            except (OSError, ValueError):
                # Rejoin and replay pending requests for explicit user review.
                # Never retry this answer on a replacement connection.
                connection.close()
