"""Follow Claude's existing Remote Control owner, without permission hooks.

Only native control traffic is requested. We never create/resume a conversation,
register hooks/dialog handlers, refresh provider credentials, or change modes.
"""
from collections import OrderedDict
from copy import deepcopy
import hashlib
import json
import re
import subprocess
import threading
import time
import urllib.error
import urllib.request
import uuid

from service.claude_hooks import REMOTE_IDENTIFIER
from service.claude_requests import decode_request
from service.claude_attention import classify_request
from service.native_attention import PendingDecisions
from service.diagnostics import fingerprint
from service.interactions import BrokerError

MAX_FRAME = 16 * 1024 * 1024
MAX_PENDING = 64


def native_token():
    """Read the native login on demand; leave refresh/rotation to Claude."""
    result = subprocess.run(['/usr/bin/security', 'find-generic-password', '-s',
                             'Claude Code-credentials', '-w'], stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, timeout=5, check=True)
    if len(result.stdout) > 65536:
        raise ValueError('invalid native login')
    value = json.loads(result.stdout).get('claudeAiOauth', {})
    token = value.get('accessToken')
    if (not isinstance(token, str) or not token or '\r' in token or '\n' in token
            or 'user:sessions:claude_code' not in value.get('scopes', [])):
        raise ValueError('native session login unavailable')
    return token


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_args, **_kwargs):
        raise OSError('native endpoint redirected')


class NativeHTTP:
    def __init__(self, remote, token_reader=native_token):
        if not isinstance(remote, str) or not REMOTE_IDENTIFIER.fullmatch(remote):
            raise ValueError('invalid native session')
        self.remote, self.token_reader = remote, token_reader
        self.url = 'https://api.anthropic.com/v1/code/sessions/' + remote + '/events'
        self.opener = urllib.request.build_opener(NoRedirect())
        self.token = None
        self.lock = threading.Lock()

    def _open(self, url, *, body=None, stream=False):
        with self.lock:
            if self.token is None:
                self.token = self.token_reader()
            token = self.token
        headers = {'Authorization': 'Bearer ' + token, 'User-Agent': 'Paceman/0.1',
                   'anthropic-version': '2023-06-01',
                   'Accept': 'text/event-stream' if stream else 'application/json'}
        if body is not None:
            headers['Content-Type'] = 'application/json'
        request = urllib.request.Request(url, data=body, headers=headers)
        try:
            return self.opener.open(request, timeout=25 if stream else 10)
        except urllib.error.HTTPError as error:
            if error.code == 401:
                with self.lock:
                    self.token = None
            raise OSError('native session request unavailable') from None

    def connect(self):
        return self._open(self.url + '/stream?control_only=1', stream=True)

    def send(self, frame):
        # This adapter is a responder/observer. It has no agent-driving path.
        if not (frame.get('type') == 'control_response' or
                frame.get('type') == 'control_request' and frame.get('request') == {'subtype': 'initialize'}):
            raise ValueError('not a response or read-only checkpoint')
        frame = dict(frame, session_id=self.remote, uuid=str(uuid.uuid4()))
        body = json.dumps({'events': [{'payload': frame}]}, ensure_ascii=False, allow_nan=False).encode()
        if len(body) > MAX_FRAME:
            raise ValueError('oversized native response')
        # Never retry an uncertain answer. HTTP acceptance is not consumption.
        with self._open(self.url, body=body) as response:
            data = response.read(65537)
            if len(data) > 65536:
                raise ValueError('oversized native receipt')
            value = json.loads(data)
            if not isinstance(value.get('results'), list) or len(value['results']) != 1:
                raise ValueError('invalid native receipt')


def events(stream, check=lambda: None):
    """Bounded SSE decoding; unknown events reach the state reducer unchanged."""
    event, lines, size = '', [], 0
    while True:
        check()
        raw = stream.readline(MAX_FRAME + 1)
        if not raw:
            raise EOFError()
        size += len(raw)
        if size > MAX_FRAME:
            raise ValueError('oversized native event')
        line = raw.decode('utf-8').rstrip('\r\n')
        if not line:
            if lines:
                value = json.loads('\n'.join(lines))
                if not isinstance(value, dict):
                    raise ValueError('invalid native event')
                yield event, value
            event, lines, size = '', [], 0
        elif line.startswith('event:'):
            event = line[6:].lstrip(' ')
        elif line.startswith('data:'):
            lines.append(line[5:].lstrip(' '))


class NativeRequests:
    """Observed native requests; checkpoints replace the current request set."""
    def __init__(self, broker, session, remote, send, attention=lambda _value: None,
                 resolved=lambda _tools, _pending: None):
        self.broker, self.session, self.remote = broker, session, remote
        self.send, self.attention = send, attention
        self.resolution = resolved
        self.lock = threading.RLock()
        self.native, self.pending = {}, {}
        self.observed, self.completed = {}, {}
        self.resolved = OrderedDict()
        self.retired = set()
        self.connected = False
        self.closed = False
        self.initializing = None
        self.last_sequence = 0
        self.confirming = set()
        self.checkpoint_confirming = set()
        self.checkpoint_started = 0
        self.next_checkpoint = 0
        self.checkpoint_failed = False
        self.observed_counts = None
        self.session_waiting = False

    def initialize(self):
        with self.lock:
            if self.closed:
                raise OSError('native session released')
            if self.initializing:
                return
            self.initializing = str(uuid.uuid4())
            self.checkpoint_started = time.monotonic()
            self.checkpoint_confirming = set(self.confirming)
            self.checkpoint_failed = False
            frame = dict(type='control_request', request_id=self.initializing, request={'subtype': 'initialize'})
        self.send(frame)

    def check(self):
        with self.lock:
            if self.closed or self.checkpoint_failed:
                raise OSError('native session unavailable')
            if self.initializing and time.monotonic() - self.checkpoint_started >= 30:
                raise OSError('native checkpoint unavailable')

    def refresh(self):
        """Confirm consumption; remote response echoes alone are not decisions."""
        with self.lock:
            if (self.closed or not self.connected or self.initializing or not (self.confirming or self.session_waiting)
                    or time.monotonic() < self.next_checkpoint):
                return
            self.next_checkpoint = time.monotonic() + 2
        def run():
            try:
                self.initialize()
            except (OSError, ValueError, subprocess.SubprocessError):
                with self.lock:
                    self.checkpoint_failed = True
        threading.Thread(target=run, daemon=True).start()

    def close(self):
        with self.lock:
            self.closed = True
            self.disconnect()

    def disconnect(self):
        with self.lock:
            self.connected = False
            self.initializing = None
            self.last_sequence = 0
            for handle, _, _ in self.pending.values():
                self.broker.withdraw(handle)
            self.pending.clear()
            self.native.clear()
            self.attention(None)  # Losing the channel never resolves the agent.

    def _resolve(self, rid):
        self.resolved[rid] = True
        while len(self.resolved) > 1024:
            self.resolved.popitem(last=False)
        self.native.pop(rid, None)
        self.confirming.discard(rid)
        self.retired.discard(rid)
        if rid in self.observed:
            self.completed[rid] = self.observed.pop(rid)
        entry = self.pending.pop(rid, None)
        if entry:
            self.broker.withdraw(entry[0])

    @staticmethod
    def _request(frame):
        if (not isinstance(frame, dict) or frame.get('type') != 'control_request'
                or not isinstance(frame.get('request_id'), str) or not 0 < len(frame['request_id']) <= 160
                or not isinstance(frame.get('request'), dict)):
            raise ValueError('invalid native request')
        return frame['request_id']

    def receive(self, event, envelope):
        with self.lock:
            if self.closed:
                return
            if event == 'catch_up_truncated' and self.initializing and not self.connected:
                return  # The in-flight owner checkpoint replaces incomplete history.
            if event in ('catch_up_truncated', 'error'):
                raise ValueError('native stream gap')
            if event == 'session_update':
                if envelope.get('connection_status', 'connected') != 'connected':
                    raise OSError('native owner disconnected')
                return
            if event != 'client_event':
                return
            sequence = envelope.get('sequence_num')
            if isinstance(sequence, str) and re.fullmatch(r'[0-9]{1,20}', sequence):
                sequence = int(sequence)
            if type(sequence) is not int or sequence <= 0:
                raise ValueError('invalid native sequence')
            if sequence <= self.last_sequence:
                return
            self.last_sequence = sequence  # Control-only streams legitimately skip non-control sequences.
            frame, source = envelope.get('payload'), envelope.get('source')
            if not isinstance(frame, dict) or source not in ('worker', 'client'):
                raise ValueError('invalid native envelope')
            native_session = frame.get('session_id')
            local_match = isinstance(native_session, str) and hashlib.sha256(
                ('claude:' + native_session).encode()).hexdigest() == self.session
            service_alias = 'cse_' + self.remote[len('session_'):]
            if native_session not in (self.remote, service_alias) and not local_match:
                reply = frame.get('response')
                checkpoint = (frame.get('type') == 'control_response' and isinstance(reply, dict)
                              and reply.get('request_id') == self.initializing)
                if self.initializing and not self.connected and not checkpoint:
                    return  # A resumed remote session can replay an earlier local owner.
                raise ValueError('wrong native session')
            kind = frame.get('type')
            if kind == 'control_response':
                reply = frame.get('response')
                if not isinstance(reply, dict):
                    raise ValueError('invalid native reply')
                rid = reply.get('request_id')
                if source == 'worker' and rid == self.initializing:
                    if reply.get('subtype') != 'success':
                        raise ValueError('native checkpoint refused')
                    permissions, dialogs = reply.get('pending_permission_requests'), reply.get('pending_user_dialog_requests')
                    if not isinstance(permissions, list) or not isinstance(dialogs, list):
                        raise ValueError('native pending snapshot unavailable')
                    pending = permissions + dialogs
                    if len(pending) > MAX_PENDING:
                        raise ValueError('too many native requests')
                    all_ids = {self._request(f) for f in pending}
                    if len(all_ids) != len(pending):
                        raise ValueError('duplicate native request')
                    self._diagnose(pending)
                    pending = [f for values, subtype in ((permissions, 'can_use_tool'), (dialogs, 'request_user_dialog'))
                               for f in values if f['request'].get('subtype') == subtype
                               and classify_request(f) == 'human']
                    current_ids = {self._request(f) for f in pending}
                    state = reply.get('response') or {}
                    if not isinstance(state, dict):
                        raise ValueError('invalid native session state')
                    if state.get('session_state') in ('idle', 'running', 'requires_action'):
                        self.session_waiting = state['session_state'] == 'requires_action'
                    # Replace replay and earlier observations with this checkpoint.
                    # It cannot reconstruct omitted elicitation/inherited prompts.
                    # The owner still awaits these decisions. Re-present them
                    # for explicit review; never resend the previous answer.
                    for unanswered in self.checkpoint_confirming & self.confirming & current_ids:
                        entry = self.pending.get(unanswered)
                        if entry and entry[0].response and entry[0].response.get('action') in ('answer', 'choose'):
                            self.broker.withdraw(self.pending.pop(unanswered)[0])
                            self.retired.discard(unanswered)
                    self.confirming.difference_update(self.checkpoint_confirming)
                    self.retired.intersection_update(current_ids)
                    for missing in (self.native.keys() | self.observed.keys()) - current_ids:
                        self._resolve(missing)
                    self.native = {self._request(f): deepcopy(f) for f in pending
                                   if f.get('request_id') not in self.resolved}
                    self.initializing = None
                    self.connected = True
                elif isinstance(rid, str) and source == 'worker':
                    self._resolve(rid)
                elif isinstance(rid, str) and source == 'client' and rid in self.native:
                    decision = reply.get('response')
                    if (reply.get('subtype') == 'success' and isinstance(decision, dict)
                            and decision.get('behavior') in ('allow', 'deny')):
                        self.confirming.add(rid)
                        self.next_checkpoint = time.monotonic() + 1
            elif kind == 'control_cancel_request' and source == 'worker':
                rid = frame.get('request_id')
                if not isinstance(rid, str):
                    raise ValueError('invalid native cancellation')
                self._resolve(rid)
            elif kind == 'control_request' and source == 'worker':
                rid = self._request(frame)
                self._diagnose([frame])
                if classify_request(frame) != 'human':
                    return
                if rid not in self.resolved:
                    if len(self.native) >= MAX_PENDING and rid not in self.native:
                        raise ValueError('too many native requests')
                    self.native[rid] = deepcopy(frame)
            if self.connected:
                self._sync()

    def _sync(self):
        for rid, frame in self.native.items():
            request = frame['request']
            if isinstance(request.get('tool_use_id'), str) and isinstance(request.get('tool_name'), str):
                actor = request.get('agent_id')
                scope = (hashlib.sha256(actor.encode()).hexdigest(),) if isinstance(actor, str) and actor else ()
                self.observed[rid] = request['tool_use_id'], request['tool_name'], *scope
        if self.completed:
            pending_tools = {(hashlib.sha256(f['request']['agent_id'].encode()).hexdigest(), f['request'].get('tool_name'))
                             if f['request'].get('agent_id') else f['request'].get('tool_name') for f in self.native.values()}
            self.resolution(list(self.completed.values()), pending_tools)
            self.completed.clear()
        for rid, (handle, _, _) in list(self.pending.items()):
            if rid not in self.native:
                self.broker.withdraw(handle)
                del self.pending[rid]
        for rid, frame in self.native.items():
            decoded = decode_request(self.session, frame)
            if rid in self.pending and (self.pending[rid][1] != frame or
                    decoded is None or self.pending[rid][2] != decoded[0]):
                self.broker.withdraw(self.pending.pop(rid)[0])
                self.retired.add(rid)
            if rid in self.pending or rid in self.retired or decoded is None:
                continue
            public, encode = decoded
            try:
                handle = self.broker.publish_live(public)
            except BrokerError:
                continue
            self.pending[rid] = (handle, deepcopy(frame), deepcopy(public))
            threading.Thread(target=self._answer, args=(rid, handle, encode), daemon=True).start()
        requests = frozenset((None, 'str', rid) for rid in self.native)
        inputs = frozenset(((None, 'str', rid), hashlib.sha256(
            (f['request'].get('elicitation_id') or f['request']['mcp_server_name']).encode()).hexdigest())
            for rid, f in self.native.items() if f['request'].get('subtype') == 'elicitation'
            and isinstance(f['request'].get('elicitation_id') or f['request'].get('mcp_server_name'), str))
        self.attention(PendingDecisions(self.remote, requests, inputs, waiting_on_human=self.session_waiting))

    def _diagnose(self, frames):
        counts = dict(human=0, internal=0, unknown=0, invalid=0)
        for frame in frames:
            counts[classify_request(frame)] += 1
        if counts != self.observed_counts:
            self.observed_counts = counts
            if self.broker.diagnostics is not None:
                self.broker.diagnostics.record('native_requests_observed', provider='claude',
                    sessionFingerprint=fingerprint(self.session),
                    **{kind + 'Count': count for kind, count in counts.items()})

    def _answer(self, rid, handle, encode):
        handle.ready.wait()
        with self.lock:
            entry = self.pending.get(rid)
            if not self.connected or entry is None or entry[0] is not handle:
                return
            frame = encode(handle.response or {'action': 'release'})
            self.retired.add(rid)
            if frame is None:
                self.broker.withdraw(handle)
                self.pending.pop(rid, None)
                return
        try:
            self.send(frame)
        except (OSError, ValueError, subprocess.SubprocessError):
            pass  # Never retry an uncertain decision.
        finally:
            with self.lock:
                if rid in self.native:
                    self.confirming.add(rid)
                    self.next_checkpoint = time.monotonic() + 1


class RemoteRequests:
    """One controls-only native subscription per active, already-shared session."""
    def __init__(self, broker, sessions, *, attention=lambda *_args: None,
                 resolved=lambda *_args: None, http_factory=NativeHTTP, owner_token=lambda *_: None):
        self.broker, self.sessions, self.attention = broker, sessions, attention
        self.resolution = resolved
        self.http_factory = http_factory
        self.owner_token = owner_token
        self.stop = threading.Event()
        self.workers = {}

    def __enter__(self):
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()
        return self

    def __exit__(self, *_args):
        self.stop.set()
        self.thread.join(timeout=3)
        for stop, reducer, _ in list(self.workers.values()):
            stop.set()
            reducer.close()

    def _run(self):
        while not self.stop.is_set():
            current = {(session, remote, self.owner_token(session, remote)): turn for session, remote, turn in self.sessions()}
            for identity in list(self.workers):
                if identity not in current:
                    stop, reducer, _ = self.workers.pop(identity)
                    stop.set()
                    reducer.close()
            for identity in current:
                if identity in self.workers:
                    continue
                session, remote, token = identity
                stop = threading.Event()
                http = self.http_factory(remote)
                def send(frame, *, http=http, stop=stop, session=session, remote=remote, token=token):
                    # A card may be submitted before the subscription poll
                    # retires its worker. Check the current binding at dispatch.
                    if (self.stop.is_set() or stop.is_set()
                            or not any((key, owner) == (session, remote) for key, owner, _turn in self.sessions())
                            or self.owner_token(session, remote) != token):
                        raise OSError('native session released')
                    http.send(frame)
                def callback(function, *args, session=session, remote=remote, token=token):
                    # Hook turns may advance while session-owned decisions stay
                    # pending. Recheck the owner at callback delivery time.
                    turn = next((turn for key, owner, turn in self.sessions() if (key, owner) == (session, remote)), None)
                    if turn is not None and self.owner_token(session, remote) == token:
                        function(session, turn, *args)
                reducer = NativeRequests(self.broker, session, remote, send,
                    attention=lambda value, callback=callback: callback(self.attention, value),
                    resolved=lambda tools, pending, callback=callback: callback(self.resolution, tools, pending))
                worker = threading.Thread(target=self._follow, args=(http, reducer, stop), daemon=True)
                self.workers[identity] = stop, reducer, worker
                worker.start()
            for _, reducer, _ in list(self.workers.values()):
                reducer.refresh()
            self.stop.wait(1)

    def _follow(self, http, reducer, stop):
        delay = 1
        while not self.stop.is_set() and not stop.is_set():
            try:
                with http.connect() as stream:
                    if self.stop.is_set() or stop.is_set():
                        break
                    reducer.initialize()
                    def check():
                        if self.stop.is_set() or stop.is_set():
                            raise OSError('native session released')
                        reducer.check()
                    for event, value in events(stream, check):
                        if self.stop.is_set() or stop.is_set():
                            break
                        reducer.receive(event, value)
                        if reducer.connected:
                            delay = 1
            except (OSError, EOFError, ValueError, KeyError, TypeError, RecursionError, subprocess.SubprocessError):
                pass
            finally:
                reducer.disconnect()
            stop.wait(delay)
            delay = min(60, delay * 2)
