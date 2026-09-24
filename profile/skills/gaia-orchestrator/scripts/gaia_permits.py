#!/usr/bin/env python3
"""gaia_permits.py — inactive Gaia run-permit ledger (Part 4, half one).

NOT READY FOR GAIA RUNS. This module is an importable, standard-library-only
accounting contract. Nothing in this repository imports it, no runner, service,
CLI hook, gateway or cron calls it, and it never launches, executes or
schedules anything. It answers exactly one question durably: "may project P
consume one of its daily Gaia starts right now, and which permit is it?"

Contract (see references/run-permits.md for the full document):

* Four starts per project per Europe/Berlin calendar day (DAILY_STARTS), plus
  whatever the owner has added for that project and day through
  ``raise_for_today``. Owner grants are rows in the ``grants`` table; the
  limit is recomputed from rows on every admission and status call.
* A permit is counted at admission. Finishing a permit (succeeded, failed or
  stopped) never refunds it. A resume is a new request and consumes a start.
* All five sources — cron, resume, gateway, self_schedule, direct — go through
  the single ``admit`` method and share one count.
* At most one unfinished (active) permit per project, across days. A second
  request while one is active is ``busy``.
* Admission, counting and event creation happen in ONE ``BEGIN IMMEDIATE``
  SQLite transaction (WAL journal, synchronous=FULL), so concurrent processes
  serialise on the ledger file.
* Responses are fixed structured statuses (``Status``) plus fixed reason codes
  (``Reason``). Nothing parses prose. Request payloads are never executed,
  formatted into commands or used as paths.
* Refused requests write nothing. Admitted, exhausted and busy results are
  durable and idempotent per request_id: replaying the identical payload
  returns the stored result EXACTLY AS RECORDED (the same dict, no extra
  flag, no mutation) without another count or event; a different payload
  under an existing request_id is refused. Owner commands replay the same
  way: the recorded response is returned unchanged.

Trusted construction: the ledger path, the registry directory and the clock
are supplied by the trusted caller that constructs ``PermitLedger``. A launch
request carries only ``request_id``, ``project`` and ``source`` and can
override none of them. Owner controls (``raise_for_today``, ``keep_waiting``)
and ``finish`` are separate methods for trusted callers; they are not part of
the request schema and a request that tries to smuggle them is refused.

This is an inactive library contract, not a production security boundary.
Half two (supervisor, 45 active minutes, one extension or stop, containment,
launch-once binding to permit identity, launch-time paused recheck, owner
channel authentication, kill / clean-resume proof) is NOT implemented here.
"""

from __future__ import annotations

import contextlib
import datetime as _dt
import enum
import hashlib
import json
import os
import re
import sqlite3
import stat as _stat
import uuid
from typing import Any, Callable, Optional
from zoneinfo import ZoneInfo

_closing = contextlib.closing

__all__ = [
    "DAILY_STARTS",
    "RAISE_INCREMENT",
    "BERLIN",
    "SOURCES",
    "OUTCOMES",
    "Status",
    "Reason",
    "PermitLedger",
]

DAILY_STARTS = 4
RAISE_INCREMENT = 4
BERLIN = ZoneInfo("Europe/Berlin")
SOURCES = ("cron", "resume", "gateway", "self_schedule", "direct")
OUTCOMES = ("succeeded", "failed", "stopped")
SCHEMA_VERSION = "1"
_SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,47}$")
_REQUEST_FIELDS = ("request_id", "project", "source")
_TABLES = ("meta", "requests", "permits", "events", "grants")


class Status(str, enum.Enum):
    """Fixed response statuses. ``admit`` returns one of the first four;
    ``finish``, ``status``, ``raise_for_today`` and ``keep_waiting`` return
    ``OK`` or ``REFUSED``."""

    ADMITTED = "admitted"
    EXHAUSTED = "exhausted"
    BUSY = "busy"
    REFUSED = "refused"
    OK = "ok"


class Reason(str, enum.Enum):
    """Fixed reason codes attached to refusals (and to ``exhausted``/``busy``)."""

    # request schema
    REQUEST_NOT_OBJECT = "request_not_object"
    UNKNOWN_FIELD = "unknown_field"
    MISSING_FIELD = "missing_field"
    WRONG_TYPE = "wrong_type"
    INVALID_REQUEST_ID = "invalid_request_id"
    INVALID_PROJECT = "invalid_project"
    INVALID_SOURCE = "invalid_source"
    PAYLOAD_CHANGED = "payload_changed"
    # registry record
    REGISTRY_MISSING = "registry_missing"
    REGISTRY_SYMLINK = "registry_symlink"
    REGISTRY_UNREADABLE = "registry_unreadable"
    REGISTRY_MALFORMED = "registry_malformed"
    REGISTRY_NOT_OBJECT = "registry_not_object"
    REGISTRY_PAUSED_MISSING = "registry_paused_missing"
    REGISTRY_PAUSED_NOT_BOOLEAN = "registry_paused_not_boolean"
    PROJECT_PAUSED = "project_paused"
    # accounting
    ALLOWANCE_EXHAUSTED = "allowance_exhausted"
    PERMIT_ACTIVE = "permit_active"
    # ledger / clock
    LEDGER_UNAVAILABLE = "ledger_unavailable"
    LEDGER_CORRUPT = "ledger_corrupt"
    LEDGER_INCONSISTENT = "ledger_inconsistent"
    CLOCK_INVALID = "clock_invalid"
    # finish
    INVALID_PERMIT_ID = "invalid_permit_id"
    PERMIT_UNKNOWN = "permit_unknown"
    PERMIT_NOT_ACTIVE = "permit_not_active"
    INVALID_OUTCOME = "invalid_outcome"
    # owner controls
    INVALID_COMMAND_ID = "invalid_command_id"
    INVALID_DAY = "invalid_day"
    DAY_STALE = "day_stale"
    NO_DECISION_PENDING = "no_decision_pending"
    COMMAND_CHANGED = "command_changed"


class _Refusal(Exception):
    def __init__(self, reason: Reason, detail: Optional[str] = None):
        super().__init__(reason.value)
        self.reason = reason
        self.detail = detail


class _Corrupt(Exception):
    pass


# ----------------------------------------------------------------- helpers ---

def _canonical_uuid(value: Any) -> Optional[str]:
    """Return the value if it is a str in canonical lower-case hyphenated UUID
    form, else None. No normalisation: ``str(uuid.UUID(value))`` must equal
    the value exactly."""
    if type(value) is not str:
        return None
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError, TypeError):
        return None
    return value if str(parsed) == value else None


def _validate_request(request: Any) -> dict:
    """Schema check of a launch request. Raises _Refusal; never touches disk."""
    if type(request) is not dict:
        raise _Refusal(Reason.REQUEST_NOT_OBJECT)
    for key in request:
        if type(key) is not str or key not in _REQUEST_FIELDS:
            raise _Refusal(Reason.UNKNOWN_FIELD, str(key)[:64])
    for key in _REQUEST_FIELDS:
        if key not in request:
            raise _Refusal(Reason.MISSING_FIELD, key)
        if type(request[key]) is not str:
            raise _Refusal(Reason.WRONG_TYPE, key)
    if _canonical_uuid(request["request_id"]) is None:
        raise _Refusal(Reason.INVALID_REQUEST_ID)
    if not _SLUG_RE.match(request["project"]):
        raise _Refusal(Reason.INVALID_PROJECT)
    if request["source"] not in SOURCES:
        raise _Refusal(Reason.INVALID_SOURCE)
    return {k: request[k] for k in _REQUEST_FIELDS}


def _fingerprint(clean: dict) -> str:
    payload = json.dumps(clean, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def _validate_slug(project: Any) -> str:
    if type(project) is not str or not _SLUG_RE.match(project):
        raise _Refusal(Reason.INVALID_PROJECT)
    return project


def _validate_day(day: Any) -> str:
    if type(day) is not str:
        raise _Refusal(Reason.INVALID_DAY)
    try:
        parsed = _dt.date.fromisoformat(day)
    except ValueError:
        raise _Refusal(Reason.INVALID_DAY)
    if parsed.isoformat() != day:
        raise _Refusal(Reason.INVALID_DAY)
    return day


def _stored(text: str) -> dict:
    """Decode a recorded response. The stored JSON *is* the receipt; it is
    returned as decoded, with nothing added, removed or rewritten."""
    return json.loads(text)


# ----------------------------------------------------------------- ledger ----

class PermitLedger:
    """Trusted handle on one permit ledger.

    ``ledger_path``   SQLite file (created on first use; never reset).
    ``registry_dir``  directory holding ``<slug>.yaml`` records (JSON bodies,
                      the registry format gaia-project.sh writes).
    ``clock``         zero-argument callable returning a timezone-aware
                      ``datetime``; the Berlin calendar day is derived from it.

    None of these can be supplied or overridden by a launch request.
    """

    def __init__(self, ledger_path: str, registry_dir: str,
                 clock: Callable[[], _dt.datetime]):
        if type(ledger_path) is not str or not ledger_path:
            raise ValueError("ledger_path must be a non-empty str")
        if type(registry_dir) is not str or not registry_dir:
            raise ValueError("registry_dir must be a non-empty str")
        if not callable(clock):
            raise ValueError("clock must be callable")
        self._ledger_path = ledger_path
        self._registry_dir = registry_dir
        self._clock = clock
        self._closed = False

    # -- public API ---------------------------------------------------------

    def admit(self, request: Any) -> dict:
        """Ask for one start. ``request`` must be exactly
        ``{"request_id": <uuid>, "project": <slug>, "source": <source>}``.

        Returns a dict with ``status`` (Status value) and, depending on it:
          admitted  → request_id, project, source, day, used, limit, permit_id
          exhausted → request_id, project, source, day, used, limit, reason
          busy      → request_id, project, source, day, used, limit, reason,
                      active_permit
          refused   → reason (+ optional ``detail``)
        Refused requests write no rows. The other three are stored under the
        request_id; an identical replay returns the stored result EXACTLY as
        first returned (same keys, same values, no replay marker) and performs
        no further count or event. Callers that need to know whether a call
        was a replay compare against their own record or watch ``status``;
        the receipt itself is immutable.
        """
        try:
            clean = _validate_request(request)
        except _Refusal as r:
            return self._refused(r)
        fingerprint = _fingerprint(clean)
        try:
            day = self._today()
            with _closing(self._connect()) as conn:
                self._begin(conn)
                try:
                    row = conn.execute(
                        "SELECT fingerprint, result FROM requests WHERE request_id = ?",
                        (clean["request_id"],)).fetchone()
                    if row is not None:
                        if row[0] != fingerprint:
                            raise _Refusal(Reason.PAYLOAD_CHANGED)
                        conn.execute("ROLLBACK")
                        return _stored(row[1])
                    self._check_registry(clean["project"])
                    result = self._account(conn, clean, fingerprint, day)
                    conn.execute("COMMIT")
                    return result
                except BaseException:
                    if conn.in_transaction:
                        conn.execute("ROLLBACK")
                    raise
        except _Refusal as r:
            return self._refused(r)
        except _Corrupt:
            return self._refused(_Refusal(Reason.LEDGER_CORRUPT))
        except sqlite3.DatabaseError as exc:
            return self._refused(self._db_refusal(exc))

    def finish(self, permit_id: Any, outcome: Any) -> dict:
        """Trusted: close an ACTIVE permit exactly once with an explicit
        outcome in ``OUTCOMES``. Never refunds the start. Returns
        ``{"status": "ok", "permit_id", "project", "day", "outcome"}`` or a
        refusal (unknown permit, already finished, invalid outcome)."""
        try:
            if _canonical_uuid(permit_id) is None:
                raise _Refusal(Reason.INVALID_PERMIT_ID)
            if type(outcome) is not str or outcome not in OUTCOMES:
                raise _Refusal(Reason.INVALID_OUTCOME)
            now = self._now_iso()
            with _closing(self._connect()) as conn:
                self._begin(conn)
                try:
                    row = conn.execute(
                        "SELECT project, day, status FROM permits WHERE permit_id = ?",
                        (permit_id,)).fetchone()
                    if row is None:
                        raise _Refusal(Reason.PERMIT_UNKNOWN)
                    if row[2] != "active":
                        raise _Refusal(Reason.PERMIT_NOT_ACTIVE)
                    conn.execute(
                        "UPDATE permits SET status = ?, finished_at = ? "
                        "WHERE permit_id = ? AND status = 'active'",
                        (outcome, now, permit_id))
                    conn.execute("COMMIT")
                except BaseException:
                    if conn.in_transaction:
                        conn.execute("ROLLBACK")
                    raise
            return {"status": Status.OK.value, "permit_id": permit_id,
                    "project": row[0], "day": row[1], "outcome": outcome}
        except _Refusal as r:
            return self._refused(r)
        except _Corrupt:
            return self._refused(_Refusal(Reason.LEDGER_CORRUPT))
        except sqlite3.DatabaseError as exc:
            return self._refused(self._db_refusal(exc))

    def status(self, project: Any) -> dict:
        """Read-only. Recomputes from rows for the CURRENT Berlin day:
        ``{"status": "ok", "project", "day", "used", "limit", "remaining",
        "active_permit": {...}|None, "decision_pending": bool}``.
        Never stores or returns a waiting sentence."""
        try:
            slug = _validate_slug(project)
            day = self._today()
            with _closing(self._connect()) as conn:
                conn.execute("BEGIN")
                try:
                    used, limit = self._capacity(conn, slug, day)
                    active = self._active_permit(conn, slug)
                    pending = conn.execute(
                        "SELECT 1 FROM events WHERE project = ? AND day = ?",
                        (slug, day)).fetchone() is not None
                finally:
                    conn.execute("ROLLBACK")
            return {"status": Status.OK.value, "project": slug, "day": day,
                    "used": used, "limit": limit, "remaining": max(0, limit - used),
                    "active_permit": active, "decision_pending": pending}
        except _Refusal as r:
            return self._refused(r)
        except _Corrupt:
            return self._refused(_Refusal(Reason.LEDGER_CORRUPT))
        except sqlite3.DatabaseError as exc:
            return self._refused(self._db_refusal(exc))

    def raise_for_today(self, command_id: Any, project: Any, day: Any) -> dict:
        """Trusted owner control "Raise for today": adds RAISE_INCREMENT starts
        to ``project`` for the current Berlin day. ``day`` must equal the
        current Berlin day (stale-day control is refused) and a decision event
        must be pending for that project/day. Identical replay of
        ``command_id`` is inert and returns the recorded response unchanged;
        a changed replay is refused. Never admits, finishes, launches or
        touches the registry."""
        return self._control(command_id, project, day, "raise_for_today", RAISE_INCREMENT)

    def keep_waiting(self, command_id: Any, project: Any, day: Any) -> dict:
        """Trusted owner control "Keep waiting": acknowledges the pending
        decision event for ``project``/current day and adds no allowance.
        Same replay and day rules as ``raise_for_today``."""
        return self._control(command_id, project, day, "keep_waiting", 0)

    def close(self) -> None:
        """No connection is held between calls; ``close`` only marks the
        handle so a reopened ``PermitLedger`` is the way to continue."""
        self._closed = True

    # -- internals ------------------------------------------------------------

    @staticmethod
    def _refused(r: _Refusal) -> dict:
        out = {"status": Status.REFUSED.value, "reason": r.reason.value}
        if r.detail is not None:
            out["detail"] = r.detail
        return out

    @staticmethod
    def _db_refusal(exc: sqlite3.DatabaseError) -> _Refusal:
        text = str(exc)
        if "not a database" in text or "malformed" in text or "corrupt" in text:
            return _Refusal(Reason.LEDGER_CORRUPT)
        return _Refusal(Reason.LEDGER_UNAVAILABLE)

    def _now(self) -> _dt.datetime:
        try:
            now = self._clock()
        except Exception:
            raise _Refusal(Reason.CLOCK_INVALID)
        if not isinstance(now, _dt.datetime) or now.tzinfo is None \
                or now.utcoffset() is None:
            raise _Refusal(Reason.CLOCK_INVALID)
        return now

    def _now_iso(self) -> str:
        return self._now().astimezone(_dt.timezone.utc).isoformat()

    def _today(self) -> str:
        return self._now().astimezone(BERLIN).date().isoformat()

    def _connect(self) -> sqlite3.Connection:
        if self._closed:
            raise _Refusal(Reason.LEDGER_UNAVAILABLE, "closed")
        if os.path.isdir(self._ledger_path):
            raise _Refusal(Reason.LEDGER_UNAVAILABLE)
        try:
            conn = sqlite3.connect(self._ledger_path, timeout=30.0,
                                   isolation_level=None)
        except sqlite3.DatabaseError as exc:
            raise self._db_refusal(exc)
        try:
            # Inspect BEFORE touching journal mode: a foreign or corrupt file
            # must be refused without a single byte written to it.
            fresh = self._inspect_schema(conn)
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute("PRAGMA synchronous=FULL")
            if fresh:
                self._create_schema(conn)
        except BaseException:
            conn.close()
            raise
        return conn

    @staticmethod
    def _begin(conn: sqlite3.Connection) -> None:
        conn.execute("BEGIN IMMEDIATE")

    def _inspect_schema(self, conn: sqlite3.Connection) -> bool:
        """True when the file holds none of our tables (fresh ledger). Raises
        _Corrupt for a failed quick_check, a partial schema or a foreign
        schema version. Read-only."""
        check = conn.execute("PRAGMA quick_check").fetchone()
        if check is None or check[0] != "ok":
            raise _Corrupt()
        present = {r[0] for r in conn.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table'")}
        ours = present & set(_TABLES)
        if not ours:
            return True
        if ours != set(_TABLES):
            raise _Corrupt()
        version = conn.execute(
            "SELECT value FROM meta WHERE key = 'schema_version'").fetchone()
        if version is None or version[0] != SCHEMA_VERSION:
            raise _Corrupt()
        return False

    def _create_schema(self, conn: sqlite3.Connection) -> None:
        self._begin(conn)
        try:
            if self._inspect_schema(conn):  # re-check under the write lock
                for statement in _SCHEMA.split(";"):
                    if statement.strip():
                        conn.execute(statement)
                conn.execute("INSERT INTO meta(key, value) VALUES ('schema_version', ?)",
                             (SCHEMA_VERSION,))
            conn.execute("COMMIT")
        except BaseException:
            if conn.in_transaction:
                conn.execute("ROLLBACK")
            raise

    def _check_registry(self, slug: str) -> None:
        """Read ``<registry_dir>/<slug>.yaml`` as JSON; refuse anything that
        is not a regular, directly contained, readable JSON object with a
        boolean ``paused`` equal to False. Never creates or writes files.
        NOTE: this is a pre-accounting check only; a later registry change
        (pause after admission) is not detected by this library. Half two's
        launch-time paused recheck is a separate obligation."""
        record = os.path.join(self._registry_dir, slug + ".yaml")
        try:
            st = os.lstat(record)
        except FileNotFoundError:
            raise _Refusal(Reason.REGISTRY_MISSING)
        except OSError:
            raise _Refusal(Reason.REGISTRY_UNREADABLE)
        if _stat.S_ISLNK(st.st_mode):
            raise _Refusal(Reason.REGISTRY_SYMLINK)
        if not _stat.S_ISREG(st.st_mode):
            raise _Refusal(Reason.REGISTRY_UNREADABLE)
        real_dir = os.path.realpath(self._registry_dir)
        if os.path.dirname(os.path.realpath(record)) != real_dir:
            raise _Refusal(Reason.REGISTRY_SYMLINK)
        try:
            fd = os.open(record, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        except OSError as exc:
            if getattr(exc, "errno", None) == getattr(os, "ELOOP", -1):
                raise _Refusal(Reason.REGISTRY_SYMLINK)
            raise _Refusal(Reason.REGISTRY_UNREADABLE)
        try:
            with os.fdopen(fd, "rb") as f:
                raw = f.read()
        except OSError:
            raise _Refusal(Reason.REGISTRY_UNREADABLE)
        try:
            data = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            raise _Refusal(Reason.REGISTRY_MALFORMED)
        if type(data) is not dict:
            raise _Refusal(Reason.REGISTRY_NOT_OBJECT)
        if "paused" not in data:
            raise _Refusal(Reason.REGISTRY_PAUSED_MISSING)
        if type(data["paused"]) is not bool:
            raise _Refusal(Reason.REGISTRY_PAUSED_NOT_BOOLEAN)
        if data["paused"]:
            raise _Refusal(Reason.PROJECT_PAUSED)

    def _capacity(self, conn: sqlite3.Connection, slug: str, day: str):
        used = conn.execute(
            "SELECT COUNT(*) FROM permits WHERE project = ? AND day = ?",
            (slug, day)).fetchone()[0]
        extra = conn.execute(
            "SELECT COALESCE(SUM(increment), 0) FROM grants WHERE project = ? AND day = ?",
            (slug, day)).fetchone()[0]
        if type(used) is not int or type(extra) is not int or used < 0 or extra < 0:
            raise _Refusal(Reason.LEDGER_INCONSISTENT)
        return used, DAILY_STARTS + extra

    def _active_permit(self, conn: sqlite3.Connection, slug: str):
        rows = conn.execute(
            "SELECT permit_id, request_id, source, day, admitted_at FROM permits "
            "WHERE project = ? AND status = 'active'", (slug,)).fetchall()
        if len(rows) > 1:
            raise _Refusal(Reason.LEDGER_INCONSISTENT)
        if not rows:
            return None
        r = rows[0]
        return {"permit_id": r[0], "request_id": r[1], "source": r[2],
                "day": r[3], "admitted_at": r[4]}

    def _account(self, conn, clean: dict, fingerprint: str, day: str) -> dict:
        slug = clean["project"]
        now = self._now_iso()
        used, limit = self._capacity(conn, slug, day)
        active = self._active_permit(conn, slug)
        base = {"request_id": clean["request_id"], "project": slug,
                "source": clean["source"], "day": day}
        if active is not None:
            result = dict(base, status=Status.BUSY.value, reason=Reason.PERMIT_ACTIVE.value,
                          used=used, limit=limit, active_permit=active["permit_id"])
        elif used >= limit:
            result = dict(base, status=Status.EXHAUSTED.value,
                          reason=Reason.ALLOWANCE_EXHAUSTED.value, used=used, limit=limit)
            conn.execute(
                "INSERT OR IGNORE INTO events(project, day, kind, request_id, created_at) "
                "VALUES (?, ?, 'allowance_decision', ?, ?)",
                (slug, day, clean["request_id"], now))
        else:
            permit_id = str(uuid.uuid4())
            conn.execute(
                "INSERT INTO permits(permit_id, request_id, project, source, day, status, "
                "admitted_at, finished_at) VALUES (?, ?, ?, ?, ?, 'active', ?, NULL)",
                (permit_id, clean["request_id"], slug, clean["source"], day, now))
            result = dict(base, status=Status.ADMITTED.value, permit_id=permit_id,
                          used=used + 1, limit=limit)
        # The stored JSON is the receipt. It is decoded and returned as-is on
        # replay, so the first response is also round-tripped through the same
        # encoding to guarantee byte-for-byte equal receipts.
        stored = json.dumps(result, sort_keys=True)
        conn.execute(
            "INSERT INTO requests(request_id, fingerprint, project, source, day, status, "
            "permit_id, result, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (clean["request_id"], fingerprint, slug, clean["source"], day,
             result["status"], result.get("permit_id"), stored, now))
        return _stored(stored)

    def _control(self, command_id, project, day, action: str, increment: int) -> dict:
        try:
            if _canonical_uuid(command_id) is None:
                raise _Refusal(Reason.INVALID_COMMAND_ID)
            slug = _validate_slug(project)
            target = _validate_day(day)
            today = self._today()
            now = self._now_iso()
            with _closing(self._connect()) as conn:
                self._begin(conn)
                try:
                    row = conn.execute(
                        "SELECT project, day, action, result "
                        "FROM grants WHERE command_id = ?", (command_id,)).fetchone()
                    if row is not None:
                        if (row[0], row[1], row[2]) != (slug, target, action):
                            raise _Refusal(Reason.COMMAND_CHANGED)
                        conn.execute("ROLLBACK")
                        return _stored(row[3])
                    if target != today:
                        raise _Refusal(Reason.DAY_STALE)
                    pending = conn.execute(
                        "SELECT 1 FROM events WHERE project = ? AND day = ?",
                        (slug, today)).fetchone()
                    if pending is None:
                        raise _Refusal(Reason.NO_DECISION_PENDING)
                    _used, limit = self._capacity(conn, slug, today)
                    new_limit = limit + increment
                    result = {"status": Status.OK.value, "command_id": command_id,
                              "project": slug, "day": today, "action": action,
                              "increment": increment, "limit": new_limit}
                    stored = json.dumps(result, sort_keys=True)
                    conn.execute(
                        "INSERT INTO grants(command_id, project, day, action, increment, "
                        "resulting_limit, result, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                        (command_id, slug, today, action, increment, new_limit, stored, now))
                    conn.execute("COMMIT")
                    return _stored(stored)
                except BaseException:
                    if conn.in_transaction:
                        conn.execute("ROLLBACK")
                    raise
        except _Refusal as r:
            return self._refused(r)
        except _Corrupt:
            return self._refused(_Refusal(Reason.LEDGER_CORRUPT))
        except sqlite3.DatabaseError as exc:
            return self._refused(self._db_refusal(exc))


_SCHEMA = """
CREATE TABLE meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
CREATE TABLE requests (
    request_id  TEXT PRIMARY KEY,
    fingerprint TEXT NOT NULL,
    project     TEXT NOT NULL,
    source      TEXT NOT NULL,
    day         TEXT NOT NULL,
    status      TEXT NOT NULL CHECK (status IN ('admitted', 'exhausted', 'busy')),
    permit_id   TEXT,
    result      TEXT NOT NULL,
    created_at  TEXT NOT NULL
);
CREATE TABLE permits (
    permit_id   TEXT PRIMARY KEY,
    request_id  TEXT NOT NULL UNIQUE,
    project     TEXT NOT NULL,
    source      TEXT NOT NULL,
    day         TEXT NOT NULL,
    status      TEXT NOT NULL CHECK (status IN ('active', 'succeeded', 'failed', 'stopped')),
    admitted_at TEXT NOT NULL,
    finished_at TEXT
);
CREATE UNIQUE INDEX permits_one_active ON permits(project) WHERE status = 'active';
CREATE INDEX permits_project_day ON permits(project, day);
CREATE TABLE events (
    project    TEXT NOT NULL,
    day        TEXT NOT NULL,
    kind       TEXT NOT NULL CHECK (kind = 'allowance_decision'),
    request_id TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (project, day)
);
CREATE TABLE grants (
    command_id      TEXT PRIMARY KEY,
    project         TEXT NOT NULL,
    day             TEXT NOT NULL,
    action          TEXT NOT NULL CHECK (action IN ('raise_for_today', 'keep_waiting')),
    increment       INTEGER NOT NULL CHECK (increment >= 0),
    resulting_limit INTEGER NOT NULL,
    result          TEXT NOT NULL,
    created_at      TEXT NOT NULL
);
"""
