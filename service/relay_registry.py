"""Persistent source, paired-client, and APNs destination authorization.

The production DSN is PostgreSQL. SQLite is used only by focused local tests.
APNs tokens and bearer credentials are stored as SHA-256 digests.
"""
from __future__ import annotations

from contextlib import contextmanager
import hashlib
import hmac
import re
import sqlite3
import time
import uuid


SCHEMA = (
    "CREATE TABLE IF NOT EXISTS relay_sources ("
    "id TEXT PRIMARY KEY, credential_hash TEXT NOT NULL, created_at DOUBLE PRECISION NOT NULL)",
    "CREATE TABLE IF NOT EXISTS relay_revoked_sources (id TEXT PRIMARY KEY)",
    "CREATE TABLE IF NOT EXISTS relay_clients ("
    "source_id TEXT NOT NULL REFERENCES relay_sources(id) ON DELETE CASCADE, "
    "id TEXT NOT NULL, credential_hash TEXT NOT NULL, PRIMARY KEY (source_id,id))",
    "CREATE TABLE IF NOT EXISTS relay_destinations ("
    "source_id TEXT NOT NULL, client_id TEXT NOT NULL, mode TEXT NOT NULL, "
    "activity_id TEXT NOT NULL DEFAULT '', token_hash TEXT NOT NULL, environment TEXT NOT NULL, "
    "PRIMARY KEY (source_id,client_id,mode,activity_id), "
    "FOREIGN KEY (source_id,client_id) REFERENCES relay_clients(source_id,id) ON DELETE CASCADE)",
    "CREATE TABLE IF NOT EXISTS relay_send_limits ("
    "source_id TEXT PRIMARY KEY REFERENCES relay_sources(id) ON DELETE CASCADE, "
    "window_start BIGINT NOT NULL, sent INTEGER NOT NULL)",
    "CREATE TABLE IF NOT EXISTS relay_global_send_limit ("
    "id INTEGER PRIMARY KEY, window_start BIGINT NOT NULL, sent INTEGER NOT NULL)",
)


def digest(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def valid_uuid(value: object) -> bool:
    if not isinstance(value, str):
        return False
    try:
        return str(uuid.UUID(value)) == value
    except ValueError:
        return False


def valid_token(value: object) -> bool:
    return isinstance(value, str) and re.fullmatch(r"(?:[0-9a-f]{2}){16,256}", value) is not None


class Registry:
    def __init__(self, dsn: str):
        if not (dsn.startswith("postgres://") or dsn.startswith("postgresql://")
                or dsn.startswith("sqlite:///")):
            raise ValueError("DATABASE_URL must be PostgreSQL")
        self.dsn = dsn
        with self.connection() as db:
            for statement in SCHEMA:
                db.execute(statement)

    @contextmanager
    def connection(self):
        if self.dsn.startswith("sqlite:///"):
            db = sqlite3.connect(self.dsn.removeprefix("sqlite:///"), timeout=5)
            db.execute("PRAGMA foreign_keys=ON")
        else:
            import psycopg
            db = psycopg.connect(self.dsn)
        try:
            with db:
                yield _Queries(db, isinstance(db, sqlite3.Connection))
        finally:
            db.close()

    def create_source(self, source_id: str, credential: str, now: float | None = None) -> bool:
        if not valid_uuid(source_id) or not re.fullmatch(r"[A-Za-z0-9_-]{43,128}", credential):
            raise ValueError("Invalid source registration")
        with self.connection() as db:
            if db.one("SELECT 1 FROM relay_revoked_sources WHERE id=?", (source_id,)):
                return False
            existing = db.one("SELECT credential_hash FROM relay_sources WHERE id=?", (source_id,))
            if existing:
                return hmac.compare_digest(existing[0], digest(credential))
            if (db.one("SELECT COUNT(*) FROM relay_sources")[0]
                    + db.one("SELECT COUNT(*) FROM relay_revoked_sources")[0] >= 10_000):
                return False
            db.execute("INSERT INTO relay_sources VALUES (?,?,?) ON CONFLICT(id) DO NOTHING",
                       (source_id, digest(credential), time.time() if now is None else now))
            existing = db.one("SELECT credential_hash FROM relay_sources WHERE id=?", (source_id,))
            return bool(existing and hmac.compare_digest(existing[0], digest(credential)))

    def source_authorized(self, source_id: str, credential: str) -> bool:
        if not valid_uuid(source_id) or not credential:
            return False
        with self.connection() as db:
            existing = db.one("SELECT credential_hash FROM relay_sources WHERE id=?", (source_id,))
        return bool(existing and hmac.compare_digest(existing[0], digest(credential)))

    def sync_clients(self, source_id: str, clients: list[dict]) -> None:
        if (not isinstance(clients, list) or len(clients) > 100
                or any(not isinstance(c, dict) or set(c) != {"clientID", "credentialHash"}
                       or not valid_uuid(c["clientID"])
                       or not isinstance(c["credentialHash"], str)
                       or not re.fullmatch(r"[0-9a-f]{64}", c["credentialHash"])
                       for c in clients)
                or len({c["clientID"] for c in clients}) != len(clients)):
            raise ValueError("Invalid client list")
        with self.connection() as db:
            current = dict(db.all("SELECT id,credential_hash FROM relay_clients WHERE source_id=?", (source_id,)))
            incoming = {c["clientID"]: c["credentialHash"] for c in clients}
            for client_id in current.keys() - incoming.keys():
                db.execute("DELETE FROM relay_clients WHERE source_id=? AND id=?", (source_id, client_id))
            for client_id, credential_hash in incoming.items():
                if current.get(client_id) != credential_hash:
                    # A credential rotation invalidates every old token binding.
                    db.execute("DELETE FROM relay_clients WHERE source_id=? AND id=?", (source_id, client_id))
                    db.execute("INSERT INTO relay_clients VALUES (?,?,?)", (source_id, client_id, credential_hash))

    def client_authorized(self, source_id: str, client_id: str, credential: str) -> bool:
        if not valid_uuid(source_id) or not valid_uuid(client_id) or not credential:
            return False
        with self.connection() as db:
            existing = db.one("SELECT credential_hash FROM relay_clients WHERE source_id=? AND id=?",
                              (source_id, client_id))
        return bool(existing and hmac.compare_digest(existing[0], digest(credential)))

    def delete_client(self, source_id: str, client_id: str) -> None:
        with self.connection() as db:
            db.execute("DELETE FROM relay_clients WHERE source_id=? AND id=?", (source_id, client_id))

    def bind(self, source_id: str, client_id: str, mode: str, activity_id: str,
             token: str, environment: str) -> None:
        if (mode not in ("alert", "watch", "liveactivity") or not valid_token(token)
                or environment not in ("development", "production")
                or not isinstance(activity_id, str) or len(activity_id) > 128
                or (mode != "liveactivity" and activity_id)):
            raise ValueError("Invalid destination")
        with self.connection() as db:
            db.execute("DELETE FROM relay_destinations WHERE source_id=? AND client_id=? AND mode=? AND activity_id=?",
                       (source_id, client_id, mode, activity_id))
            db.execute("INSERT INTO relay_destinations VALUES (?,?,?,?,?,?)",
                       (source_id, client_id, mode, activity_id, digest(token), environment))

    def unbind(self, source_id: str, client_id: str, mode: str, activity_id: str = "") -> None:
        if mode not in ("alert", "watch", "liveactivity") or not isinstance(activity_id, str):
            raise ValueError("Invalid destination")
        with self.connection() as db:
            db.execute("DELETE FROM relay_destinations WHERE source_id=? AND client_id=? AND mode=? AND activity_id=?",
                       (source_id, client_id, mode, activity_id))

    def allowed(self, source_id: str, client_id: str, mode: str, token: str,
                environment: str, activity_id: str = "") -> bool:
        if not valid_uuid(source_id) or not valid_uuid(client_id) or not valid_token(token):
            return False
        with self.connection() as db:
            rows = db.all("SELECT token_hash FROM relay_destinations WHERE source_id=? AND client_id=? "
                          "AND mode=? AND environment=? AND activity_id=?",
                          (source_id, client_id, mode, environment, activity_id))
        return any(hmac.compare_digest(row[0], digest(token)) for row in rows)

    def delete_source(self, source_id: str) -> None:
        with self.connection() as db:
            # Keep the identity denied after a still-running Mac retries enrollment.
            db.execute("INSERT INTO relay_revoked_sources(id) VALUES (?) ON CONFLICT(id) DO NOTHING",
                       (source_id,))
            db.execute("DELETE FROM relay_sources WHERE id=?", (source_id,))

    def take_send_slot(self, source_id: str, now: float, per_minute: int = 120,
                       global_per_minute: int = 3000) -> bool:
        window = int(now // 60)
        with self.connection() as db:
            db.execute("INSERT INTO relay_send_limits(source_id,window_start,sent) VALUES (?,?,1) "
                       "ON CONFLICT(source_id) DO UPDATE SET "
                       "window_start=excluded.window_start, "
                       "sent=CASE WHEN relay_send_limits.window_start=excluded.window_start "
                       "THEN relay_send_limits.sent+1 ELSE 1 END", (source_id, window))
            sent = db.one("SELECT sent FROM relay_send_limits WHERE source_id=?", (source_id,))[0]
            if sent > per_minute:
                return False
            db.execute("INSERT INTO relay_global_send_limit(id,window_start,sent) VALUES (1,?,1) "
                       "ON CONFLICT(id) DO UPDATE SET "
                       "window_start=excluded.window_start, "
                       "sent=CASE WHEN relay_global_send_limit.window_start=excluded.window_start "
                       "THEN relay_global_send_limit.sent+1 ELSE 1 END", (window,))
            total = db.one("SELECT sent FROM relay_global_send_limit WHERE id=1")[0]
        return total <= global_per_minute


class _Queries:
    def __init__(self, connection, sqlite: bool):
        self.connection, self.sqlite = connection, sqlite

    def execute(self, statement: str, parameters: tuple = ()):
        if not self.sqlite:
            statement = statement.replace("?", "%s")
        return self.connection.execute(statement, parameters)

    def one(self, statement: str, parameters: tuple = ()):
        return self.execute(statement, parameters).fetchone()

    def all(self, statement: str, parameters: tuple = ()):
        return self.execute(statement, parameters).fetchall()
