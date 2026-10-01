"""Persistent source, paired-client, and APNs destination authorization.

The production DSN is PostgreSQL. SQLite is used only by focused local tests.
APNs tokens and bearer credentials are stored as SHA-256 digests.
"""
from __future__ import annotations

from contextlib import contextmanager
import base64
import binascii
import hashlib
import hmac
import json
import logging
import os
import re
import secrets
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
    "CREATE TABLE IF NOT EXISTS relay_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
    "CREATE TABLE IF NOT EXISTS relay_attest_keys ("
    "id TEXT PRIMARY KEY, environment TEXT NOT NULL, public_key TEXT NOT NULL, "
    "counter BIGINT NOT NULL, created_at DOUBLE PRECISION NOT NULL)",
    "CREATE TABLE IF NOT EXISTS relay_activation_claims ("
    "source_id TEXT PRIMARY KEY, credential_hash TEXT NOT NULL, key_id TEXT NOT NULL "
    "REFERENCES relay_attest_keys(id), expires_at DOUBLE PRECISION NOT NULL)",
    "CREATE TABLE IF NOT EXISTS relay_attest_sources ("
    "key_id TEXT NOT NULL REFERENCES relay_attest_keys(id), source_id TEXT NOT NULL, "
    "created_at DOUBLE PRECISION NOT NULL, PRIMARY KEY(key_id,source_id))",
    "CREATE TABLE IF NOT EXISTS relay_used_challenges ("
    "challenge_hash TEXT PRIMARY KEY, expires_at DOUBLE PRECISION NOT NULL)",
    "CREATE TABLE IF NOT EXISTS relay_daily_enrollment ("
    "day BIGINT PRIMARY KEY, registered INTEGER NOT NULL)",
)


def digest(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def base64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode().rstrip("=")


def base64decode(value: str) -> bytes:
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", value):
        raise ValueError("Invalid base64url value")
    try:
        decoded = base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
    except binascii.Error as error:
        raise ValueError("Invalid base64url value") from error
    if base64url(decoded) != value:
        raise ValueError("Invalid base64url value")
    return decoded


def valid_uuid(value: object) -> bool:
    if not isinstance(value, str):
        return False
    try:
        return str(uuid.UUID(value)) == value
    except ValueError:
        return False


def valid_token(value: object) -> bool:
    return isinstance(value, str) and re.fullmatch(r"(?:[0-9a-f]{2}){16,256}", value) is not None


class EnrollmentLimited(PermissionError):
    pass


class Registry:
    def __init__(self, dsn: str):
        if not (dsn.startswith("postgres://") or dsn.startswith("postgresql://")
                or dsn.startswith("sqlite:///")):
            raise ValueError("DATABASE_URL must be PostgreSQL")
        self.max_sources_per_key = int(os.environ.get("PACEMAN_MAX_SOURCES_PER_ATTEST_KEY", "20"))
        self.daily_enrollment_limit = int(os.environ.get("PACEMAN_DAILY_ENROLLMENT_LIMIT", "500"))
        if not (1 <= self.max_sources_per_key <= 10_000
                and 1 <= self.daily_enrollment_limit <= 10_000):
            raise ValueError("Invalid relay enrollment limits")
        self.dsn = dsn
        with self.connection() as db:
            for statement in SCHEMA:
                db.execute(statement)
            db.execute("INSERT INTO relay_metadata(key,value) VALUES ('challenge_key',?) "
                       "ON CONFLICT(key) DO NOTHING", (secrets.token_hex(32),))
            self.challenge_key = bytes.fromhex(db.one(
                "SELECT value FROM relay_metadata WHERE key='challenge_key'")[0])

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

    def check_database(self) -> None:
        """Check that the registry can serve queries without changing stored data."""
        with self.connection() as db:
            if db.one("SELECT 1") != (1,):
                raise RuntimeError("Relay database probe returned an unexpected result")

    def create_source(self, source_id: str, credential: str, now: float | None = None,
                      *, legacy: bool = False) -> bool:
        if not valid_uuid(source_id) or not re.fullmatch(r"[A-Za-z0-9_-]{43,128}", credential):
            raise ValueError("Invalid source registration")
        now = time.time() if now is None else now
        with self.connection() as db:
            if db.one("SELECT 1 FROM relay_revoked_sources WHERE id=?", (source_id,)):
                return False
            existing = db.one("SELECT credential_hash FROM relay_sources WHERE id=?", (source_id,))
            if existing:
                return hmac.compare_digest(existing[0], digest(credential))
            if (db.one("SELECT COUNT(*) FROM relay_sources")[0]
                    + db.one("SELECT COUNT(*) FROM relay_revoked_sources")[0] >= 10_000):
                return False
            if not legacy:
                claim = db.one("SELECT credential_hash,key_id,expires_at FROM relay_activation_claims "
                               "WHERE source_id=?", (source_id,))
                if (claim is None or claim[2] <= now
                        or not hmac.compare_digest(claim[0], digest(credential))):
                    raise PermissionError("A paired Paceman iPhone must approve this source")
                if db.one("SELECT COUNT(*) FROM relay_attest_sources WHERE key_id=?", (claim[1],))[0] >= self.max_sources_per_key:
                    raise EnrollmentLimited("Too many sources for one app instance")
                day = int(now // 86400)
                db.execute("DELETE FROM relay_daily_enrollment WHERE day<?", (day - 7,))
                db.execute("INSERT INTO relay_daily_enrollment(day,registered) VALUES (?,1) "
                           "ON CONFLICT(day) DO UPDATE SET registered=relay_daily_enrollment.registered+1",
                           (day,))
                if db.one("SELECT registered FROM relay_daily_enrollment WHERE day=?", (day,))[0] > self.daily_enrollment_limit:
                    raise EnrollmentLimited("Relay enrollment budget reached")
            added = db.execute("INSERT INTO relay_sources VALUES (?,?,?) ON CONFLICT(id) DO NOTHING",
                               (source_id, digest(credential), now))
            if not legacy:
                db.execute("INSERT INTO relay_attest_sources VALUES (?,?,?) "
                           "ON CONFLICT(key_id,source_id) DO NOTHING", (claim[1], source_id, now))
                db.execute("DELETE FROM relay_activation_claims WHERE source_id=?", (source_id,))
                if added.rowcount == 1:
                    logging.getLogger("paceman.relay").info("source_enrollment_accepted")
            existing = db.one("SELECT credential_hash FROM relay_sources WHERE id=?", (source_id,))
            return bool(existing and hmac.compare_digest(existing[0], digest(credential)))

    @staticmethod
    def _valid_claim(source_id: str, credential_hash: str, key_id: str, environment: str) -> bool:
        return (valid_uuid(source_id) and isinstance(credential_hash, str)
                and re.fullmatch(r"[0-9a-f]{64}", credential_hash) is not None
                and isinstance(key_id, str) and re.fullmatch(r"[A-Za-z0-9_-]{43}", key_id) is not None
                and environment in ("development", "production"))

    def challenge(self, source_id: str, credential_hash: str, key_id: str,
                  environment: str, now: float | None = None) -> tuple[str, str]:
        if not self._valid_claim(source_id, credential_hash, key_id, environment):
            raise ValueError("Invalid activation request")
        now = time.time() if now is None else now
        with self.connection() as db:
            existing = db.one("SELECT environment FROM relay_attest_keys WHERE id=?", (key_id,))
        if existing and existing[0] != environment:
            raise ValueError("App Attest key environment mismatch")
        kind = "assert" if existing else "attest"
        value = [1, kind, source_id, credential_hash, key_id, environment,
                 int(now) + 300, secrets.token_urlsafe(24)]
        encoded = json.dumps(value, separators=(",", ":")).encode()
        body = base64url(encoded)
        signature = base64url(hmac.new(self.challenge_key, body.encode(), hashlib.sha256).digest())
        return kind, body + "." + signature

    def _validate_challenge(self, challenge: str, kind: str, source_id: str,
                            credential_hash: str, key_id: str, environment: str, now: float) -> int:
        if not isinstance(challenge, str) or len(challenge) > 512 or challenge.count(".") != 1:
            raise ValueError("Invalid challenge")
        body, signature = challenge.split(".")
        expected = base64url(hmac.new(self.challenge_key, body.encode(), hashlib.sha256).digest())
        if not hmac.compare_digest(signature, expected):
            raise ValueError("Invalid challenge")
        try:
            value = json.loads(base64decode(body))
        except (ValueError, UnicodeDecodeError) as error:
            raise ValueError("Invalid challenge") from error
        if (not isinstance(value, list) or len(value) != 8 or value[:6] !=
                [1, kind, source_id, credential_hash, key_id, environment]
                or type(value[6]) is not int or not now < value[6] <= now + 300):
            raise ValueError("Expired or mismatched challenge")
        return value[6]

    def _consume_challenge(self, db, challenge: str, expires_at: int, now: float) -> None:
        db.execute("DELETE FROM relay_used_challenges WHERE expires_at<=?", (now,))
        added = db.execute("INSERT INTO relay_used_challenges VALUES (?,?) "
                           "ON CONFLICT(challenge_hash) DO NOTHING",
                           (digest(challenge), expires_at))
        if added.rowcount != 1:
            raise ValueError("Replayed challenge")

    def attest_key(self, source_id: str, credential_hash: str, key_id: str,
                   environment: str, kind: str, challenge: str, proof: str,
                   verifier, now: float | None = None) -> None:
        if not self._valid_claim(source_id, credential_hash, key_id, environment) or kind not in ("attest", "assert"):
            raise ValueError("Invalid activation request")
        now = time.time() if now is None else now
        expires_at = self._validate_challenge(challenge, kind, source_id, credential_hash,
                                              key_id, environment, now)
        with self.connection() as db:
            existing = db.one("SELECT environment,public_key,counter FROM relay_attest_keys WHERE id=?", (key_id,))
        if kind == "attest" and existing is None:
            public_key = verifier.attest(proof, key_id, challenge, environment)
            counter = 0
        elif kind == "assert" and existing and existing[0] == environment:
            public_key = base64decode(existing[1])
            counter = verifier.assert_key(proof, public_key, challenge, environment, existing[2])
        else:
            raise ValueError("App Attest key state changed")
        with self.connection() as db:
            self._consume_challenge(db, challenge, expires_at, now)
            db.execute("DELETE FROM relay_activation_claims WHERE expires_at<=?", (now,))
            if kind == "attest":
                inserted = db.execute("INSERT INTO relay_attest_keys VALUES (?,?,?,?,?) "
                                      "ON CONFLICT(id) DO NOTHING",
                                      (key_id, environment, base64url(public_key), 0, now))
                if inserted.rowcount != 1:
                    raise ValueError("App Attest key already registered")
            else:
                updated = db.execute("UPDATE relay_attest_keys SET counter=? WHERE id=? AND counter=?",
                                     (counter, key_id, existing[2]))
                if updated.rowcount != 1:
                    raise ValueError("Replayed App Attest assertion")
            db.execute("INSERT INTO relay_activation_claims VALUES (?,?,?,?) "
                       "ON CONFLICT(source_id) DO UPDATE SET "
                       "credential_hash=excluded.credential_hash,key_id=excluded.key_id,"
                       "expires_at=excluded.expires_at",
                       (source_id, credential_hash, key_id, now + 900))

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
            db.execute("DELETE FROM relay_activation_claims WHERE source_id=?", (source_id,))
            db.execute("DELETE FROM relay_attest_sources WHERE source_id=?", (source_id,))
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
