# Gaia run permits — daily accounting library (Part 4, half one)

**NOT READY FOR GAIA RUNS.** This document describes
`scripts/gaia_permits.py`, an *inactive* standard-library Python ledger and
its proof `tests/verify-permits.py`. Nothing in this repository calls it. There
is no runner, service, CLI hook, gateway connection, cron entry or deployment.
The pilot stays paused, cron stays off and no Gaia run is started by anything
described here. It is an accounting contract for half two to build on, not a
production security boundary.

## Owner rule it implements

* Four starts per project per Europe/Berlin calendar day.
* A resume consumes a start like any other request.
* All five sources — `cron`, `resume`, `gateway`, `self_schedule`, `direct` —
  use the same accounting through the same method.
* When the day's allowance is exhausted the request waits for the owner:
  **Raise for today** (adds four starts to that project and day) or
  **Keep waiting** (acknowledges, adds nothing).
* Owner grants are rows that a mechanism spends; they are not prose and are
  never parsed.

## Trusted construction

```python
from gaia_permits import PermitLedger
ledger = PermitLedger(ledger_path, registry_dir, clock)
```

| argument       | meaning                                                                 |
|----------------|-------------------------------------------------------------------------|
| `ledger_path`  | SQLite file. Created on first use. Never deleted or reinitialised.      |
| `registry_dir` | directory holding `<slug>.yaml` records with JSON bodies (the format `gaia-project.sh` writes when PyYAML is absent; a body that is not valid JSON is refused as malformed, never defaulted). |
| `clock`        | zero-argument callable returning a timezone-aware `datetime`. The Berlin day is derived from it. |

None of these can be supplied, chosen or overridden by a launch request.
Invalid trusted arguments raise `ValueError` at construction. SQLite is opened
with `journal_mode=WAL`, `synchronous=FULL`, and every write is one
`BEGIN IMMEDIATE` transaction, so concurrent processes serialise on the file.

## Launch request schema

A request is exactly:

```json
{"request_id": "<canonical lower-case hyphenated UUID>",
 "project":    "<slug matching [a-z0-9][a-z0-9-]{0,47}>",
 "source":     "cron | resume | gateway | self_schedule | direct"}
```

Anything else is refused before any I/O: a non-object, a missing or unknown
field, a wrong type, a non-canonical UUID, an invalid slug or source. In
particular paths, commands, cap/day/clock overrides and owner operations
(`action`, `finish`, `command_id`, …) are unknown fields and refuse. Request
data is never executed, formatted into a command or used as a path; the slug
only selects `<registry_dir>/<slug>.yaml`.

## Public methods

### `admit(request) -> dict`

The single admission path for all five sources. Order of work:

1. Schema validation (above). Refusal writes nothing.
2. `BEGIN IMMEDIATE`. If `request_id` is already recorded: identical payload
   (same fingerprint) returns the **stored receipt unchanged** — the very
   dict that was first returned, decoded from the row, with no flag added
   and nothing rewritten — and performs no further count or event; a
   different payload refuses with `payload_changed`.
3. Registry record check (below). Refusal rolls back and writes nothing.
4. Accounting for the current Berlin day, in this order:
   * an unfinished permit for the project (any day) → `busy`;
   * `used >= limit` → `exhausted`, and the first exhausted admission for
     that project/day inserts one `allowance_decision` event;
   * otherwise → `admitted`: a new permit row (`status = active`) is
     inserted and the request is counted **now**, before any launch.
5. The request row is stored with its fingerprint, day, status, permit id and
   the exact result JSON, then `COMMIT`. The first response is itself the
   decoded stored JSON, so first answer and every replay are equal.

`used` is the number of permit rows for the project and day regardless of
outcome. `limit` is `4 + sum(increment)` of grant rows for the project and
day.

Response statuses (`Status`):

| status      | meaning                                    | fields |
|-------------|--------------------------------------------|--------------|
| `admitted`  | one start consumed; `permit_id` issued     | `status`, `request_id`, `project`, `source`, `day`, `used`, `limit`, `permit_id` |
| `exhausted` | allowance for project/day used up          | `status`, `request_id`, `project`, `source`, `day`, `used`, `limit`, `reason = allowance_exhausted` |
| `busy`      | an unfinished permit exists for the project| `status`, `request_id`, `project`, `source`, `day`, `used`, `limit`, `reason = permit_active`, `active_permit` |
| `refused`   | invalid request, registry, ledger or clock | `status`, `reason` (fixed `Reason` code), optional `detail` |

There is no replay marker. `admitted`, `exhausted` and `busy` are durable and
idempotent per `request_id`: the receipt is immutable and repeating the same
request returns exactly it. A later attempt after exhaustion, a raise or a
finish needs a **new** `request_id`: the stored result is a receipt, never
fresh permission.

**Half two must bind exactly one launch to the permit identity.** An admitted
replay returns the same `permit_id`; it does not authorise a second launch.

### `finish(permit_id, outcome) -> dict`

Trusted. Closes an `active` permit exactly once with an explicit outcome in
`succeeded | failed | stopped`. Returns `{"status": "ok", "permit_id",
"project", "day", "outcome"}` or a refusal (`invalid_permit_id`,
`permit_unknown`, `permit_not_active`, `invalid_outcome`). **Never refunds
the start.** A failed launch still counts. No permit is finished
automatically at midnight, on restart or on reopen; an unfinished permit
stays `busy` until a trusted `finish`.

### `status(project) -> dict`

Read-only. Recomputes from rows for the **current** Berlin day:
`day`, `used`, `limit`, `remaining`, `active_permit` (or `None`) and
`decision_pending` (whether today's allowance-decision event exists). It never
stores or returns a waiting sentence; after a raise or a day rollover the
numbers change because the rows or the day changed.

### `raise_for_today(command_id, project, day) -> dict`

Trusted owner control. Adds `RAISE_INCREMENT = 4` starts to the project for
the current Berlin day by inserting one grant row (`command_id`, project,
day, action, increment, resulting limit, the exact result JSON).
Requirements:

* `command_id` is a canonical UUID; `project` a valid slug; `day` an ISO
  date that **equals the current Berlin day** — a stale or future day refuses
  with `day_stale`;
* an allowance-decision event is pending for that project/day, else
  `no_decision_pending`;
* an identical replay of `command_id` is inert and returns the **recorded
  response unchanged** (same `limit`, no marker), also on a later day; a
  replay with a different project, day or action refuses with
  `command_changed`.

Returns `{"status": "ok", "command_id", "project", "day", "action",
"increment", "limit"}`. Each distinct authorised command adds four; the
library does not cap the number of raises. It never admits a request,
unpauses a project, creates or finishes a permit, changes registry bytes or
launches anything.

### `keep_waiting(command_id, project, day) -> dict`

Trusted owner control with the same rules as `raise_for_today` but
`increment = 0`: it acknowledges the existing decision event and adds no
allowance.

### `close()`

Marks the handle closed; later calls refuse with `ledger_unavailable`. No
connection is held between calls, so continuing means constructing a new
`PermitLedger` on the same file — everything is in the rows.

## Registry record check

Before accounting (step 3 above) the library reads
`<registry_dir>/<slug>.yaml` as JSON. It refuses, writing nothing, when the
record is absent (`registry_missing`), a symlink or resolves outside the
registry directory (`registry_symlink`), not a regular readable file
(`registry_unreadable`), not valid JSON (`registry_malformed`), not an object
(`registry_not_object`), lacks `paused` (`registry_paused_missing`), has a
non-boolean `paused` (`registry_paused_not_boolean`) or has `paused: true`
(`project_paused`). Missing state is never defaulted. The library never
creates, writes or renames anything under the registry directory.

**Race note.** This check and half two's launch-time paused recheck are
separate obligations. This inactive library alone does not close the race
between admission and a later registry change (a project paused after its
permit was admitted).

## Ledger failure modes

| condition                                                  | result |
|------------------------------------------------------------|--------|
| file/directory cannot be opened, path is a directory, closed handle | `refused`, `ledger_unavailable` |
| not a SQLite file, failed `quick_check`, partial schema, foreign schema version | `refused`, `ledger_corrupt` |
| more than one active permit for a project, negative counts | `refused`, `ledger_inconsistent` |
| clock returns a naive datetime or raises                    | `refused`, `clock_invalid` |

Corrupt or foreign files are inspected before any pragma or write, so their
bytes stay as they were. Nothing is deleted or reinitialised and there is no
in-memory fallback allowance: when the ledger cannot answer, the answer is a
refusal.

## Invariants (all exercised by `tests/verify-permits.py`)

1. Invalid requests, registry refusals and refused controls add no request,
   permit, event or grant row and create no file.
2. One count per admitted request, counted at admission; `finish` with any
   outcome never refunds; a new resume request consumes another start.
3. At most one unfinished permit per project, across days (also enforced by a
   partial unique index); it survives midnight, DST changes, close and reopen.
4. `used` and `limit` are per project and Berlin day; other projects and
   other days are independent; the day comes only from the trusted clock.
5. Exactly one allowance-decision event per project/day, created by the first
   exhausted admission and never by a control or by the passage of time.
6. Owner commands are UUID-keyed rows; identical replay returns the recorded
   response unchanged, changed replay refuses, stale-day control refuses,
   keep waiting adds zero.
7. Every non-refused answer is durable and immutable: closing and reopening
   the file preserves requests, counts, active permits, decisions and
   commands, and a replay (same process, another process, or after reopen)
   returns exactly the receipt first issued.

## Proof

```
python3 tests/verify-permits.py      # exit 0 == correct
```

Runs from the repository root with no environment setup. It imports the
actual library, uses temporary ledgers and registries with a frozen
injectable clock, spawns real concurrent processes against one SQLite file,
crosses Berlin midnight and both 2026 DST transitions, corrupts and removes
ledgers, and exits non-zero on any failed assertion. No model, owner
transport, real registry or service is involved.

## Still required before any Gaia run (half two and deployment)

Not implemented and not claimed here:

* the **supervisor** with 45 active minutes, one extension or stop, and real
  containment of the launched process;
* **launch-once binding** of exactly one launch to each permit identity;
* the **launch-time paused recheck** of the registry record;
* **owner-channel authentication** so that `raise_for_today`, `keep_waiting`
  and `finish` are reachable only by the owner / trusted supervisor and never
  by request dispatch or an untrusted caller;
* the **kill / clean-resume proof** (a killed run leaves a permit that a new
  resume request must pay for, and nothing is auto-completed);
* wiring into `gaia-claude.sh`, the runner, gateway and cron — none of which
  are touched by this half.

Until those land: **NOT READY FOR GAIA RUNS.**
