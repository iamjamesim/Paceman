"""Ephemeral responses to live agent-owned requests.

An HTTP receipt confirms submission to Paceman, never agent consumption. The
native adapter owns each request's lifetime; neither requests nor answers persist.
"""
from __future__ import annotations

from collections import OrderedDict
from copy import deepcopy
from dataclasses import dataclass, field
import errno
import hashlib
import json
import math
import os
from pathlib import Path
import re
import select
import socket
import socketserver
import stat
import threading
import time
import uuid

from service.diagnostics import fingerprint as support_fingerprint
from service.interaction_content import normalize_approval


MAX_WIRE_BYTES = 65536
RESPONSE_TIMEOUT_SECONDS = 600
IDENTIFIER = re.compile(r"[A-Za-z0-9_.:-]{1,160}\Z")


class BrokerError(ValueError):
    def __init__(self, code, status=400):
        self.code, self.status = code, status
        super().__init__(code)


def _text(value, limit, *, empty=False):
    if (not isinstance(value, str) or len(value) > limit
            or (not empty and not value.strip())
            or any((ord(c) < 32 and c not in "\t\r\n") or 0xD800 <= ord(c) <= 0xDFFF for c in value)):
        raise BrokerError("invalid_request")
    return value


def _identifier(value):
    if not isinstance(value, str) or not IDENTIFIER.fullmatch(value):
        raise BrokerError("invalid_request")
    return value


def _keys(value, required, optional=()):
    if not isinstance(value, dict) or not set(required) <= value.keys() or value.keys() - set(required) - set(optional):
        raise BrokerError("invalid_request")


def _request(value):
    _keys(value, ("provider", "sessionID", "kind", "title", "detail"),
          ("questions", "contentVersion", "approval", "responseOptions"))
    if value["kind"] not in ("approval", "question"):
        raise BrokerError("invalid_request")
    if (not isinstance(value["sessionID"], str)
            or not re.fullmatch(r"[0-9a-f]{64}", value["sessionID"])):
        raise BrokerError("invalid_request")
    result = {"provider": _identifier(value["provider"]), "sessionID": _identifier(value["sessionID"]),
              "kind": value["kind"], "title": _text(value["title"], 256),
              "detail": _text(value["detail"], 16384, empty=True), "questions": []}
    content_version = value.get("contentVersion", 1)
    if type(content_version) is not int or content_version not in (1, 2, 3, 4, 5):
        raise BrokerError("invalid_request")
    if content_version in (2, 4, 5):
        if value["kind"] != "approval" or value["detail"]:
            raise BrokerError("invalid_request")
        try:
            result["approval"] = normalize_approval(value["provider"], value.get("approval"))
        except (ValueError, TypeError, OverflowError, RecursionError):
            raise BrokerError("invalid_request") from None
        options = value.get("responseOptions")
        if not isinstance(options, list) or len(options) > 16:
            raise BrokerError("invalid_request")
        result.update(contentVersion=content_version, responseOptions=[])
        for option in options:
            _keys(option, ("id", "label"), ("confirmation", "commandPrefix") if content_version == 5
                  else ("confirmation",) if content_version == 4 else ())
            normalized = {"id": _identifier(option["id"]), "label": _text(option["label"], 512)}
            if "confirmation" in option:
                normalized["confirmation"] = _text(option["confirmation"], 32768)
            if "commandPrefix" in option:
                prefix = option["commandPrefix"]
                if (not isinstance(prefix, list) or not 1 <= len(prefix) <= 256
                        or "confirmation" in option or result["approval"]["action"]["kind"] != "command"):
                    raise BrokerError("invalid_request")
                normalized["commandPrefix"] = [_text(argument, 32768, empty=True) for argument in prefix]
                if not prefix[0].strip():
                    raise BrokerError("invalid_request")
            result["responseOptions"].append(normalized)
        if len({o["id"] for o in options}) != len(options):
            raise BrokerError("invalid_request")
    elif any(k in value for k in ("approval", "responseOptions")):
        raise BrokerError("invalid_request")
    if content_version == 3:
        if value["kind"] != "question":
            raise BrokerError("invalid_request")
        result["contentVersion"] = 3
    questions = value.get("questions", [])
    if not isinstance(questions, list) or len(questions) > 4:
        raise BrokerError("invalid_request")
    if bool(questions) != (result["kind"] == "question"):
        raise BrokerError("invalid_request")
    ids = set()
    for q in questions:
        _keys(q, ("id", "prompt", "multiple", "options", "allowsText") if content_version == 3
              else ("id", "prompt", "multiple", "options"))
        if content_version == 3 and (type(q["allowsText"]) is not bool or not q["allowsText"] and not q["options"]):
            raise BrokerError("invalid_request")
        qid = _identifier(q["id"])
        if qid in ids or type(q["multiple"]) is not bool or not isinstance(q["options"], list) or len(q["options"]) > 16:
            raise BrokerError("invalid_request")
        ids.add(qid)
        options = []
        for option in q["options"]:
            _keys(option, ("label", "description"))
            options.append({"label": _text(option["label"], 512),
                            "description": _text(option["description"], 2048, empty=True)})
        result["questions"].append({"id": qid, "prompt": _text(q["prompt"], 4096),
                                    "multiple": q["multiple"], "options": options,
                                    **({"allowsText": q["allowsText"]} if content_version == 3 else {})})
    if len(json.dumps(result).encode()) > MAX_WIRE_BYTES:
        raise BrokerError("invalid_request")
    return result


@dataclass
class _Pending:
    public: dict
    deadline: float | None
    ready: threading.Event = field(default_factory=threading.Event)
    response: dict | None = None


class InteractionBroker:
    def __init__(self, clock=time.monotonic, provider_enabled=None, diagnostics=None):
        self.generation = str(uuid.uuid4())
        self._clock = clock
        self._lock = threading.RLock()
        self._pending = {}
        self._receipts = OrderedDict()
        self._awaiting_native = OrderedDict()
        self._closed = False
        self._provider_enabled = provider_enabled or (lambda provider: True)
        self.diagnostics = diagnostics

    def _record(self, stage, request, **fields):
        if self.diagnostics is not None:
            self.diagnostics.record(stage, provider=request["provider"], kind=request["kind"],
                requestFingerprint=support_fingerprint(request["requestID"]),
                sessionFingerprint=support_fingerprint(request["sessionID"]), **fields)

    def _enabled(self, provider):
        try:
            return bool(self._provider_enabled(provider))
        except Exception:
            return False

    def _prune(self):
        now = self._clock()
        for request_id, pending in list(self._pending.items()):
            if pending.deadline is not None and pending.deadline <= now:
                self._release(request_id, "deadline")
            elif not self._enabled(pending.public["provider"]):
                self._release(request_id, "provider_disabled")
        for request_id, receipt in list(self._receipts.items()):
            if receipt[0] <= now:
                del self._receipts[request_id]
        for request_id, provider in list(self._awaiting_native.items()):
            if not self._enabled(provider):
                del self._awaiting_native[request_id]

    def _release(self, request_id, reason="hook_disconnected"):
        self._awaiting_native.pop(request_id, None)
        pending = self._pending.pop(request_id, None)
        if pending:
            self._record("request_released", pending.public, reason=reason)
            pending.response = {"action": "release"}
            pending.ready.set()

    def _publish(self, request, timeout):
        normalized = _request(request)
        if type(timeout) not in (int, float) or not math.isfinite(timeout) or not 0 < timeout <= RESPONSE_TIMEOUT_SECONDS:
            raise BrokerError("invalid_request")
        with self._lock:
            self._prune()
            if self._closed:
                raise BrokerError("unavailable", 503)
            if not self._enabled(normalized["provider"]):
                raise BrokerError("unavailable", 503)
            if len(self._pending) >= 32:
                raise BrokerError("busy", 429)
            request_id = str(uuid.uuid4())
            normalized.update(requestID=request_id, version=1)
            pending = _Pending(normalized, self._clock() + timeout)
            self._pending[request_id] = pending
            self._record("request_published", normalized, pendingCount=len(self._pending))
            return pending

    def _cancel(self, pending):
        with self._lock:
            self._release(pending.public["requestID"])

    def publish_live(self, request):
        """The adapter owns lifetime and must withdraw on resolution/disconnect.

        The phone still gets a bounded display lease; elapsed time cannot expire
        an operation that the connected agent confirms is pending.
        """
        with self._lock:
            pending = self._publish(request, RESPONSE_TIMEOUT_SECONDS)
            pending.deadline = None
            return pending

    def withdraw(self, pending):
        self._cancel(pending)

    def pending(self, content_version=5):
        with self._lock:
            self._prune()
            return {"generation": self.generation,
                    "awaitingRequestIDs": list(self._awaiting_native),
                    "requests": [dict(deepcopy(p.public), remainingSeconds=(RESPONSE_TIMEOUT_SECONDS
                                     if p.deadline is None else max(0, p.deadline - self._clock())))
                                 for p in self._pending.values()
                                 if p.public.get("contentVersion", 1) <= content_version]}

    def submit(self, payload, *, trace_id=None, origin=None):
        _keys(payload, ("generation", "requestID", "version", "idempotencyKey", "action"), ("answers", "optionID"))
        generation = _identifier(payload["generation"])
        request_id = _identifier(payload["requestID"])
        key = _identifier(payload["idempotencyKey"])
        if type(payload["version"]) is not int or payload["version"] != 1:
            raise BrokerError("invalid_request")
        action = payload["action"]
        if action not in ("allowOnce", "deny", "answer", "release", "choose"):
            raise BrokerError("invalid_request")
        option_id = _identifier(payload.get("optionID")) if action == "choose" else None
        if action != "choose" and "optionID" in payload:
            raise BrokerError("invalid_request")
        # Validate bounded answer data before looking up receipts. Receipt hashes
        # retain no answer text, and identical retries do not need the prompt.
        answers = payload.get("answers", {})
        if not isinstance(answers, dict) or len(answers) > 4:
            raise BrokerError("invalid_request")
        normalized_answers = {}
        for qid, answer in answers.items():
            _identifier(qid)
            _keys(answer, ("selected", "text"))
            selected = answer["selected"]
            if (not isinstance(selected, list) or len(selected) > 16
                    or any(type(i) is not int or not 0 <= i < 16 for i in selected)
                    or len(set(selected)) != len(selected)):
                raise BrokerError("invalid_request")
            normalized_answers[qid] = {"selected": sorted(selected), "text": _text(answer["text"], 4096, empty=True)}
        if action != "answer" and answers:
            raise BrokerError("invalid_request")
        response = {"action": action}
        if action == "choose":
            response["optionID"] = option_id
        if action == "answer":
            response["answers"] = normalized_answers
        fingerprint = hashlib.sha256(json.dumps(response, sort_keys=True).encode()).hexdigest()
        with self._lock:
            self._prune()
            if self._closed:
                raise BrokerError("unavailable", 503)
            if generation != self.generation:
                raise BrokerError("stale_request", 409)
            receipt = self._receipts.get(request_id)
            if receipt:
                if receipt[1:3] != (key, fingerprint):
                    raise BrokerError("response_conflict", 409)
                if self.diagnostics is not None:
                    self.diagnostics.record("response_replayed", requestFingerprint=support_fingerprint(request_id),
                                            action=action, traceID=trace_id, origin=origin)
                return dict(receipt[3])
            pending = self._pending.get(request_id)
            if pending is None:
                raise BrokerError("stale_request", 409)
            request = pending.public
            if action == "choose":
                if request.get("contentVersion") not in (2, 4, 5) or option_id not in {o["id"] for o in request["responseOptions"]}:
                    raise BrokerError("invalid_response")
            elif request.get("contentVersion") in (2, 4, 5) and action != "release":
                raise BrokerError("invalid_response")
            if action == "answer":
                if request["kind"] != "question" or set(answers) != {q["id"] for q in request["questions"]}:
                    raise BrokerError("invalid_response")
                for question in request["questions"]:
                    answer = normalized_answers[question["id"]]
                    if (not answer["selected"] and not answer["text"].strip()
                            or not question.get("allowsText", True) and bool(answer["text"])
                            or not question["multiple"] and len(answer["selected"]) > 1
                            or any(i >= len(question["options"]) for i in answer["selected"])):
                        raise BrokerError("invalid_response")
            elif action in ("allowOnce", "deny") and request["kind"] != "approval":
                raise BrokerError("invalid_response")
            del self._pending[request_id]
            pending.response = response
            result = {"status": "submitted", "generation": self.generation,
                      "requestID": request_id, "version": 1}
            self._receipts[request_id] = (self._clock() + 300, key, fingerprint, result)
            if pending.deadline is None and action != "release":
                # IDs only: native adapters withdraw even after submission. An
                # HTTP receipt alone cannot establish native consumption.
                self._awaiting_native[request_id] = request["provider"]
                while len(self._awaiting_native) > 256:
                    self._awaiting_native.popitem(last=False)
            while len(self._receipts) > 256:
                self._receipts.popitem(last=False)
            pending.ready.set()
            self._record("response_submitted", request, action=action, traceID=trace_id, origin=origin)
            return dict(result)

    def cancel_all(self, reason="access_changed"):
        """Invalidate phone credentials/config-era requests without reopening any."""
        with self._lock:
            for request_id in list(self._pending):
                self._release(request_id, reason)
            self._receipts.clear()
            self._awaiting_native.clear()
            self.generation = str(uuid.uuid4())

    def close(self):
        with self._lock:
            self._closed = True
            self.cancel_all("shutdown")


class _Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
    block_on_close = False

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()

    def handle_error(self, request, client_address):
        # No provider content, request fields, or traceback in diagnostics.
        pass


class _Handler(socketserver.BaseRequestHandler):
    def handle(self):
        connection = self.request
        broker = self.server.broker
        pending = None
        response = {"action": "release"}
        try:
            connection.settimeout(1)
            raw = bytearray()
            # One absolute deadline also bounds peers trickling bytes forever.
            read_deadline = time.monotonic() + 1
            while b"\n" not in raw:
                remaining = read_deadline - time.monotonic()
                if remaining <= 0:
                    raise ValueError()
                connection.settimeout(remaining)
                chunk = connection.recv(min(4096, MAX_WIRE_BYTES + 1 - len(raw)))
                if not chunk:
                    return
                raw.extend(chunk)
                if len(raw) > MAX_WIRE_BYTES:
                    raise ValueError()
            if raw.find(b"\n") != len(raw) - 1:
                raise ValueError()
            message = json.loads(raw)
            _keys(message, ("request",), ("timeoutSeconds",))
            pending = broker._publish(message["request"], message.get("timeoutSeconds", RESPONSE_TIMEOUT_SECONDS))
            connection.settimeout(.2)
            while not pending.ready.is_set():
                if select.select([connection], [], [], .05)[0]:
                    # EOF or extra input ends this invocation's authority.
                    connection.recv(1, socket.MSG_PEEK)
                    broker._cancel(pending)
                    return
                with broker._lock:
                    broker._prune()
            # Check cancellation before writing even if submit won the race.
            if select.select([connection], [], [], 0)[0]:
                return
            response = pending.response or response
        except BrokerError as error:
            if broker.diagnostics is not None:
                broker.diagnostics.record("request_rejected", reason=error.code)
        except (ValueError, TypeError, OSError, OverflowError, RecursionError):
            pass
        finally:
            if pending is not None:
                broker._cancel(pending)
        try:
            connection.sendall(json.dumps(response).encode() + b"\n")
        except OSError:
            pass


class ResponseListener:
    def __init__(self, broker, path):
        self.broker, self.path = broker, Path(path)
        self.server = self.thread = self.inode = None

    def __enter__(self):
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        parent = self.path.parent.stat()
        if parent.st_uid != os.getuid() or parent.st_mode & 0o077:
            raise ValueError("Interaction socket directory must be private to this user")
        if self.path.exists() or self.path.is_symlink():
            info = self.path.lstat()
            if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
                raise ValueError("Interaction socket path is not an owned socket")
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(.2)
                try:
                    client.connect(str(self.path))
                except OSError as error:
                    if error.errno != errno.ECONNREFUSED:
                        raise
                else:
                    raise ValueError("Interaction socket is already in use")
            if self.path.lstat().st_ino != info.st_ino:
                raise ValueError("Interaction socket changed during startup")
            self.path.unlink()
        self.server = _Server(str(self.path), _Handler)
        self.inode = self.path.lstat().st_ino
        try:
            os.chmod(self.path, 0o600)
            self.server.broker = self.broker
            self.server.slots = threading.BoundedSemaphore(32)
            self.thread = threading.Thread(target=self.server.serve_forever,
                                           kwargs={"poll_interval": .05}, daemon=True)
            self.thread.start()
        except BaseException:
            self.close()
            raise
        return self

    def close(self):
        self.broker.close()
        if self.server:
            if self.thread and self.thread.is_alive():
                self.server.shutdown()
                self.thread.join(timeout=2)
            self.server.server_close()
        try:
            if self.inode is not None and self.path.lstat().st_ino == self.inode:
                self.path.unlink()
        except FileNotFoundError:
            pass
        self.server = self.thread = self.inode = None

    def __exit__(self, *_):
        self.close()
