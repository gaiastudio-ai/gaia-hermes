#!/usr/bin/env python3
"""verify-permits.py — deterministic proof for the inactive Gaia permit ledger
(profile/skills/gaia-orchestrator/scripts/gaia_permits.py).

NOT READY FOR GAIA RUNS: this proves the accounting library only. No model,
no owner transport, no real registry, no service, nothing launched.

Imports the actual library, uses temporary ledgers / registries and a frozen
injectable clock, spawns real concurrent processes against one SQLite file,
and exits non-zero on any failed assertion.

    python3 tests/verify-permits.py      # exit 0 == correct
"""
import datetime as dt
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import uuid

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(REPO, "profile", "skills", "gaia-orchestrator", "scripts")
sys.path.insert(0, SCRIPTS)
import gaia_permits as gp  # noqa: E402

UTC = dt.timezone.utc
FAILS = []
PASSES = 0


def check(cond, label):
    global PASSES
    if cond:
        PASSES += 1
        print("PASS  " + label)
    else:
        FAILS.append(label)
        print("FAIL  " + label)


def eq(actual, expected, label):
    check(actual == expected, f"{label} (got {actual!r}, want {expected!r})")


class Clock:
    def __init__(self, when):
        self.when = when

    def __call__(self):
        return self.when


def utc(*args):
    return dt.datetime(*args, tzinfo=UTC)


def rid():
    return str(uuid.uuid4())


def req(project="alpha", source="cron", request_id=None):
    return {"request_id": request_id or rid(), "project": project, "source": source}


def rows(path):
    """Snapshot of every ledger table (sorted rows), or None if unreadable."""
    try:
        conn = sqlite3.connect(path)
        out = {}
        for t in ("requests", "permits", "events", "grants"):
            out[t] = sorted(conn.execute(f"SELECT * FROM {t}").fetchall())
        conn.close()
        return out
    except sqlite3.DatabaseError:
        return None


def counts(path):
    r = rows(path)
    return {k: len(v) for k, v in r.items()} if r else None


def tree(d):
    out = {}
    for root, dirs, files in os.walk(d):
        for f in files:
            p = os.path.join(root, f)
            st = os.lstat(p)
            try:
                with open(p, "rb") as fh:
                    body = fh.read()
            except OSError:
                body = b"<unreadable>"
            out[os.path.relpath(p, d)] = (st.st_mode, st.st_size, st.st_mtime_ns, body)
        for s in dirs:
            p = os.path.join(root, s)
            if os.path.islink(p):
                out[os.path.relpath(p, d)] = b"<symlink>"
    return out


def make_registry(base, slug="alpha", record=None, raw=None):
    reg = os.path.join(base, "projects")
    os.makedirs(reg, exist_ok=True)
    p = os.path.join(reg, slug + ".yaml")
    if raw is not None:
        with open(p, "wb") as f:
            f.write(raw)
    else:
        with open(p, "w") as f:
            json.dump(record if record is not None else {"slug": slug, "paused": False}, f)
    return reg


def fresh(when=utc(2026, 9, 24, 10, 0, 0), slugs=("alpha",)):
    base = tempfile.mkdtemp(prefix="permits-")
    reg = os.path.join(base, "projects")
    for s in slugs:
        make_registry(base, s)
    clock = Clock(when)
    ledger = os.path.join(base, "ledger.db")
    return base, reg, ledger, clock, gp.PermitLedger(ledger, reg, clock)


def admitted_and_finished(L, project="alpha", n=1, source="direct", outcome="succeeded"):
    ids = []
    for _ in range(n):
        r = L.admit(req(project, source))
        assert r["status"] == "admitted", r
        assert L.finish(r["permit_id"], outcome)["status"] == "ok"
        ids.append(r["permit_id"])
    return ids


def stored_result(ledger, table, key_col, key):
    conn = sqlite3.connect(ledger)
    row = conn.execute(f"SELECT result FROM {table} WHERE {key_col} = ?", (key,)).fetchone()
    conn.close()
    return json.loads(row[0]) if row else None


# ---------------------------------------------------------------- 1: schema ---
def test_schema_and_registry():
    base, reg, ledger, clock, L = fresh()
    L.admit(req())  # ensure ledger exists so snapshots are comparable
    before_rows, before_tree = rows(ledger), tree(base)
    bad = [
        ("not an object", "x", "request_not_object"),
        ("list", [req()], "request_not_object"),
        ("missing request_id", {"project": "alpha", "source": "cron"}, "missing_field"),
        ("missing project", {"request_id": rid(), "source": "cron"}, "missing_field"),
        ("missing source", {"request_id": rid(), "project": "alpha"}, "missing_field"),
        ("unknown field", dict(req(), extra=1), "unknown_field"),
        ("path override", dict(req(), ledger_path="/tmp/x"), "unknown_field"),
        ("registry override", dict(req(), registry_dir="/tmp"), "unknown_field"),
        ("command override", dict(req(), command="rm -rf /"), "unknown_field"),
        ("cap override", dict(req(), cap=99), "unknown_field"),
        ("day override", dict(req(), day="2030-01-01"), "unknown_field"),
        ("clock override", dict(req(), clock="2030-01-01T00:00:00Z"), "unknown_field"),
        ("raise via request", dict(req(), action="raise_for_today"), "unknown_field"),
        ("finish via request", dict(req(), finish="succeeded"), "unknown_field"),
        ("control via request", dict(req(), command_id=rid()), "unknown_field"),
        ("wrong type id", {"request_id": 5, "project": "alpha", "source": "cron"}, "wrong_type"),
        ("wrong type project", {"request_id": rid(), "project": ["alpha"], "source": "cron"}, "wrong_type"),
        ("wrong type source", {"request_id": rid(), "project": "alpha", "source": None}, "wrong_type"),
        ("non-canonical uuid", req(request_id=rid().upper()), "invalid_request_id"),
        ("uuid no hyphens", req(request_id=uuid.uuid4().hex), "invalid_request_id"),
        ("bad uuid", req(request_id="not-a-uuid"), "invalid_request_id"),
        ("slug uppercase", req(project="Alpha"), "invalid_project"),
        ("slug path", req(project="../alpha"), "invalid_project"),
        ("slug slash", req(project="a/b"), "invalid_project"),
        ("slug leading dash", req(project="-alpha"), "invalid_project"),
        ("slug too long", req(project="a" * 49), "invalid_project"),
        ("slug empty", req(project=""), "invalid_project"),
        ("bad source", req(source="manual"), "invalid_source"),
        ("source case", req(source="Cron"), "invalid_source"),
    ]
    for label, payload, reason in bad:
        r = L.admit(payload)
        eq((r["status"], r["reason"]), ("refused", reason), f"schema: {label}")
    check(rows(ledger) == before_rows, "schema refusals added no rows")
    check(tree(base) == before_tree, "schema refusals created no files")

    # registry records
    make_registry(base, "paused", {"paused": True})
    make_registry(base, "nopaused", {"slug": "nopaused"})
    make_registry(base, "strpaused", {"paused": "false"})
    make_registry(base, "intpaused", {"paused": 0})
    make_registry(base, "nullpaused", {"paused": None})
    make_registry(base, "malformed", raw=b"{not json")
    make_registry(base, "notobject", raw=b"[1, 2]")
    make_registry(base, "scalar", raw=b"true")
    make_registry(base, "binary", raw=b"\xff\xfe\x00")
    os.symlink(os.path.join(reg, "alpha.yaml"), os.path.join(reg, "linked.yaml"))
    outside = os.path.join(base, "outside.yaml")
    with open(outside, "w") as f:
        json.dump({"paused": False}, f)
    os.symlink(outside, os.path.join(reg, "escape.yaml"))
    os.mkdir(os.path.join(reg, "isdir.yaml"))
    unreadable = make_registry(base, "unreadable")
    os.chmod(os.path.join(unreadable, "unreadable.yaml"), 0)
    before_rows, before_tree = rows(ledger), tree(base)
    reg_cases = [
        ("missing record", "missing", "registry_missing"),
        ("paused=true", "paused", "project_paused"),
        ("paused absent", "nopaused", "registry_paused_missing"),
        ("paused string", "strpaused", "registry_paused_not_boolean"),
        ("paused int", "intpaused", "registry_paused_not_boolean"),
        ("paused null", "nullpaused", "registry_paused_not_boolean"),
        ("malformed json", "malformed", "registry_malformed"),
        ("array record", "notobject", "registry_not_object"),
        ("scalar record", "scalar", "registry_not_object"),
        ("binary record", "binary", "registry_malformed"),
        ("symlink inside", "linked", "registry_symlink"),
        ("symlink outside", "escape", "registry_symlink"),
        ("directory record", "isdir", "registry_unreadable"),
    ]
    for label, slug, reason in reg_cases:
        for source in gp.SOURCES:
            r = L.admit(req(slug, source))
            eq((r["status"], r["reason"]), ("refused", reason), f"registry: {label} via {source}")
    if os.geteuid() != 0:
        r = L.admit(req("unreadable"))
        eq((r["status"], r["reason"]), ("refused", "registry_unreadable"), "registry: unreadable record")
    check(rows(ledger) == before_rows, "registry refusals added no rows")
    check(tree(base) == before_tree, "registry refusals changed/created no files")
    os.chmod(os.path.join(unreadable, "unreadable.yaml"), 0o600)
    shutil.rmtree(base)


# --------------------------------------------------------- 2: five sources ---
def test_sources_and_replay():
    base, reg, ledger, clock, L = fresh()
    # each source admits with room (finish in between so nothing is busy)
    for source in gp.SOURCES:
        r = L.admit(req("alpha", source))
        if source == "direct":
            eq((r["status"], r["reason"]), ("exhausted", "allowance_exhausted"),
               "fifth source exhausted after four")
        else:
            eq(r["status"], "admitted", f"{source} admits with room")
            eq(r["source"], source, f"{source} recorded")
            eq(L.finish(r["permit_id"], "succeeded")["status"], "ok", f"{source} permit finished")
    eq(L.status("alpha")["used"], 4, "used is four after four completed")
    # each source refuses as exhausted after four completed permits
    for source in gp.SOURCES:
        r = L.admit(req("alpha", source))
        eq((r["status"], r["reason"]), ("exhausted", "allowance_exhausted"), f"{source} exhausted")
    eq(counts(ledger)["events"], 1, "exhaustion recorded one decision event")
    # resume consumes a start on a fresh project
    make_registry(base, "beta")
    before = L.status("beta")["used"]
    r = L.admit(req("beta", "resume"))
    eq(r["status"], "admitted", "resume admitted")
    eq(L.status("beta")["used"], before + 1, "resume increased used by one")
    # replay of admitted request: the EXACT original receipt, no new rows
    L.finish(r["permit_id"], "stopped")
    snap = rows(ledger)
    rr = L.admit(dict(req("beta", "resume", r["request_id"])))
    eq(rr, r, "admitted replay returns the exact original result")
    eq(rr, stored_result(ledger, "requests", "request_id", r["request_id"]),
       "admitted replay equals the stored receipt row")
    check("replay" not in rr and "replay" not in r, "no replay marker in either receipt")
    eq(rr["permit_id"], r["permit_id"], "replay returns original permit id")
    eq(rows(ledger), snap, "replay changed no row")
    eq(L.status("beta")["used"], before + 1, "replay did not count again")
    rr2 = L.admit(dict(req("beta", "resume", r["request_id"])))
    eq(rr2, r, "second replay still identical")
    # replay of exhausted request: durable, exact, no new event
    ex = req("alpha", "gateway")
    r1 = L.admit(ex)
    snap = rows(ledger)
    r2 = L.admit(dict(ex))
    eq(r2["status"], "exhausted", "exhausted replay stays exhausted")
    eq(r2, r1, "exhausted replay identical to original")
    eq(rows(ledger), snap, "exhausted replay changed no row")
    # changed payload for existing id refuses
    for changed in (dict(ex, source="cron"), dict(ex, project="beta")):
        r3 = L.admit(changed)
        eq((r3["status"], r3["reason"]), ("refused", "payload_changed"), "changed payload refuses")
    eq(rows(ledger), snap, "changed payload changed no row")
    # busy replay
    make_registry(base, "gamma")
    a = L.admit(req("gamma"))
    b = req("gamma", "self_schedule")
    rb = L.admit(b)
    eq((rb["status"], rb["reason"], rb["active_permit"]), ("busy", "permit_active", a["permit_id"]), "busy while active")
    snap = rows(ledger)
    rb2 = L.admit(dict(b))
    eq(rb2, rb, "busy replay identical to original")
    eq(rows(ledger), snap, "busy replay changed no row")
    L.finish(a["permit_id"], "succeeded")
    rb3 = L.admit(dict(b))
    eq(rb3, rb, "busy replay stays the original busy receipt after finish (needs new request id)")
    eq(L.admit(req("gamma"))["status"], "admitted", "new request id admits after finish")
    shutil.rmtree(base)


# ---------------------------------------------------------- 3: concurrency ---
CHILD = r"""
import sys, json, datetime, time
sys.path.insert(0, sys.argv[1])
import gaia_permits as gp
ledger, reg, start, project, rid = sys.argv[2], sys.argv[3], float(sys.argv[4]), sys.argv[5], sys.argv[6]
clock = lambda: datetime.datetime(2026, 9, 24, 10, 0, tzinfo=datetime.timezone.utc)
while time.time() < start:
    time.sleep(0.001)
L = gp.PermitLedger(ledger, reg, clock)
print(json.dumps(L.admit({"request_id": rid, "project": project, "source": "cron"})))
"""


def test_concurrency_and_finish():
    base, reg, ledger, clock, L = fresh()
    admitted_and_finished(L, n=3)
    eq(L.status("alpha")["used"], 3, "three completed permits")
    start = time.time() + 1.0
    procs = [subprocess.Popen([sys.executable, "-c", CHILD, SCRIPTS, ledger, reg, str(start), "alpha", rid()],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for _ in range(8)]
    results = []
    for p in procs:
        out, err = p.communicate(timeout=60)
        check(p.returncode == 0 and not err, f"child process clean (rc={p.returncode}, err={err.strip()[:200]})")
        results.append(json.loads(out))
    statuses = sorted(r["status"] for r in results)
    eq(statuses.count("admitted"), 1, "exactly one concurrent admission")
    eq(statuses.count("refused"), 0, "no concurrent refusal")
    check(all(s in ("admitted", "busy", "exhausted") for s in statuses), f"concurrent statuses {statuses}")
    eq(L.status("alpha")["used"], 4, "total used is four after race")
    eq(counts(ledger)["permits"], 4, "four permit rows")
    eq(counts(ledger)["requests"], 3 + 8, "every racing request recorded")
    winner = [r for r in results if r["status"] == "admitted"][0]
    # replaying the winner from this process returns the child's exact receipt
    eq(L.admit({"request_id": winner["request_id"], "project": "alpha", "source": "cron"}), winner,
       "cross-process replay returns the child's exact receipt")
    # unfinished permit blocks
    r = L.admit(req("alpha", "direct"))
    eq((r["status"], r["reason"]), ("busy", "permit_active"), "another request cannot admit while unfinished")
    # invalid finish outcomes
    for bad in (None, "", "done", "SUCCEEDED", 1, "succeeded "):
        f = L.finish(winner["permit_id"], bad)
        eq((f["status"], f["reason"]), ("refused", "invalid_outcome"), f"finish outcome {bad!r} refused")
    eq(L.finish(rid(), "succeeded")["reason"], "permit_unknown", "unknown permit refused")
    eq(L.finish("bogus", "succeeded")["reason"], "invalid_permit_id", "invalid permit id refused")
    eq(L.status("alpha")["active_permit"]["permit_id"], winner["permit_id"], "permit still active after refused finishes")
    # finishing never refunds
    make_registry(base, "delta")
    for outcome in gp.OUTCOMES:
        before = L.status("delta")["used"]
        a = L.admit(req("delta"))
        eq(a["status"], "admitted", f"delta admitted before {outcome}")
        eq(L.finish(a["permit_id"], outcome)["status"], "ok", f"finish {outcome}")
        eq(L.status("delta")["used"], before + 1, f"{outcome} did not refund")
        eq(L.finish(a["permit_id"], outcome)["reason"], "permit_not_active", f"second finish {outcome} refused")
    eq(L.finish(winner["permit_id"], "stopped")["status"], "ok", "race winner stopped")
    eq(L.status("alpha")["used"], 4, "still four used after stop")
    eq(L.admit(req("alpha"))["status"], "exhausted", "alpha exhausted after stop, not refunded")
    shutil.rmtree(base)


# ----------------------------------------------------------- 4: Berlin days ---
def test_days_and_dst():
    base, reg, ledger, clock, L = fresh(when=utc(2026, 3, 28, 12, 0, 0), slugs=("alpha", "beta"))
    admitted_and_finished(L, n=3)
    eq(L.status("beta")["used"], 0, "beta untouched")
    active = L.admit(req("alpha", "gateway"))
    eq(active["status"], "admitted", "fourth admitted and left active")
    eq(L.admit(req("alpha"))["status"], "busy", "busy before midnight")
    old_rows = rows(ledger)
    clock.when = utc(2026, 3, 28, 22, 59, 59)  # Berlin 23:59:59 CET, 28 March
    eq(L.status("alpha")["day"], "2026-03-28", "23:59:59 Berlin still 28 March")
    eq(L.status("alpha")["used"], 4, "four used on 28 March")
    clock.when = utc(2026, 3, 28, 23, 0, 0)  # Berlin 00:00:00, 29 March (DST day)
    st = L.status("alpha")
    eq(st["day"], "2026-03-29", "midnight rolls to 29 March")
    eq(st["used"], 0, "new-day used is zero")
    eq(st["active_permit"]["permit_id"], active["permit_id"], "active permit survives midnight")
    eq(rows(ledger), old_rows, "time change alone wrote nothing")
    r = L.admit(req("alpha", "cron"))
    eq((r["status"], r["reason"]), ("busy", "permit_active"), "still busy across midnight")
    # spring forward: 01:59:59 CET -> 03:00:00 CEST, same day
    clock.when = utc(2026, 3, 29, 0, 59, 59)
    eq(L.status("alpha")["day"], "2026-03-29", "01:59:59 CET is 29 March")
    clock.when = utc(2026, 3, 29, 1, 0, 0)
    eq(L.status("alpha")["day"], "2026-03-29", "03:00:00 CEST is 29 March")
    eq(L.finish(active["permit_id"], "succeeded")["status"], "ok", "finish across boundary")
    eq(L.status("alpha")["used"], 0, "finishing yesterday's permit counts nothing today")
    r = L.admit(req("alpha", "resume"))
    eq((r["status"], r["used"]), ("admitted", 1), "new day admits")
    L.finish(r["permit_id"], "failed")
    conn = sqlite3.connect(ledger)
    eq(conn.execute("SELECT COUNT(*) FROM permits WHERE project='alpha' AND day='2026-03-28'").fetchone()[0], 4,
       "old-day permit rows persist")
    conn.close()
    # autumn: CEST -> CET on 25 October 2026 at 03:00 -> 02:00
    clock.when = utc(2026, 10, 24, 21, 59, 59)  # Berlin 23:59:59 CEST 24 Oct
    eq(L.status("alpha")["day"], "2026-10-24", "23:59:59 CEST is 24 October")
    clock.when = utc(2026, 10, 24, 22, 0, 0)  # Berlin 00:00 25 Oct
    eq(L.status("alpha")["day"], "2026-10-25", "midnight into 25 October")
    admitted_and_finished(L, n=4)
    eq(L.admit(req("alpha"))["status"], "exhausted", "exhausted on 25 October")
    clock.when = utc(2026, 10, 25, 0, 59, 59)  # 02:59:59 CEST
    eq(L.status("alpha")["day"], "2026-10-25", "02:59:59 CEST is 25 October")
    clock.when = utc(2026, 10, 25, 1, 0, 0)  # 02:00:00 CET (repeated hour)
    eq(L.status("alpha")["day"], "2026-10-25", "02:00:00 CET is 25 October")
    eq(L.status("alpha")["used"], 4, "fall-back hour does not reset used")
    clock.when = utc(2026, 10, 25, 22, 30, 0)  # 23:30 CET 25 Oct (would be 26 Oct at +2)
    eq(L.status("alpha")["day"], "2026-10-25", "23:30 CET still 25 October")
    eq(L.status("alpha")["used"], 4, "still exhausted on 25 October")
    clock.when = utc(2026, 10, 25, 23, 0, 0)  # 00:00 CET 26 Oct
    eq(L.status("alpha")["day"], "2026-10-26", "midnight CET into 26 October")
    eq(L.status("alpha")["used"], 0, "26 October used is zero")
    eq(L.status("alpha")["decision_pending"], False, "25 October decision is not today's")
    eq(L.status("beta")["used"], 0, "beta unaffected throughout")
    eq(L.admit(req("beta"))["status"], "admitted", "beta admits")
    ev = counts(ledger)["events"]
    clock.when = utc(2026, 12, 31, 23, 30, 0)
    L.status("alpha")
    eq(counts(ledger)["events"], ev, "no event appears solely because time changed")
    # naive / broken clock refuses
    clock.when = dt.datetime(2026, 1, 1, 0, 0, 0)
    eq(L.admit(req("beta"))["reason"], "clock_invalid", "naive clock refused")
    shutil.rmtree(base)


# ---------------------------------------------------------- 5: owner controls ---
def test_owner_controls():
    base, reg, ledger, clock, L = fresh(slugs=("alpha", "beta"))
    admitted_and_finished(L, n=4)
    reg_before = tree(reg)
    for source in gp.SOURCES:
        eq(L.admit(req("alpha", source))["status"], "exhausted", f"exhausted via {source}")
    eq(counts(ledger)["events"], 1, "one decision event for project/day")
    eq(L.status("alpha")["decision_pending"], True, "status reports pending decision")
    # controls before any raise: keep waiting adds zero
    kw = rid()
    r = L.keep_waiting(kw, "alpha", "2026-09-24")
    eq((r["status"], r["increment"], r["limit"]), ("ok", 0, 4), "keep waiting adds zero")
    eq(L.keep_waiting(kw, "alpha", "2026-09-24"), r, "keep waiting replay returns exact original")
    eq(L.status("alpha")["limit"], 4, "limit unchanged after keep waiting")
    eq(L.admit(req("alpha"))["status"], "exhausted", "still exhausted after keep waiting")
    # raise adds four exactly once
    rc = rid()
    r = L.raise_for_today(rc, "alpha", "2026-09-24")
    eq((r["status"], r["increment"], r["limit"]), ("ok", 4, 8), "raise adds four")
    check("replay" not in r, "no replay marker in control receipt")
    st = L.status("alpha")
    eq((st["used"], st["limit"], st["remaining"], st["active_permit"]), (4, 8, 4, None),
       "status recomputes capacity after raise; no permit created")
    snap = rows(ledger)
    r2 = L.raise_for_today(rc, "alpha", "2026-09-24")
    eq(r2, r, "identical raise replay returns exact original result")
    eq(r2, stored_result(ledger, "grants", "command_id", rc), "raise replay equals stored command row")
    eq(rows(ledger), snap, "raise replay changed no row")
    eq(L.status("alpha")["limit"], 8, "replay did not add again")
    for changed in (("beta", "2026-09-24"), ("alpha", "2026-09-23")):
        r3 = L.raise_for_today(rc, *changed)
        eq((r3["status"], r3["reason"]), ("refused", "command_changed"), f"changed raise replay {changed} refused")
    eq(L.keep_waiting(rc, "alpha", "2026-09-24")["reason"], "command_changed", "same id other action refused")
    eq(L.raise_for_today(rid(), "alpha", "2026-09-23")["reason"], "day_stale", "stale-day raise refused")
    eq(L.raise_for_today(rid(), "alpha", "2026-09-25")["reason"], "day_stale", "future-day raise refused")
    eq(L.keep_waiting(rid(), "alpha", "2026-09-23")["reason"], "day_stale", "stale-day keep waiting refused")
    eq(L.raise_for_today(rid(), "beta", "2026-09-24")["reason"], "no_decision_pending", "raise without decision refused")
    eq(L.raise_for_today("nope", "alpha", "2026-09-24")["reason"], "invalid_command_id", "bad command id refused")
    eq(L.raise_for_today(rid(), "Alpha", "2026-09-24")["reason"], "invalid_project", "bad slug refused")
    eq(L.raise_for_today(rid(), "alpha", "24.09.2026")["reason"], "invalid_day", "bad day refused")
    eq(L.raise_for_today(rid(), "alpha", None)["reason"], "invalid_day", "missing day refused")
    eq(rows(ledger), snap, "refused controls changed no row")
    eq(L.status("alpha")["limit"], 8, "refused controls changed nothing")
    eq(counts(ledger)["grants"], 2, "two grant rows (keep + raise)")
    eq(counts(ledger)["permits"], 4, "controls created no permit")
    eq(tree(reg), reg_before, "controls did not change registry bytes")
    # the raised allowance is spent by admission, resume included
    r = L.admit(req("alpha", "resume"))
    eq((r["status"], r["used"], r["limit"]), ("admitted", 5, 8), "raise spent by a mechanism")
    # controls never finish an active permit
    eq(L.keep_waiting(rid(), "alpha", "2026-09-24")["status"], "ok", "keep waiting while active")
    eq(L.raise_for_today(rid(), "alpha", "2026-09-24")["limit"], 12, "second distinct raise adds four again")
    eq(L.status("alpha")["active_permit"]["permit_id"], r["permit_id"], "controls left the permit active")
    eq(tree(reg), reg_before, "controls while active did not change registry bytes")
    L.finish(r["permit_id"], "succeeded")
    for i in range(3):
        admitted_and_finished(L)
    eq(L.status("alpha")["used"], 8, "eight used")
    admitted_and_finished(L, n=4)
    eq(L.admit(req("alpha"))["status"], "exhausted", "exhausted at twelve")
    eq(counts(ledger)["events"], 1, "second exhaustion same day adds no event")
    # midnight: yesterday's raise does not carry
    clock.when = utc(2026, 9, 25, 10, 0, 0)
    st = L.status("alpha")
    eq((st["day"], st["used"], st["limit"], st["decision_pending"]), ("2026-09-25", 0, 4, False),
       "next day back to four and no pending decision")
    eq(L.raise_for_today(rid(), "alpha", "2026-09-24")["reason"], "day_stale", "yesterday's control refused")
    eq(L.raise_for_today(rc, "alpha", "2026-09-24"), r2, "yesterday's recorded command still replays unchanged")
    eq(L.admit(req("alpha"))["status"], "admitted", "new day admits without any control")
    shutil.rmtree(base)


# ------------------------------------------------------ 6: durability/corrupt ---
def test_reopen_and_corrupt():
    base, reg, ledger, clock, L = fresh(slugs=("alpha", "beta"))
    admitted_and_finished(L, n=4)
    ex = req("alpha")
    ex_result = L.admit(ex)
    rc = rid()
    rc_result = L.raise_for_today(rc, "alpha", "2026-09-24")
    act = L.admit(req("alpha", "resume"))
    eq(act["status"], "admitted", "active permit before close")
    snap = rows(ledger)
    L.close()
    eq(L.admit(req("beta"))["reason"], "ledger_unavailable", "closed handle refuses")
    L2 = gp.PermitLedger(ledger, reg, clock)
    eq(rows(ledger), snap, "reopen preserves rows")
    st = L2.status("alpha")
    eq((st["used"], st["limit"], st["active_permit"]["permit_id"], st["decision_pending"]),
       (5, 8, act["permit_id"], True), "reopened status from rows")
    eq(L2.admit(dict(ex)), ex_result, "reopened exhausted replay is the exact original")
    eq(L2.admit(dict(req("alpha", "resume", act["request_id"]))), act,
       "reopened admitted replay is the exact original")
    eq(L2.raise_for_today(rc, "alpha", "2026-09-24"), rc_result, "reopened command replay is the exact original")
    eq(rows(ledger), snap, "reopened replays changed no row")
    eq(L2.admit(req("alpha"))["status"], "busy", "reopened active permit still active (not expired)")
    eq(L2.finish(act["permit_id"], "succeeded")["status"], "ok", "reopened finish")
    eq(L2.status("alpha")["used"], 5, "no refund after reopen")
    # read-only status reflects today, not yesterday's exhaustion
    clock.when = utc(2026, 9, 25, 8, 0, 0)
    st = L2.status("alpha")
    eq((st["used"], st["limit"], st["remaining"]), (0, 4, 4), "status reflects new day capacity")
    # corrupt ledger: garbage bytes
    garbage = os.path.join(base, "garbage.db")
    with open(garbage, "wb") as f:
        f.write(b"this is not a sqlite database\n" * 40)
    with open(garbage, "rb") as f:
        gbytes = f.read()
    G = gp.PermitLedger(garbage, reg, clock)
    for label, r in (("admit", G.admit(req("beta"))), ("status", G.status("beta")),
                     ("finish", G.finish(rid(), "succeeded")),
                     ("raise", G.raise_for_today(rid(), "beta", "2026-09-25"))):
        eq((r["status"], r["reason"]), ("refused", "ledger_corrupt"), f"garbage ledger refuses {label}")
    with open(garbage, "rb") as f:
        eq(f.read(), gbytes, "garbage ledger bytes untouched")
    check(not os.path.exists(garbage + "-wal") and not os.path.exists(garbage + "-journal"),
          "no journal created beside garbage ledger")
    # corrupt: valid sqlite with foreign/partial schema
    partial = os.path.join(base, "partial.db")
    c = sqlite3.connect(partial)
    c.execute("CREATE TABLE permits (x INTEGER)")
    c.execute("INSERT INTO permits VALUES (1)")
    c.commit()
    c.close()
    with open(partial, "rb") as f:
        pbytes = f.read()
    P = gp.PermitLedger(partial, reg, clock)
    r = P.admit(req("beta"))
    eq((r["status"], r["reason"]), ("refused", "ledger_corrupt"), "partial schema refuses")
    eq(P.status("beta")["reason"], "ledger_corrupt", "partial schema status refuses")
    with open(partial, "rb") as f:
        eq(f.read(), pbytes, "partial ledger not reinitialised")
    # corrupt: wrong schema version
    versioned = os.path.join(base, "versioned.db")
    gp.PermitLedger(versioned, reg, clock).status("beta")
    c = sqlite3.connect(versioned)
    c.execute("UPDATE meta SET value='99' WHERE key='schema_version'")
    c.commit()
    c.close()
    eq(gp.PermitLedger(versioned, reg, clock).admit(req("beta"))["reason"], "ledger_corrupt",
       "schema version mismatch refuses")
    # inconsistent: two active permits for one project (index bypassed)
    incons = os.path.join(base, "incons.db")
    I = gp.PermitLedger(incons, reg, clock)
    a = I.admit(req("beta"))
    c = sqlite3.connect(incons)
    c.execute("DROP INDEX permits_one_active")
    c.execute("INSERT INTO permits SELECT 'ffffffff-ffff-4fff-8fff-ffffffffffff', 'ffffffff-ffff-4fff-8fff-fffffffffffe', "
              "project, source, day, status, admitted_at, finished_at FROM permits")
    c.commit()
    c.close()
    eq(I.admit(req("beta"))["reason"], "ledger_inconsistent", "two active permits refuses")
    eq(I.status("beta")["reason"], "ledger_inconsistent", "inconsistent status refuses")
    # unavailable: missing directory, directory as path, unwritable directory
    U = gp.PermitLedger(os.path.join(base, "nope", "ledger.db"), reg, clock)
    eq(U.admit(req("beta"))["reason"], "ledger_unavailable", "missing directory refuses")
    eq(U.status("beta")["reason"], "ledger_unavailable", "missing directory status refuses")
    D = gp.PermitLedger(base, reg, clock)
    eq(D.admit(req("beta"))["reason"], "ledger_unavailable", "directory path refuses")
    check(not os.path.exists(os.path.join(base, "nope")), "unavailable ledger created nothing")
    if os.geteuid() != 0:
        ro = os.path.join(base, "ro")
        os.mkdir(ro)
        os.chmod(ro, 0o500)
        R = gp.PermitLedger(os.path.join(ro, "ledger.db"), reg, clock)
        eq(R.admit(req("beta"))["reason"], "ledger_unavailable", "unwritable directory refuses")
        os.chmod(ro, 0o700)
    # no fallback allowance: the healthy ledger still knows alpha is exhausted for the 24th
    clock.when = utc(2026, 9, 24, 20, 0, 0)  # 22:00 CEST, still the 24th
    st = L2.status("alpha")
    eq((st["used"], st["limit"]), (5, 8), "no fresh allowance leaked: the 24th still counts its rows")
    # trusted construction rejects bad arguments outright
    for bad in ((None, reg, clock), (ledger, "", clock), (ledger, reg, "now")):
        try:
            gp.PermitLedger(*bad)
            check(False, f"construction {bad!r} should raise")
        except ValueError:
            check(True, "construction rejects invalid trusted argument")
    shutil.rmtree(base)


# ------------------------------------------------------------- 7: contract ---
def test_documentation_and_enums():
    doc = os.path.join(REPO, "profile", "skills", "gaia-orchestrator", "references", "run-permits.md")
    with open(doc) as f:
        text = f.read()
    check("NOT READY FOR GAIA RUNS" in text, "doc states NOT READY FOR GAIA RUNS")
    for needle in ("supervisor", "launch-once", "launch-time paused recheck", "owner-channel authentication",
                   "clean-resume"):
        check(needle in text, f"doc names remaining prerequisite: {needle}")
    for name in ("admit", "finish", "status", "raise_for_today", "keep_waiting"):
        check(f"`{name}" in text, f"doc documents {name}")
    eq({s.value for s in gp.Status}, {"admitted", "exhausted", "busy", "refused", "ok"}, "status enum fixed")
    eq(gp.SOURCES, ("cron", "resume", "gateway", "self_schedule", "direct"), "five sources")
    eq((gp.DAILY_STARTS, gp.RAISE_INCREMENT), (4, 4), "four per day, raise adds four")
    src = os.path.join(SCRIPTS, "gaia_permits.py")
    with open(src) as f:
        code = f.read()
    for forbidden in ("subprocess", "os.system", "exec(", "eval(", "shlex"):
        check(forbidden not in code, f"library never executes anything ({forbidden})")


def main():
    for test in (test_schema_and_registry, test_sources_and_replay, test_concurrency_and_finish,
                 test_days_and_dst, test_owner_controls, test_reopen_and_corrupt,
                 test_documentation_and_enums):
        print(f"---- {test.__name__}")
        try:
            test()
        except Exception as exc:  # any unexpected error is a failure
            import traceback
            traceback.print_exc()
            FAILS.append(f"{test.__name__} raised {exc!r}")
            print(f"FAIL  {test.__name__} raised {exc!r}")
    print(f"\n{PASSES} passed, {len(FAILS)} failed")
    if FAILS:
        for f in FAILS:
            print("  FAIL " + f)
        print("NOT READY FOR GAIA RUNS — proof failed")
        return 1
    print("OK — accounting library proven; NOT READY FOR GAIA RUNS (half two outstanding)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
