"""Follower of the existing Codex desktop owner; never starts/resumes an agent.

The desktop IPC interface is private and versioned. Accept only the verified
stream version, withdraw on any gap, and use exact owner/request identities.
No router startup, ownership claim, global client identity, or config mutation.
"""
from copy import deepcopy
import json
import os
from pathlib import Path
import socket
import stat
import struct
import threading
import time
import uuid

from service.codex_requests import decode_request, decode_async_question, is_browser_approval
from service.codex_policy import read_browser_policy
from service.interactions import BrokerError


MAX_FRAME = 16 * 1024 * 1024
STREAM_VERSION = 11


def _item(value):
    fields = {"fileChange": ("id", "type", "changes"),
              "commandExecution": ("id", "type", "command", "processId"),
              "agentMessage": ("id", "type", "questions"),
              "userInputResponse": ("id", "type", "completed", "requestId"),
              "userMessage": ("type", "content"),
              "steeringUserMessage": ("type", "input", "status")}.get(value.get("type"), ())
    result = {k: deepcopy(value[k]) for k in fields if k in value}
    for field in ("input", "content"):
        if field in result and not _answered(result[field]):
            result[field] = []
    return result


def _answered(content):
    if (not isinstance(content, list) or len(content) != 1 or not isinstance(content[0], dict)
            or content[0].get("type") != "text" or not isinstance(content[0].get("text"), str)):
        return []
    text = content[0]["text"].strip()
    start, end = "<send_user_message_question_reply>", "</send_user_message_question_reply>"
    if not text.startswith(start) or not text.endswith(end):
        return []
    try:
        value = json.loads(text[len(start):-len(end)])
    except ValueError:
        return []
    values = value if isinstance(value, list) else [value]
    if not values or any(not isinstance(v, dict) or any(not isinstance(v.get(k), str)
                         for k in ("questionItemId", "question", "answer")) for v in values):
        return []
    return [v["questionItemId"] for v in values]


def _turn(value):
    return dict(turnId=value.get("turnId"), status=value.get("status"), items=[_item(i) for i in value.get("items", [])])


def _history(value):
    if not value:
        return None
    if value.get("kind") != "canonical":
        raise ValueError("unsupported native history")
    return dict(kind="canonical", history=dict(entitiesByKey={
        key: _turn(turn) for key, turn in value["history"]["entitiesByKey"].items()}))


def _turns(state):
    return [*(state.get("turns") or []), *((state.get("turnHistory") or {}).get("history", {}).get("entitiesByKey", {}).values())]


def _async_waiting(turn):
    if turn.get("status") != "inProgress":
        return False
    questions, answered = set(), set()
    for item in turn["items"]:
        if item.get("type") == "userInputResponse" and item.get("completed") is False:
            return True
        if item.get("type") == "agentMessage":
            questions.update(json.dumps(["request_user_input_async", item["id"], index], separators=(",", ":"), ensure_ascii=False)
                             for index, _ in enumerate(item.get("questions") or []))
        if item.get("type") == "userMessage":
            answered.update(_answered(item.get("content")))
        if item.get("type") == "steeringUserMessage" and item.get("status") == "accepted":
            answered.update(_answered(item.get("input")))
    return bool(questions - answered)


def read_frame(connection):
    def exact(count):
        data = bytearray()
        while len(data) < count:
            chunk = connection.recv(count - len(data))
            if not chunk:
                raise EOFError()
            data.extend(chunk)
        return data
    length, = struct.unpack("<I", exact(4))
    if not 0 < length <= MAX_FRAME:
        raise ValueError("invalid frame size")
    value = json.loads(exact(length))
    if not isinstance(value, dict):
        raise ValueError("invalid frame")
    return value


def owned_socket(path):
    # Do not create, chmod, replace, or probe arbitrary sockets.
    info, parent = path.lstat(), path.parent.stat()
    return (stat.S_ISSOCK(info.st_mode) and info.st_uid == os.getuid()
            and parent.st_uid == os.getuid() and not parent.st_mode & 0o077)


class DesktopRequests:
    def __init__(self, broker, sessions, *, path=None, attention=None, policy_reader=read_browser_policy):
        self.broker, self.sessions = broker, sessions
        self.path = path or Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))) / "ipc/ipc.sock"
        self.attention = attention or (lambda session, pending: None)
        self.stop = threading.Event()
        self.connection = None
        self.client = None
        self.lock = threading.RLock()
        self.write_lock = threading.Lock()
        self.calls = {}
        self.owners = {}
        self.states = {}
        self.pending = {}
        self.retired = set()
        self.discovering = set()
        self.retry_at = {}
        self.thread = None
        self.policy_reader = policy_reader
        self.browser_policy = None
        self.policy_loaded = False
        self.policy_loading = False
        self.policy_epoch = object()

    def __enter__(self):
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()
        return self

    def unavailable(self, session):
        with self.lock:
            return session not in self.owners and (self.connection is None or session in self.retry_at)

    def __exit__(self, *_):
        self.stop.set()
        if self.connection is not None:
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        if self.thread:
            self.thread.join(timeout=3)
        self._reset()

    def _send(self, value, connection=None):
        data = json.dumps(value, ensure_ascii=False, allow_nan=False).encode()
        if len(data) > MAX_FRAME:
            raise ValueError("oversized frame")
        with self.write_lock:
            if self.connection is None:
                raise OSError("disconnected")
            if connection is not None and self.connection is not connection:
                raise OSError("connection changed")
            self.connection.sendall(struct.pack("<I", len(data)) + data)

    def _request(self, method, params, *, target=None, connection=None):
        rid = str(uuid.uuid4())
        done, box = threading.Event(), []
        with self.lock:
            self.calls[rid] = (done, box)
        try:
            self._send(dict(type="request", requestId=rid, sourceClientId=self.client or "initializing-client",
                            version=0 if method == "initialize" else 1, method=method,
                            params=params, **({"targetClientId": target} if target else {})), connection)
            if not done.wait(5) or not box or box[0].get("resultType") != "success":
                raise OSError("request unavailable")
            return box[0]
        finally:
            with self.lock:
                self.calls.pop(rid, None)

    def _follow(self, session, owner, following, connection=None):
        self._send(dict(type="broadcast", method="thread-stream-following-changed", version=1,
                        sourceClientId=self.client, targetClientIds=[owner],
                        params=dict(hostId="local", conversationId=session, following=following)), connection)

    def _reset(self):
        with self.lock:
            for handle, _, _ in self.pending.values():
                self.broker.withdraw(handle)
            for session in self.owners:
                self.attention(session, None)
            for done, _ in self.calls.values():
                done.set()
            self.pending.clear()
            self.owners.clear()
            self.states.clear()
            self.retired.clear()
            self.retry_at.clear()
            self.client = None
            self.policy_epoch = object()
            self.policy_loaded = self.policy_loading = False
            self.browser_policy = None

    def _run(self):
        while not self.stop.is_set():
            try:
                if not owned_socket(self.path):
                    raise OSError("unavailable")
                with socket.socket(socket.AF_UNIX) as connection:
                    connection.settimeout(3)
                    connection.connect(str(self.path))
                    connection.settimeout(None)
                    self.connection = connection
                    reader = threading.Thread(target=self._read, args=(connection,), daemon=True)
                    reader.start()
                    self.client = self._request("initialize", {"clientType": "paceman"})["result"]["clientId"]
                    while not self.stop.is_set() and reader.is_alive():
                        sessions = set(self.sessions())
                        with self.lock:
                            existing = dict(self.owners)
                        for session, owner in existing.items():
                            if session not in sessions:
                                self._follow(session, owner, False)
                                self._forget(session)
                        for session in sessions - existing.keys():
                            if self.stop.is_set() or not reader.is_alive():
                                break
                            with self.lock:
                                if (session in self.discovering or len(self.discovering) >= 4
                                        or time.monotonic() < self.retry_at.get(session, 0)):
                                    continue
                                self.discovering.add(session)
                            threading.Thread(target=self._discover, args=(session, connection), daemon=True).start()
                        self.stop.wait(2)
                    try:
                        connection.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
                    reader.join(timeout=2)
            except (OSError, EOFError, ValueError, KeyError, TypeError):
                pass
            finally:
                self.connection = None
                self._reset()
            self.stop.wait(3)

    def _discover(self, session, connection):
        try:
            reply = self._request("thread-owner-discovery", dict(hostId="local", conversationId=session), connection=connection)
            owner = reply.get("handledByClientId")
            with self.lock:
                if self.connection is not connection or self.stop.is_set() or not isinstance(owner, str):
                    return
                self.owners[session] = owner
                self._follow(session, owner, True, connection)
        except (OSError, ValueError):
            with self.lock:
                if self.connection is connection:
                    self.retry_at[session] = time.monotonic() + 30
        finally:
            with self.lock:
                self.discovering.discard(session)

    def _forget(self, session):
        with self.lock:
            for key, (handle, _, _) in list(self.pending.items()):
                if key[0] == session:
                    self.broker.withdraw(handle)
                    del self.pending[key]
            self.states.pop(session, None)
            self.owners.pop(session, None)
            self.retired = {k for k in self.retired if k[0] != session}
            self.attention(session, None)

    def _read(self, connection):
        try:
            while not self.stop.is_set():
                self._receive(read_frame(connection))
        except (OSError, EOFError, ValueError, KeyError, TypeError, IndexError, AttributeError, RecursionError):
            # A malformed/private-protocol update cannot leave actionable cards.
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            self._reset()

    def _receive(self, message):
        if message.get("targetClientIds") is not None and self.client not in message["targetClientIds"]:
            return
        if message.get("type") == "response":
            with self.lock:
                call = self.calls.get(message.get("requestId"))
                if call:
                    call[1].append(message)
                    call[0].set()
            return
        if message.get("type") == "client-discovery-request":
            self._send(dict(type="client-discovery-response", requestId=message["requestId"], response={"canHandle": False}))
            return
        if message.get("type") != "broadcast":
            return
        if message.get("method") == "client-status-changed":
            params = message.get("params", {})
            if params.get("status") == "disconnected":
                for session, owner in list(self.owners.items()):
                    if owner == params.get("clientId"):
                        self._forget(session)
            return
        if message.get("method") != "thread-stream-state-changed":
            return
        params = message.get("params", {})
        session = params.get("conversationId")
        with self.lock:
            if (params.get("hostId") != "local" or session not in self.owners
                    or message.get("sourceClientId") != self.owners[session]):
                return
            if message.get("version") != STREAM_VERSION:
                raise ValueError("unsupported native stream")
            change = params["change"]
            if change["type"] == "snapshot":
                state = change["conversationState"]
                if not isinstance(state, dict) or state.get("id") != session:
                    raise ValueError("wrong native session")
                # Retain only request data and associated review items in RAM.
                self.states[session] = (change["revision"], dict(requests=deepcopy(state.get("requests")),
                    turns=[_turn(t) for t in state.get("turns") or []], turnHistory=_history(state.get("turnHistory"))))
            elif change["type"] == "patches":
                previous = self.states.get(session)
                if previous is None or previous[0] != change["baseRevision"]:
                    raise ValueError("native stream gap")
                state = deepcopy(previous[1])
                for patch in change["patches"]:
                    self._patch(state, patch)
                self.states[session] = (change["revision"], state)
            else:
                raise ValueError("unsupported native change")
            self._sync(session, self.states[session][1])

    @staticmethod
    def _patch(state, patch):
        path = patch["path"]
        if not isinstance(path, list) or not path:
            raise ValueError("invalid patch")
        if path[0] not in ("requests", "turns", "turnHistory"):
            return
        transform = lambda v: deepcopy(v)
        offset = None
        if path[0] == "turns":
            if len(path) == 1:
                transform = lambda v: [_turn(t) for t in v]
            else:
                offset = 2
        if path[0] == "turnHistory":
            if len(path) == 1:
                transform = _history
            elif path[1] != "history":
                return
            elif len(path) == 2:
                transform = lambda v: {"entitiesByKey": {k: _turn(t) for k, t in v["entitiesByKey"].items()}}
            elif path[2] != "entitiesByKey":
                return
            elif len(path) == 3:
                transform = lambda v: {k: _turn(t) for k, t in v.items()}
            else:
                offset = 4
        if offset is not None:
            rest = path[offset:]
            if not rest:
                transform = _turn
            elif rest[0] not in ("items", "status", "turnId"):
                return
            elif rest[0] == "items":
                if len(rest) == 1:
                    transform = lambda v: [_item(i) for i in v]
                elif len(rest) == 2:
                    transform = _item
                elif rest[2] not in ("id", "type", "changes", "questions", "completed", "requestId", "content", "input", "status", "command", "processId"):
                    return
        parent = state
        for key in path[:-1]:
            parent = parent[key]
        key, op = path[-1], patch["op"]
        if op == "remove":
            del parent[key]
        elif op == "add" and isinstance(parent, list):
            parent.insert(key, transform(patch["value"]))
        elif op in ("add", "replace"):
            parent[key] = transform(patch["value"])
        else:
            raise ValueError("unsupported patch")

    def _sync(self, session, state):
        requests = state["requests"]
        if not isinstance(requests, list):
            raise ValueError("invalid native requests")
        native = {}
        asynchronous = {}
        turns = _turns(state)
        for request in requests:
            if request.get("completed") is True:
                continue
            rid = request.get("id")
            if type(rid) not in (str, int) or isinstance(rid, bool):
                raise ValueError("invalid native id")
            key = (session, type(rid).__name__, str(rid))
            native[key] = request
        for turn in turns:
            if turn.get("status") != "inProgress" or not isinstance(turn.get("turnId"), str):
                continue
            answered = set()
            for item in turn["items"]:
                if item.get("type") == "userMessage":
                    answered.update(_answered(item.get("content")))
                if item.get("type") == "steeringUserMessage" and item.get("status") == "accepted":
                    answered.update(_answered(item.get("input")))
            for item in turn["items"]:
                if item.get("type") != "agentMessage" or not isinstance(item.get("id"), str):
                    continue
                for index, question in enumerate(item.get("questions") or []):
                    qid = json.dumps(["request_user_input_async", item["id"], index], separators=(",", ":"), ensure_ascii=False)
                    if qid in answered:
                        continue
                    key = (session, "async", qid)
                    native[key] = dict(id=qid, params=dict(turnId=turn["turnId"]), question=deepcopy(question))
                    asynchronous[key] = decode_async_question(session, turn["turnId"], item["id"], index, question)
        for key, (handle, _, _) in list(self.pending.items()):
            if key[0] == session and key not in native:
                self.broker.withdraw(handle)
                del self.pending[key]
        self.retired = {k for k in self.retired if k[0] != session or k in native}
        for key, request in native.items():
            items = [i for t in turns if t.get("turnId") == request.get("params", {}).get("turnId") for i in t["items"]]
            if is_browser_approval(request) and not self.policy_loaded:
                if not self.policy_loading:
                    self.policy_loading = True
                    threading.Thread(target=self._load_browser_policy, args=(self.policy_epoch,), daemon=True).start()
                continue
            decoded = asynchronous[key] if key in asynchronous else decode_request(session, request, items,
                browser_global_allowed=self.browser_policy)
            if key in self.pending and (self.pending[key][1] != request
                    or decoded is None or self.pending[key][2] != decoded[0]):
                self.broker.withdraw(self.pending.pop(key)[0])
                self.retired.add(key)  # Request or review changed: keep native.
            if key in self.pending or key in self.retired:
                continue
            if decoded is None:
                continue
            public, encode = decoded
            try:
                handle = self.broker.publish_live(public)
            except BrokerError:
                continue
            self.pending[key] = (handle, deepcopy(request), deepcopy(public))
            threading.Thread(target=self._answer, args=(key, handle, encode), daemon=True).start()
        human = {"item/commandExecution/requestApproval", "item/fileChange/requestApproval",
                 "item/permissions/requestApproval", "item/tool/requestUserInput",
                 "item/tool/requestOptionPicker", "mcpServer/elicitation/request"}
        by_turn = {t["turnId"]: _async_waiting(t) for t in turns if isinstance(t.get("turnId"), str)}
        for request in native.values():
            turn = request.get("params", {}).get("turnId")
            if request.get("method") in human and isinstance(turn, str):
                by_turn[turn] = True
            elif request.get("method") == "item/plan/requestImplementation" and isinstance(turn, str):
                by_turn[turn] = "planImplementation"
        self.attention(session, by_turn)

    def _load_browser_policy(self, epoch):
        try:
            allowed = self.policy_reader()
        except (OSError, ValueError):
            allowed = None
        with self.lock:
            if self.stop.is_set() or epoch is not self.policy_epoch:
                return
            self.browser_policy = allowed
            self.policy_loaded, self.policy_loading = True, False
            for session, (_, state) in list(self.states.items()):
                self._sync(session, state)

    def _answer(self, key, handle, encode):
        handle.ready.wait()
        global_allowed = True
        if (handle.response or {}).get('optionID') == 'browser-all-sites':
            try:
                global_allowed = self.policy_reader() is True
            except (OSError, ValueError):
                global_allowed = False
        with self.lock:
            entry = self.pending.get(key)
            if entry is None or entry[0] is not handle:
                return
            response = encode(handle.response or {"action": "release"}) if global_allowed else None
            if response is None:
                # Release only relinquishes Paceman's card, never the agent's
                # prompt. Access changes do not reopen it on every patch.
                self.retired.add(key)
                self.broker.withdraw(handle)
                self.pending.pop(key, None)
                return
            method, payload = response
            session = key[0]
            if method == "thread-follower-steer-turn":
                active = {t.get("turnId") for t in _turns(self.states.get(session, (None, {}))[1])
                          if t.get("status") == "inProgress"}
                if active != {entry[1]["params"]["turnId"]}:
                    return  # Never start a turn to deliver an expired question.
            owner = self.owners.get(session)
            native_id = entry[1]["id"]
            connection = self.connection
            self.retired.add(key)
        try:
            params = dict(conversationId=session, **payload)
            if method != "thread-follower-steer-turn":
                params["requestId"] = native_id
            self._request(method, params, target=owner, connection=connection)
        except (OSError, ValueError):
            # Reconcile against a new native snapshot; never resend a decision.
            with self.lock:
                if self.connection is connection and connection is not None:
                    try:
                        connection.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
