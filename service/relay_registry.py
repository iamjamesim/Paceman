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
    "CREATE TABLE IF NOT EXISTS relay_send_limits ("
    "source_id TEXT PRIMARY KEY REFERENCES relay_sources(id) ON DELETE CASCADE, "
    "window_start BIGINT NOT NULL, sent INTEGER NOT NULL)",
    "CREATE TABLE IF NOT EXISTS relay_global_send_limit ("
    "id INTEGER PRIMARY KEY, window_start BIGINT NOT NULL, sent INTEGER NOT NULL)",
    "CREATE TABLE IF NOT EXISTS relay_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
    "CREATE TABLE IF NOT EXISTS relay_attest_keys ("
    "id TEXT PRIMARY KEY, environment TEXT NOT NULL, public_key TEXT NOT NULL, "
    "counter BIGINT NOT NULL, created_at DOUBLE PRECISION NOT NULL)",
    "CREATE TABLE IF NOT EXISTS relay_attest_sources ("
    "key_id TEXT NOT NULL REFERENCES relay_attest_keys(id), source_id TEXT NOT NULL, "
    "created_at DOUBLE PRECISION NOT NULL, PRIMARY KEY(key_id,source_id))",
    "CREATE TABLE IF NOT EXISTS relay_used_challenges ("
    "challenge_hash TEXT PRIMARY KEY, expires_at DOUBLE PRECISION NOT NULL)",
    "CREATE TABLE IF NOT EXISTS relay_daily_enrollment ("
    "day BIGINT PRIMARY KEY, registered INTEGER NOT NULL)",
    "CREATE TABLE IF NOT EXISTS relay_approvals ("
    "source_id TEXT NOT NULL, source_hash TEXT NOT NULL, client_id TEXT NOT NULL, "
    "client_hash TEXT NOT NULL, key_id TEXT NOT NULL REFERENCES relay_attest_keys(id), "
    "created_at DOUBLE PRECISION NOT NULL, "
    "PRIMARY KEY(source_id,source_hash,client_id,client_hash))",
    "CREATE TABLE IF NOT EXISTS relay_approved_destinations ("
    "source_id TEXT NOT NULL, source_hash TEXT NOT NULL, client_id TEXT NOT NULL, "
    "client_hash TEXT NOT NULL, mode TEXT NOT NULL, activity_id TEXT NOT NULL DEFAULT '', "
    "token_hash TEXT NOT NULL, environment TEXT NOT NULL, expires_at DOUBLE PRECISION NOT NULL DEFAULT 0, "
    "PRIMARY KEY(source_id,source_hash,client_id,client_hash,mode,activity_id,token_hash), "
    "FOREIGN KEY(source_id,source_hash,client_id,client_hash) "
    "REFERENCES relay_approvals(source_id,source_hash,client_id,client_hash) ON DELETE CASCADE)",
    "CREATE TABLE IF NOT EXISTS relay_revoked_clients ("
    "source_id TEXT NOT NULL, source_hash TEXT NOT NULL, client_id TEXT NOT NULL, "
    "client_hash TEXT NOT NULL, PRIMARY KEY(source_id,source_hash,client_id,client_hash))",
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

    @staticmethod
    def _valid_claim(source_id: str, credential_hash: str, key_id: str, environment: str) -> bool:
        return (valid_uuid(source_id) and isinstance(credential_hash, str)
                and re.fullmatch(r"[0-9a-f]{64}", credential_hash) is not None
                and isinstance(key_id, str) and re.fullmatch(r"[A-Za-z0-9_-]{43}", key_id) is not None
                and environment in ("development", "production"))

    def _consume_challenge(self, db, challenge: str, expires_at: int, now: float) -> None:
        db.execute("DELETE FROM relay_used_challenges WHERE expires_at<=?", (now,))
        added = db.execute("INSERT INTO relay_used_challenges VALUES (?,?) "
                           "ON CONFLICT(challenge_hash) DO NOTHING",
                           (digest(challenge), expires_at))
        if added.rowcount != 1:
            raise ValueError("Replayed challenge")

    @staticmethod
    def _valid_pair(source_id: str, source_hash: str, client_id: str,
                    client_hash: str, key_id: str, environment: str) -> bool:
        return (Registry._valid_claim(source_id, source_hash, key_id, environment)
                and valid_uuid(client_id) and isinstance(client_hash, str)
                and re.fullmatch(r"[0-9a-f]{64}", client_hash) is not None)

    def pairing_challenge(self, source_id: str, source_hash: str, client_id: str,
                          client_hash: str, key_id: str, environment: str,
                          now: float | None = None) -> tuple[str, str]:
        if not self._valid_pair(source_id, source_hash, client_id, client_hash, key_id, environment):
            raise ValueError("Invalid pairing approval")
        now = time.time() if now is None else now
        with self.connection() as db:
            existing = db.one("SELECT environment FROM relay_attest_keys WHERE id=?", (key_id,))
        if existing and existing[0] != environment:
            raise ValueError("App Attest key environment mismatch")
        kind = "assert" if existing else "attest"
        value = [2, kind, source_id, source_hash, client_id, client_hash,
                 key_id, environment, int(now) + 300, secrets.token_urlsafe(24)]
        body = base64url(json.dumps(value, separators=(",", ":")).encode())
        signature = base64url(hmac.new(self.challenge_key, body.encode(), hashlib.sha256).digest())
        return kind, body + "." + signature

    def approve_pairing(self, source_id: str, source_hash: str, client_id: str,
                        client_hash: str, key_id: str, environment: str, kind: str,
                        challenge: str, proof: str, verifier, now: float | None = None) -> None:
        if not self._valid_pair(source_id, source_hash, client_id, client_hash, key_id, environment):
            raise ValueError("Invalid pairing approval")
        now = time.time() if now is None else now
        if kind not in ("attest", "assert") or not isinstance(challenge, str) or challenge.count(".") != 1:
            raise ValueError("Invalid challenge")
        body, signature = challenge.split(".")
        if len(challenge) > 768 or not hmac.compare_digest(
                signature, base64url(hmac.new(self.challenge_key, body.encode(), hashlib.sha256).digest())):
            raise ValueError("Invalid challenge")
        try:
            value = json.loads(base64decode(body))
        except (ValueError, UnicodeDecodeError) as error:
            raise ValueError("Invalid challenge") from error
        expected = [2, kind, source_id, source_hash, client_id, client_hash, key_id, environment]
        if (not isinstance(value, list) or len(value) != 10 or value[:8] != expected
                or type(value[8]) is not int or not now < value[8] <= now + 300):
            raise ValueError("Expired or mismatched challenge")
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
            self._consume_challenge(db, challenge, value[8], now)
            db.execute("DELETE FROM relay_approvals WHERE created_at<? "
                       "AND source_id NOT IN (SELECT id FROM relay_sources)", (now - 7 * 86400,))
            db.execute("DELETE FROM relay_attest_sources WHERE source_id NOT IN "
                       "(SELECT id FROM relay_sources) AND source_id NOT IN "
                       "(SELECT source_id FROM relay_approvals)")
            if db.one("SELECT 1 FROM relay_revoked_sources WHERE id=?", (source_id,)) or db.one(
                    "SELECT 1 FROM relay_revoked_clients WHERE source_id=? AND source_hash=? "
                    "AND client_id=? AND client_hash=?", (source_id, source_hash, client_id, client_hash)):
                raise PermissionError("Pairing was revoked")
            active = db.one("SELECT credential_hash FROM relay_sources WHERE id=?", (source_id,))
            if active and not hmac.compare_digest(active[0], source_hash):
                raise PermissionError("Source credential mismatch")
            old_approval = db.one("SELECT 1 FROM relay_approvals WHERE source_id=? AND source_hash=? "
                                  "AND client_id=? AND client_hash=?",
                                  (source_id, source_hash, client_id, client_hash))
            new_source_for_key = not db.one("SELECT 1 FROM relay_attest_sources WHERE key_id=? AND source_id=?",
                                            (key_id, source_id))
            if new_source_for_key:
                if db.one("SELECT COUNT(*) FROM relay_attest_sources WHERE key_id=?", (key_id,))[0] >= self.max_sources_per_key:
                    raise EnrollmentLimited("Too many sources for one app instance")
                day = int(now // 86400)
                db.execute("DELETE FROM relay_daily_enrollment WHERE day<?", (day - 7,))
                db.execute("INSERT INTO relay_daily_enrollment(day,registered) VALUES (?,1) "
                           "ON CONFLICT(day) DO UPDATE SET registered=relay_daily_enrollment.registered+1", (day,))
                if db.one("SELECT registered FROM relay_daily_enrollment WHERE day=?", (day,))[0] > self.daily_enrollment_limit:
                    raise EnrollmentLimited("Relay enrollment budget reached")
            if not old_approval and db.one("SELECT COUNT(*) FROM relay_approvals WHERE source_id=? AND source_hash=?",
                                           (source_id, source_hash))[0] >= 100:
                raise EnrollmentLimited("Too many paired clients")
            if not old_approval and db.one("SELECT COUNT(*) FROM relay_approvals")[0] >= 20_000:
                raise EnrollmentLimited("Relay approval budget reached")
            if kind == "attest":
                inserted = db.execute("INSERT INTO relay_attest_keys VALUES (?,?,?,?,?) ON CONFLICT(id) DO NOTHING",
                                      (key_id, environment, base64url(public_key), 0, now))
                if inserted.rowcount != 1:
                    raise ValueError("App Attest key already registered")
            else:
                updated = db.execute("UPDATE relay_attest_keys SET counter=? WHERE id=? AND counter=?",
                                     (counter, key_id, existing[2]))
                if updated.rowcount != 1:
                    raise ValueError("Replayed App Attest assertion")
            db.execute("INSERT INTO relay_attest_sources VALUES (?,?,?) ON CONFLICT(key_id,source_id) DO NOTHING",
                       (key_id, source_id, now))
            db.execute("INSERT INTO relay_approvals VALUES (?,?,?,?,?,?) ON CONFLICT DO NOTHING",
                       (source_id, source_hash, client_id, client_hash, key_id, now))

    def bind_approved(self, source_id: str, source_hash: str, client_id: str,
                      credential: str, mode: str, activity_id: str, token_hash: str,
                      environment: str, now: float) -> bool:
        if (mode not in ("alert", "watch", "liveactivity") or environment not in ("development", "production")
                or not isinstance(token_hash, str) or re.fullmatch(r"[0-9a-f]{64}", token_hash) is None
                or not isinstance(activity_id, str) or len(activity_id) > 128
                or (mode != "liveactivity" and activity_id)):
            raise ValueError("Invalid destination")
        client_hash = digest(credential)
        with self.connection() as db:
            if not db.one("SELECT 1 FROM relay_approvals WHERE source_id=? AND source_hash=? "
                          "AND client_id=? AND client_hash=?",
                          (source_id, source_hash, client_id, client_hash)):
                return False
            db.execute("UPDATE relay_approved_destinations SET expires_at=? WHERE source_id=? AND source_hash=? "
                       "AND client_id=? AND client_hash=? AND mode=? AND activity_id=? AND token_hash<>? "
                       "AND expires_at=0", (now + 600, source_id, source_hash, client_id, client_hash,
                                            mode, activity_id, token_hash))
            db.execute("INSERT INTO relay_approved_destinations VALUES (?,?,?,?,?,?,?,?,0) "
                       "ON CONFLICT(source_id,source_hash,client_id,client_hash,mode,activity_id,token_hash) "
                       "DO UPDATE SET environment=excluded.environment,expires_at=0",
                       (source_id, source_hash, client_id, client_hash, mode, activity_id, token_hash,
                        environment))
            db.execute("DELETE FROM relay_approved_destinations WHERE source_id=? AND source_hash=? "
                       "AND client_id=? AND client_hash=? AND mode=? AND activity_id=? AND expires_at>0 "
                       "AND expires_at<=?", (source_id, source_hash, client_id, client_hash, mode, activity_id, now))
        return True

    def unbind_approved(self, source_id: str, source_hash: str, client_id: str,
                        credential: str, mode: str, activity_id: str) -> bool:
        if (mode not in ("alert", "watch", "liveactivity")
                or not isinstance(activity_id, str) or len(activity_id) > 128
                or (mode != "liveactivity" and activity_id)):
            raise ValueError("Invalid destination")
        with self.connection() as db:
            if not db.one("SELECT 1 FROM relay_approvals WHERE source_id=? AND source_hash=? "
                          "AND client_id=? AND client_hash=?",
                          (source_id, source_hash, client_id, digest(credential))):
                return False
            db.execute("DELETE FROM relay_approved_destinations WHERE source_id=? AND source_hash=? "
                       "AND client_id=? AND client_hash=? AND mode=? AND activity_id=?",
                       (source_id, source_hash, client_id, digest(credential), mode, activity_id))
        return True

    def approved_send(self, source_id: str, source_credential: str, client_id: str,
                      client_hash: str, mode: str, activity_id: str, token: str,
                      environment: str, now: float) -> bool:
        source_hash = digest(source_credential)
        if not isinstance(client_hash, str) or re.fullmatch(r"[0-9a-f]{64}", client_hash) is None:
            return False
        with self.connection() as db:
            if db.one("SELECT 1 FROM relay_revoked_sources WHERE id=?", (source_id,)) or db.one(
                    "SELECT 1 FROM relay_revoked_clients WHERE source_id=? AND source_hash=? "
                    "AND client_id=? AND client_hash=?", (source_id, source_hash, client_id, client_hash)):
                return False
            active = db.one("SELECT credential_hash FROM relay_sources WHERE id=?", (source_id,))
            if active and not hmac.compare_digest(active[0], source_hash):
                return False
            approved = db.one("SELECT 1 FROM relay_approved_destinations WHERE source_id=? AND source_hash=? "
                              "AND client_id=? AND client_hash=? AND mode=? AND activity_id=? "
                              "AND token_hash=? AND environment=? AND (expires_at=0 OR expires_at>?)",
                              (source_id, source_hash, client_id, client_hash, mode, activity_id,
                               digest(token), environment, now))
            if not approved:
                return False
            if not active:
                if db.one("SELECT COUNT(*) FROM relay_sources")[0] + db.one(
                        "SELECT COUNT(*) FROM relay_revoked_sources")[0] >= 10_000:
                    return False
                db.execute("INSERT INTO relay_sources VALUES (?,?,?) ON CONFLICT(id) DO NOTHING",
                           (source_id, source_hash, now))
                active = db.one("SELECT credential_hash FROM relay_sources WHERE id=?", (source_id,))
                if not active or not hmac.compare_digest(active[0], source_hash):
                    return False
                db.execute("DELETE FROM relay_approvals WHERE source_id=? AND source_hash<>?",
                           (source_id, source_hash))
        return True

    def revoke_approved_client(self, source_id: str, source_credential: str,
                               client_id: str, client_hash: str) -> bool:
        source_hash = digest(source_credential)
        with self.connection() as db:
            active = db.one("SELECT credential_hash FROM relay_sources WHERE id=?", (source_id,))
            if active and not hmac.compare_digest(active[0], source_hash):
                return False
            if not active and not db.one("SELECT 1 FROM relay_approvals WHERE source_id=? AND source_hash=?",
                                         (source_id, source_hash)):
                return False
            db.execute("INSERT INTO relay_revoked_clients VALUES (?,?,?,?) ON CONFLICT DO NOTHING",
                       (source_id, source_hash, client_id, client_hash))
            db.execute("DELETE FROM relay_approvals WHERE source_id=? AND source_hash=? "
                       "AND client_id=? AND client_hash=?", (source_id, source_hash, client_id, client_hash))
        return True

    def revoke_approved_self(self, source_id: str, source_hash: str,
                             client_id: str, credential: str) -> bool:
        with self.connection() as db:
            client_hash = digest(credential)
            if not db.one("SELECT 1 FROM relay_approvals WHERE source_id=? AND source_hash=? "
                          "AND client_id=? AND client_hash=?",
                          (source_id, source_hash, client_id, client_hash)):
                return False
            db.execute("INSERT INTO relay_revoked_clients VALUES (?,?,?,?) ON CONFLICT DO NOTHING",
                       (source_id, source_hash, client_id, client_hash))
            db.execute("DELETE FROM relay_approvals WHERE source_id=? AND source_hash=? "
                       "AND client_id=? AND client_hash=?", (source_id, source_hash, client_id, client_hash))
        return True

    def revoke_approved_source(self, source_id: str, source_credential: str) -> bool:
        source_hash = digest(source_credential)
        with self.connection() as db:
            active = db.one("SELECT credential_hash FROM relay_sources WHERE id=?", (source_id,))
            if active and not hmac.compare_digest(active[0], source_hash):
                return False
            if not active and not db.one("SELECT 1 FROM relay_approvals WHERE source_id=? AND source_hash=?",
                                         (source_id, source_hash)):
                return False
            if active:
                db.execute("INSERT INTO relay_revoked_sources(id) VALUES (?) ON CONFLICT(id) DO NOTHING", (source_id,))
                db.execute("DELETE FROM relay_approvals WHERE source_id=?", (source_id,))
                db.execute("DELETE FROM relay_attest_sources WHERE source_id=?", (source_id,))
                db.execute("DELETE FROM relay_sources WHERE id=?", (source_id,))
            else:
                db.execute("DELETE FROM relay_approvals WHERE source_id=? AND source_hash=?",
                           (source_id, source_hash))
        return True

    def source_authorized(self, source_id: str, credential: str) -> bool:
        if not valid_uuid(source_id) or not credential:
            return False
        with self.connection() as db:
            existing = db.one("SELECT credential_hash FROM relay_sources WHERE id=?", (source_id,))
        return bool(existing and hmac.compare_digest(existing[0], digest(credential)))

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
