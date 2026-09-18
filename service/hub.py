"""Private activity source for real-device transport tests.

Run with python3 -m service.hub. No agent hooks or installed watch service touched.
Only loopback HTTP is accepted; Tailscale Serve provides the remote TLS boundary.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import sqlite3
import threading
import time
import unicodedata
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit
import uuid

STATES = {"idle", "working", "needs_input", "finished"}


class PairingConflict(ValueError):
    """An installation claim is not proof of ownership of an existing pairing."""


def device_identity(value):
    if not isinstance(value, dict):
        raise ValueError("Invalid device identity")
    if not isinstance(value.get("installationID"), str):
        raise ValueError("Invalid installation ID")
    installation = str(uuid.UUID(value["installationID"]))
    name, platform = value.get("name"), value.get("platform")
    if (not isinstance(name, str) or not 1 <= len(name.strip()) <= 80
            or any(unicodedata.category(c).startswith("C") for c in name)
            or platform not in ("ios", "macos", "linux", "android", "diagnostic")):
        raise ValueError("Invalid device identity")
    return installation, name.strip(), platform


def endpoint(value: str) -> str:
    parsed = urlsplit(value)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username
            or parsed.password or parsed.query or parsed.fragment
            or parsed.path not in ("", "/")):
        raise ValueError("Use an HTTPS origin with no path, credentials, or query")
    return value.rstrip("/")


def digest(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


class Store:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        # Create with private permissions from the first write.
        fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
        os.close(fd)
        os.chmod(path, 0o600)
        self.path = path
        with self.connect() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS invitations(hash TEXT PRIMARY KEY, expires REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS clients(id TEXT PRIMARY KEY, hash TEXT UNIQUE NOT NULL,
                    created REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS client_devices(client_id TEXT PRIMARY KEY,
                    installation_id TEXT UNIQUE NOT NULL, name TEXT NOT NULL, platform TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS events(seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    at REAL NOT NULL, state TEXT NOT NULL, label TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS schedule(id INTEGER PRIMARY KEY, due REAL NOT NULL,
                    state TEXT NOT NULL, fired INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE IF NOT EXISTS push_devices(
                    client_id TEXT PRIMARY KEY, token TEXT NOT NULL, environment TEXT NOT NULL,
                    mode TEXT NOT NULL, cursor INTEGER NOT NULL, next_attempt REAL NOT NULL DEFAULT 0,
                    attempts INTEGER NOT NULL DEFAULT 0, last_result TEXT, last_apns_id TEXT);
            """)
            db.execute("BEGIN IMMEDIATE")
            if "last_seen" not in {row[1] for row in db.execute("PRAGMA table_info(clients)")}:
                db.execute("ALTER TABLE clients ADD COLUMN last_seen REAL NOT NULL DEFAULT 0")
            columns = {row[1] for row in db.execute("PRAGMA table_info(events)")}
            if "payload" not in columns:
                db.execute("ALTER TABLE events ADD COLUMN payload TEXT")
            if "kind" not in columns:
                db.execute("ALTER TABLE events ADD COLUMN kind TEXT NOT NULL DEFAULT 'activity'")
            for key, value in [("source_id", str(uuid.uuid4())), ("generation", str(uuid.uuid4()))]:
                db.execute("INSERT OR IGNORE INTO metadata VALUES (?, ?)", (key, value))
            if db.execute("SELECT COUNT(*) FROM events").fetchone()[0] == 0:
                db.execute("INSERT INTO events(at,state,label) VALUES (?,?,?)",
                           (time.time(), "idle", "Initial synthetic state"))

    @contextmanager
    def connect(self):
        db = sqlite3.connect(self.path, timeout=5)
        db.row_factory = sqlite3.Row
        try:
            with db:
                yield db
        finally:
            db.close()

    def metadata(self, key: str) -> str:
        with self.connect() as db:
            return db.execute("SELECT value FROM metadata WHERE key=?", (key,)).fetchone()[0]

    def invite(self, origin: str, now: float | None = None) -> dict:
        origin = endpoint(origin)
        now = time.time() if now is None else now
        token = secrets.token_urlsafe(32)
        with self.connect() as db:
            db.execute("DELETE FROM invitations WHERE expires<=?", (now,))
            db.execute("INSERT INTO invitations VALUES (?,?)", (digest(token), now + 300))
        return {"schema": 1, "endpoint": origin, "sourceID": self.metadata("source_id"),
                "invitation": token, "expiresAt": now + 300}

    def redeem(self, token: str, now: float | None = None, *, device=None, previous_token="") -> dict | None:
        identity = device_identity(device) if device is not None else None
        now = time.time() if now is None else now
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT expires FROM invitations WHERE hash=?", (digest(token),)).fetchone()
            if row is None or row[0] <= now:
                return None
            credential, client_id = secrets.token_urlsafe(32), str(uuid.uuid4())
            previous = db.execute("SELECT id FROM clients WHERE hash=?", (digest(previous_token),)).fetchone() if previous_token else None
            if identity is not None:
                claimed = db.execute("SELECT client_id FROM client_devices WHERE installation_id=?", (identity[0],)).fetchone()
                if claimed and (previous is None or claimed[0] != previous[0]):
                    raise PairingConflict("Existing installation requires its current credential")
                if previous:
                    existing = db.execute("SELECT installation_id FROM client_devices WHERE client_id=?", (previous[0],)).fetchone()
                    if existing and existing[0] != identity[0]:
                        raise PairingConflict("Credential belongs to another installation")
                    client_id = previous[0]
                    db.execute("UPDATE clients SET hash=?,last_seen=0 WHERE id=?", (digest(credential), client_id))
                    db.execute("DELETE FROM push_devices WHERE client_id=?", (client_id,))
                else:
                    db.execute("INSERT INTO clients(id,hash,created) VALUES (?,?,?)", (client_id, digest(credential), now))
                db.execute("INSERT OR REPLACE INTO client_devices VALUES (?,?,?,?)", (client_id, *identity))
            else:
                db.execute("INSERT INTO clients(id,hash,created) VALUES (?,?,?)", (client_id, digest(credential), now))
            db.execute("DELETE FROM invitations WHERE hash=?", (digest(token),))
        return {"schema": 1, "sourceID": self.metadata("source_id"),
                "clientID": client_id, "credential": credential, "clientManagement": 1}

    def identify_client(self, credential, device):
        identity = device_identity(device)
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            client = db.execute("SELECT id FROM clients WHERE hash=?", (digest(credential),)).fetchone()
            if client is None:
                return False
            claimed = db.execute("SELECT client_id FROM client_devices WHERE installation_id=?", (identity[0],)).fetchone()
            existing = db.execute("SELECT installation_id FROM client_devices WHERE client_id=?", (client[0],)).fetchone()
            if (claimed and claimed[0] != client[0]) or (existing and existing[0] != identity[0]):
                raise PairingConflict("Installation is already identified")
            db.execute("INSERT OR REPLACE INTO client_devices VALUES (?,?,?,?)", (client[0], *identity))
        return True

    def client_fetched(self, credential):
        with self.connect() as db:
            db.execute("UPDATE clients SET last_seen=? WHERE hash=?", (time.time(), digest(credential)))

    def clients(self):
        with self.connect() as db:
            return self.client_list(db)

    @staticmethod
    def client_list(db):
        # Only non-secret presentation metadata crosses the local command boundary.
        modern = "last_seen" in {row[1] for row in db.execute("PRAGMA table_info(clients)")}
        query = ("SELECT c.id,c.created,c.last_seen,d.name,d.platform FROM clients c "
                 "LEFT JOIN client_devices d ON d.client_id=c.id ORDER BY c.created,c.id") if modern else (
                 "SELECT id,created,0,NULL,NULL FROM clients ORDER BY created,id")
        return [dict(zip(("id", "pairedAt", "lastContactAt", "name", "platform"), row)) for row in db.execute(
            query)]

    def authorized(self, token: str) -> bool:
        if not token:
            return False
        with self.connect() as db:
            return db.execute("SELECT 1 FROM clients WHERE hash=?", (digest(token),)).fetchone() is not None

    def revoke(self, client_id: str) -> bool:
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            db.execute("DELETE FROM push_devices WHERE client_id=?", (client_id,))
            db.execute("DELETE FROM client_devices WHERE client_id=?", (client_id,))
            return db.execute("DELETE FROM clients WHERE id=?", (client_id,)).rowcount > 0

    def revoke_self(self, credential):
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            client = db.execute("SELECT id FROM clients WHERE hash=?", (digest(credential),)).fetchone()
            if client is None:
                return False
            db.execute("DELETE FROM push_devices WHERE client_id=?", (client[0],))
            db.execute("DELETE FROM client_devices WHERE client_id=?", (client[0],))
            db.execute("DELETE FROM clients WHERE id=?", (client[0],))
            return True

    def push_device(self, credential: str, payload: dict | None = None, remove=False) -> dict | None:
        """The paired credential owns exactly one push destination; IDs aren't accepted from clients."""
        if payload is not None:
            if (not isinstance(payload, dict)
                    or not isinstance(payload.get("deviceToken"), str)
                    or not re.fullmatch(r"[0-9a-f]{32,512}", payload["deviceToken"])
                    or len(payload["deviceToken"]) % 2
                    or payload.get("environment") not in ("development", "production")
                    or payload.get("mode") not in ("alert", "background")):
                raise ValueError("Invalid push registration")
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            client = db.execute("SELECT id FROM clients WHERE hash=?", (digest(credential),)).fetchone()
            if not client:
                return None
            client_id = client[0]
            if remove:
                db.execute("DELETE FROM push_devices WHERE client_id=?", (client_id,))
            elif payload is not None:
                old = db.execute("SELECT * FROM push_devices WHERE client_id=?", (client_id,)).fetchone()
                values = (payload["deviceToken"], payload["environment"], payload["mode"])
                if old is None or tuple(old[k] for k in ("token", "environment", "mode")) != values:
                    revision = db.execute("SELECT MAX(seq) FROM events").fetchone()[0]
                    db.execute("INSERT OR REPLACE INTO push_devices(client_id,token,environment,mode,cursor) "
                               "VALUES (?,?,?,?,?)", (client_id, *values, revision))
            row = db.execute("SELECT * FROM push_devices WHERE client_id=?", (client_id,)).fetchone()
        if not row:
            return {"registered": False}
        return {"registered": True, "environment": row["environment"], "mode": row["mode"],
                "lastResult": row["last_result"], "lastAPNsID": row["last_apns_id"]}

    def emit(self, state: str, label: str = "Manual synthetic event") -> int:
        if state not in STATES:
            raise ValueError("Unknown activity state")
        with self.connect() as db:
            self.require_synthetic(db)
            return db.execute("INSERT INTO events(at,state,label) VALUES (?,?,?)",
                              (time.time(), state, label[:80])).lastrowid

    def tick(self, now: float | None = None):
        now = time.time() if now is None else now
        with self.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            mode = db.execute("SELECT value FROM metadata WHERE key='mode'").fetchone()
            if mode and mode[0] == "omarchy":
                return
            rows = db.execute("SELECT * FROM schedule WHERE fired=0 AND due<=? ORDER BY due,id", (now,)).fetchall()
            for row in rows:
                db.execute("INSERT INTO events(at,state,label) VALUES (?,?,?)",
                           (now, row["state"], "Scheduled synthetic event"))
                db.execute("UPDATE schedule SET fired=1 WHERE id=?", (row["id"],))

    def snapshot(self) -> dict:
        self.tick()
        with self.connect() as db:
            row = db.execute("SELECT * FROM events ORDER BY seq DESC LIMIT 1").fetchone()
        value = {"schema": 1, "sourceID": self.metadata("source_id"),
                "generation": self.metadata("generation"), "revision": row["seq"],
                "sourceName": "Transport test", "mode": "synthetic",
                "observedAt": time.time(), "changedAt": row["at"], "freshFor": 30,
                "state": row["state"], "eventID": str(row["seq"]),
                "sessions": [] if row["state"] == "idle" else [{
                    "id": "test-session", "provider": "fixture", "state": row["state"]}]}
        if row["payload"]:
            value.update(json.loads(row["payload"]))
        return value

    @staticmethod
    def require_synthetic(db):
        mode = db.execute("SELECT value FROM metadata WHERE key='mode'").fetchone()
        if mode and mode[0] == "omarchy":
            raise ValueError("Synthetic controls are disabled for an Omarchy source; use a separate data directory")


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, store: Store, adapter=None, desktop_status=None):
        self.store = store
        self.adapter = adapter
        self.desktop_status = desktop_status
        self.started = time.monotonic()
        self.pair_attempts: list[float] = []
        self.pair_lock = threading.Lock()
        super().__init__(address, Handler)

    def service_actions(self):
        # Scheduled events occur without a client request, essential for lock tests.
        self.store.tick()
        if self.adapter is not None:
            self.adapter.tick()
        if self.desktop_status is not None:
            self.desktop_status.publish(self.adapter)


class Handler(BaseHTTPRequestHandler):
    server: Server

    def setup(self):
        super().setup()
        self.connection.settimeout(5)

    def log_message(self, *_):
        # Request bodies, URLs, credentials, and invitation values never logged.
        pass

    def reply(self, status: int, payload: dict):
        data = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path not in ("/v1/snapshot", "/v1/events", "/v1/push"):
            self.reply(404, {"error": "not_found"})
            return
        prefix, _, token = self.headers.get("Authorization", "").partition(" ")
        if prefix != "Bearer" or not self.server.store.authorized(token):
            self.reply(401, {"error": "unauthorized"})
            return
        if self.path == "/v1/snapshot":
            self.reply(200, self.server.store.snapshot())
            self.server.store.client_fetched(token)
            if self.server.desktop_status is not None:
                self.server.desktop_status.phone_fetched()
            return
        if self.path == "/v1/push":
            value = self.server.store.push_device(token)
            self.reply(200 if value else 401, value or {"error": "unauthorized"})
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        last_revision, last_sent = None, 0.0
        try:
            while self.server.store.authorized(token):
                value = self.server.store.snapshot()
                if value["revision"] != last_revision or time.monotonic() - last_sent >= 15:
                    self.wfile.write(b"data: " + json.dumps(value, separators=(",", ":")).encode() + b"\n\n")
                    self.wfile.flush()
                    self.server.store.client_fetched(token)
                    if self.server.desktop_status is not None:
                        self.server.desktop_status.phone_fetched()
                    last_revision, last_sent = value["revision"], time.monotonic()
                time.sleep(0.25)
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass

    def do_POST(self):
        if self.path == "/v1/client":
            prefix, _, token = self.headers.get("Authorization", "").partition(" ")
            if prefix != "Bearer" or not self.server.store.authorized(token):
                self.reply(401, {"error": "unauthorized"})
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 4096 or self.headers.get("Transfer-Encoding"):
                    raise ValueError()
                payload = json.loads(self.rfile.read(length))
                accepted = self.server.store.identify_client(token, payload.get("device"))
                self.reply(200 if accepted else 401, {"clientManagement": 1} if accepted else {"error": "unauthorized"})
            except PairingConflict:
                self.reply(409, {"error": "installation_conflict"})
            except (ValueError, TypeError, AttributeError, TimeoutError):
                self.reply(400, {"error": "invalid_request"})
            return
        if self.path == "/v1/push":
            prefix, _, token = self.headers.get("Authorization", "").partition(" ")
            if prefix != "Bearer" or not self.server.store.authorized(token):
                self.reply(401, {"error": "unauthorized"})
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 4096 or self.headers.get("Transfer-Encoding"):
                    raise ValueError()
                value = self.server.store.push_device(token, json.loads(self.rfile.read(length)))
                self.reply(200 if value else 401, value or {"error": "unauthorized"})
            except (ValueError, AttributeError, TimeoutError):
                self.reply(400, {"error": "invalid_request"})
            return
        if self.path != "/v1/pair":
            self.reply(404, {"error": "not_found"})
            return
        # Global bounded pairing budget: an attacker cannot bypass it through proxy headers.
        with self.server.pair_lock:
            now = time.monotonic()
            self.server.pair_attempts = [t for t in self.server.pair_attempts if now-t < 60]
            if len(self.server.pair_attempts) >= 20:
                self.reply(429, {"error": "try_later"})
                return
            self.server.pair_attempts.append(now)
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= 4096 or self.headers.get("Transfer-Encoding"):
                raise ValueError()
            payload = json.loads(self.rfile.read(length))
            token = payload.get("invitation")
            if not isinstance(token, str) or not 20 <= len(token) <= 100:
                raise ValueError()
        except (ValueError, AttributeError, TimeoutError):
            self.reply(400, {"error": "invalid_request"})
            return
        prefix, _, previous = self.headers.get("Authorization", "").partition(" ")
        try:
            result = self.server.store.redeem(token, device=payload.get("device"),
                                              previous_token=previous if prefix == "Bearer" else "")
        except PairingConflict:
            self.reply(409, {"error": "installation_conflict"})
            return
        except (ValueError, TypeError, AttributeError):
            self.reply(400, {"error": "invalid_request"})
            return
        self.reply(200 if result else 401, result or {"error": "invitation_expired_or_used"})

    def do_DELETE(self):
        if self.path == "/v1/client":
            prefix, _, token = self.headers.get("Authorization", "").partition(" ")
            revoked = self.server.store.revoke_self(token) if prefix == "Bearer" else False
            self.reply(200 if revoked else 401, {"revoked": True} if revoked else {"error": "unauthorized"})
            return
        if self.path != "/v1/push":
            self.reply(404, {"error": "not_found"})
            return
        prefix, _, token = self.headers.get("Authorization", "").partition(" ")
        value = self.server.store.push_device(token, remove=True) if prefix == "Bearer" else None
        self.reply(200 if value else 401, value or {"error": "unauthorized"})


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", type=Path, default=Path(".runtime"))
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("serve")
    run.add_argument("--port", type=int, default=8765)
    run.add_argument("--source", choices=("synthetic", "omarchy"), default="synthetic")
    run.add_argument("--status-file", type=Path, help="Private desktop status JSON (optional)")
    run.add_argument("--agent-socket", type=Path,
                     help="Omarchy event socket (default: $XDG_RUNTIME_DIR/omarchy-watch.sock)")
    run.add_argument("--omarchy-state", type=Path,
                     help="Omarchy state directory (default: $XDG_STATE_HOME/omarchy)")
    invitation = sub.add_parser("invite")
    invitation.add_argument("--endpoint", required=True)
    invitation.add_argument("--output", type=Path, default=Path(".runtime/invitation.json"))
    emit = sub.add_parser("emit")
    emit.add_argument("state", choices=sorted(STATES))
    schedule = sub.add_parser("schedule")
    schedule.add_argument("--delay", type=int, default=900)
    schedule.add_argument("--interval", type=int, default=360)
    schedule.add_argument("--count", type=int, default=10)
    sub.add_parser("clients")
    revoke = sub.add_parser("revoke")
    revoke.add_argument("client_id")
    sub.add_parser("events")
    sub.add_parser("cancel-schedule")
    args = parser.parse_args()
    store = Store(args.data_dir / "hub.sqlite3")
    if args.command == "serve":
        from contextlib import ExitStack
        with ExitStack() as stack:
            lock = stack.enter_context((args.data_dir / "source.lock").open("a"))
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                parser.error("A source is already running for this data directory")
            server = stack.enter_context(Server(("127.0.0.1", args.port), store))
            if args.source == "omarchy":
                from service.omarchy import OmarchySource
                try:
                    server.adapter = stack.enter_context(OmarchySource(
                        store, socket_path=args.agent_socket, state_dir=args.omarchy_state))
                except (OSError, ValueError) as error:
                    parser.error(str(error))
            else:
                with store.connect() as db:
                    try:
                        store.require_synthetic(db)
                    except ValueError as error:
                        parser.error(str(error))
            if args.status_file:
                from service.status import DesktopStatus
                server.desktop_status = DesktopStatus(args.status_file, store)
                server.desktop_status.publish(server.adapter, force=True)
                stack.callback(server.desktop_status.publish, server.adapter, stopped=True, force=True)
            print(f"{args.source.title()} source listening on 127.0.0.1:{server.server_port}", flush=True)
            try:
                server.serve_forever(poll_interval=0.25)
            except KeyboardInterrupt:
                pass
    elif args.command == "invite":
        value = store.invite(args.endpoint)
        args.output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as file:
            json.dump(value, file, separators=(",", ":"))
        print(f"Five-minute invitation saved to {args.output}. Treat it as a pairing secret.")
    elif args.command == "emit":
        try:
            print(f"Synthetic event {store.emit(args.state)}: {args.state}")
        except ValueError as error:
            parser.error(str(error))
    elif args.command == "schedule":
        if args.delay < 0 or args.interval < 5 or not 1 <= args.count <= 100:
            parser.error("delay >= 0, interval >= 5, count 1..100 required")
        with store.connect() as db:
            try:
                store.require_synthetic(db)
            except ValueError as error:
                parser.error(str(error))
            db.execute("DELETE FROM schedule WHERE fired=0")
            sequence = ["working", "needs_input", "working", "finished", "idle"]
            db.executemany("INSERT INTO schedule(due,state) VALUES (?,?)", [
                (time.time() + args.delay + i * args.interval, sequence[i % 5])
                for i in range(args.count)])
        print(f"Scheduled {args.count} synthetic transitions; first in {args.delay}s.")
    elif args.command == "clients":
        with store.connect() as db:
            for row in db.execute("SELECT id,created FROM clients"):
                print(dict(row))
    elif args.command == "revoke":
        print("Revoked" if store.revoke(args.client_id) else "Client not found")
    elif args.command == "events":
        with store.connect() as db:
            for row in db.execute("SELECT * FROM events ORDER BY seq"):
                print(json.dumps(dict(row)))
    elif args.command == "cancel-schedule":
        with store.connect() as db:
            db.execute("DELETE FROM schedule WHERE fired=0")
        print("Pending synthetic events cancelled")


if __name__ == "__main__":
    main()
