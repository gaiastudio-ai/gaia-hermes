#!/usr/bin/env bash
# verify-paused-refuses.sh — proof that gaia-claude.sh itself refuses to start
# or continue a run on a paused project, so the `paused` flag is a gate no
# caller can step around.
#
# ATTEMPTS THE VIOLATION: starting a run on a paused project by every path a
# run can start — foreground, background, and resume after a hold the
# stakeholder answered — and through every alias of the record: the project
# given as a path, a symlink to the record, a relative path, a `../` walk, and
# records that resolve outside the registry directory. Each must be refused
# before any backend call, with exit 3, stderr exactly
# `refused: project <slug> is paused`, exactly one new project-log entry whose
# text is that string and NOTHING else changed in the record (not `updated`),
# nothing on stdout, no run record, no hold opened. A record that cannot be
# parsed, whose `paused` is not a boolean, or that resolves outside the
# registry is refused the same way with stderr exactly
# `refused: project record <file> is unreadable` and one new line in the
# registry-wide log — never read as "not paused".
#
# An unpaused project must behave exactly as on `main`: five scenarios
# (foreground start, background start, resume after an answered hold, a
# command with no directive set, a born-technical question) are run against
# main's copy of the script and against this branch's, in the same fixture
# with the clock frozen, and the exit code, the combined stdout+stderr, the
# whole $HERMES_HOME tree (run record and project record) and the stub's
# recorded invocations are compared as raw bytes. Nothing is stripped or
# normalised. As its last step it runs the existing suites unfrozen.
#
# MAIN'S COPY OF THE SCRIPT IS EMBEDDED BELOW, VERBATIM, and pinned by the
# sha256 of profile/skills/gaia-orchestrator/scripts/gaia-claude.sh at
# origin/main bec65e4d3005f8bf513ae6436b9005094a60bfae, the HEAD this task
# started from. The proof therefore needs no git ref (a checkout, a git
# archive or a merged tree all run it as-is) and can never compare the
# branch with itself: the embedded copy is checked against the pinned hash
# and must lack the gate, and the branch's copy must carry it.
#
# Runs fully isolated: throwaway $HERMES_HOME, a fake `claude` that prints
# whatever GAIA block the test stages and records its argv, hold backend
# `command` stubbed to record what it is asked to file. No model runs;
# nothing reaches a live channel.
#
#   bash tests/verify-paused-refuses.sh      # exit 0 == correct
set -eu

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_REL="profile/skills/gaia-orchestrator"
SKILL="$REPO_DIR/$SKILL_REL"
S="$SKILL/scripts"
for tool in python3 cmp diff find; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FAIL: $tool is required" >&2; exit 1; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0
pass() { printf 'PASS  %s\n' "$*"; }
flunk() { printf 'FAIL  %s\n' "$*"; fail=1; }

# ---- main's copy of the script, in a tree with the same siblings ------------
# The siblings (lib.sh, gaia-project.sh, gaia-hold.sh, references/) are not
# changed by this task, so main's skill tree is this tree with main's
# gaia-claude.sh in it.
MAIN_HEAD="bec65e4d3005f8bf513ae6436b9005094a60bfae"
MAIN_SHA256="f38f83b7f8a488a42d0daec3a10ed41c2c6b54d38c6bbf89ce68942c5ff2cd6e"
mkdir -p "$TMP/main-skill"
cp -R "$SKILL/." "$TMP/main-skill/"
MAIN_S="$TMP/main-skill/scripts"
cat >"$MAIN_S/gaia-claude.sh" <<'MAIN_GAIA_CLAUDE_SH_BEC65E4D'
#!/usr/bin/env bash
# gaia-claude.sh — run headless Claude Code (`claude -p`) on the Claude host
# for a GAIA project, and turn the result into Gaia's JSON contract.
#
# Usage:
#   gaia-claude.sh run  --project <slug|/abs/path> [--label <name>]
#                       [--resume <session_id>] [--background]
#                       [--max-turns N] [--model M] -- "<prompt>"
#   gaia-claude.sh wait   <run_id|result_file> [--timeout <seconds>]
#   gaia-claude.sh status <run_id|result_file>
#   gaia-claude.sh show   <run_id|result_file>      # full Claude JSON
#   gaia-claude.sh tail   <run_id|result_file>      # last lines of stderr log
#
# Prints ONE JSON object on stdout (see references/claude-protocol.md).
# --background returns immediately with status "running"; poll with `wait`.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

GAIA_SYSTEM_PROMPT_FILE="$GAIA_SKILL_DIR/references/claude-system-prompt.txt"

# GAIA commands whose run creates or increments an architecture revision
# (writes revision N+1). Matched exactly against the first word of the prompt.
# /gaia-edit-arch amends the existing document in place and is deliberately
# NOT listed. Space-separated; widen only with the stakeholder's say-so.
GAIA_NEW_REVISION_COMMANDS="/gaia-create-arch"

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

json_escape() { python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }

# _prompt_command <prompt> — the GAIA command a prompt starts with (first
# non-blank word), or empty.
_prompt_command() { printf '%s\n' "$1" | awk 'NF { print $1; exit }'; }

# ------------------------------------------------ refusal holds --------------
# A guard's refusal is a decision that is the stakeholder's, so the refusal
# opens the hold it stands on, at the seam where it refuses, through the
# existing gaia-hold.sh (whatever hold backend gaia.yaml configures). One hold
# per cause: the hold is keyed by its name and, while `holds.<name>` is
# pending, a repeated refusal opens nothing new — the open hold stands. Fail
# closed: when the hold cannot be opened the refusal stands anyway (same exit
# code), and the failure is logged on the project as a hold-open error.
#
# _guard_hold <slug> <name> <subject> <ask>
#   Sets GUARD_HOLD_SEND_TEXT to the card text gaia-hold.sh printed (channel
#   backend; empty otherwise or when nothing new was opened). Returns 0 when a
#   hold named <name> is pending afterwards (already open, or opened now);
#   returns 1 after logging the hold-open error. Never launches anything.
GUARD_HOLD_SEND_TEXT=""
_guard_hold() {
  local slug="$1" name="$2" subject="$3" ask="$4" status out err rc
  GUARD_HOLD_SEND_TEXT=""
  # Read-only look at the recorded hold (gaia-hold.sh check would poll the
  # command backend, which is a side effect a refusal must not have).
  status="$("$SCRIPT_DIR/gaia-project.sh" get "$slug" holds 2>/dev/null \
    | python3 -c 'import json,sys; print(((json.load(sys.stdin) or {}).get(sys.argv[1]) or {}).get("status") or "none")' "$name" 2>/dev/null)" || status="none"
  [ "$status" != pending ] || return 0
  err="$(mktemp)"
  set +e
  out="$("$SCRIPT_DIR/gaia-hold.sh" open "$slug" "$name" --subject "$subject" --ask "$ask" 2>"$err")"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    rm -f "$err"
    GUARD_HOLD_SEND_TEXT="$(printf '%s' "$out" | python3 -c 'import json,sys
try: print(json.loads(sys.stdin.read()).get("send_text") or "")
except Exception: print("")' 2>/dev/null || true)"
    return 0
  fi
  local why; why="$(tr '\n' ' ' <"$err" | cut -c1-300)"; rm -f "$err"
  "$SCRIPT_DIR/gaia-project.sh" log "$slug" "hold-open error: hold $name could not be opened for the stakeholder (gaia-hold.sh open rc=$rc): ${why:-no output}" >/dev/null 2>&1 || true
  return 1
}

# _json_or_null <text> — JSON string of <text>, or null when empty
_json_or_null() { if [ -n "$1" ]; then printf '%s' "$1" | json_escape; else printf 'null'; fi; }

# _amend_revision_guard <slug> <prompt>
# Refuse to launch a new-revision command while the project's STRUCTURED
# amend_revision field (gaia-project.sh set <slug> amend_revision <N>) is set.
# Reads the field only — never directive prose. Returns 0 (launch normally)
# when the prompt is not a new-revision command, the project has no state
# file, or amend_revision is null/absent. On refusal: opens the hold
# `amend-revision-<N>` for the stakeholder (options: amend revision N in
# place, draft a new revision, or change the directive), prints one JSON line
# on stdout, logs the refusal on the project, and exits non-zero before any
# run record exists — whether or not the hold could be opened.
_amend_revision_guard() {
  local slug="$1" prompt="$2" cmd c hit=0 amend
  cmd="$(_prompt_command "$prompt")"
  for c in $GAIA_NEW_REVISION_COMMANDS; do [ "$cmd" = "$c" ] && hit=1; done
  [ "$hit" = 1 ] || return 0
  [ -f "$GAIA_STATE_DIR/$slug.yaml" ] || return 0
  amend="$("$SCRIPT_DIR/gaia-project.sh" get "$slug" amend_revision)"
  case "$amend" in ""|null) return 0 ;; esac
  local msg amend_json hold hold_json
  msg="refused $cmd for project '$slug': amend_revision=$amend is set — amend architecture revision $amend (/gaia-edit-arch) instead of writing a new one, or clear the field with: gaia-project.sh set $slug amend_revision null"
  case "$amend" in *[!0-9]*) amend_json="$(printf '%s' "$amend" | json_escape)" ;; *) amend_json="$amend" ;; esac
  hold="amend-revision-$amend"
  if _guard_hold "$slug" "$hold" "amend_revision=$amend blocks $cmd on project $slug" \
       "Gaia refused $cmd for project '$slug': amend_revision=$amend is set. Options: (1) amend revision $amend in place (/gaia-edit-arch) — recommended; (2) draft a new revision (clear the field first: gaia-project.sh set $slug amend_revision null); (3) change the directive."; then
    msg="$msg — hold $hold is open for the stakeholder"
    hold_json="$(printf '%s' "$hold" | json_escape)"
  else
    msg="$msg — hold $hold could not be opened for the stakeholder (hold-open error logged on the project)"
    hold_json=null
  fi
  "$SCRIPT_DIR/gaia-project.sh" log "$slug" "$msg" >/dev/null || true
  printf '{"ok":false,"status":"refused","field":"amend_revision","amend_revision":%s,"command":%s,"hold":%s,"hold_send_text":%s,"message":%s}\n' \
    "$amend_json" "$(printf '%s' "$cmd" | json_escape)" "$hold_json" "$(_json_or_null "$GUARD_HOLD_SEND_TEXT")" "$(printf '%s' "$msg" | json_escape)"
  printf 'gaia: %s\n' "$msg" >&2
  exit 3
}

# ------------------------------------------------- audience guard ------------
# A GAIA-QUESTION routed by `run`/`wait` is recorded against its id under
# `question_audience.<id>` in the project state (audience, session, run, when
# asked). A question recorded audience="stakeholder" is then the
# stakeholder's: it cannot be DOWNGRADED to "technical" by the loop —
#   - a later block re-emitting that id as technical is refused (the summary
#     comes back status=refused at the recorded stakeholder audience),
#   - a `run --resume` of the session that asked it (the loop answering it
#     itself, whatever the prose says) is refused before anything launches,
# unless a hold NAMED AFTER THE QUESTION ID was opened after the question was
# asked and answered by the stakeholder (gaia-hold.sh: status approved,
# send_back or stopped with `by` not gaia — task B's rule). Only that hold
# releases it: `questions[].answered` is written by Gaia and carries no
# provenance, so it is never consulted. The refusal itself opens that hold
# (name = the question id, ask = the question's recorded text, for the
# stakeholder) through gaia-hold.sh at the seam where it exits 3 — see
# _guard_hold; while it is pending a repeated refusal opens nothing new. A
# question emitted technical from the start is not guarded (the model's first
# tagging is its own; what is the stakeholder's by nature is V3's taxonomy,
# not this guard's), and a technical question later re-emitted as stakeholder
# is simply upgraded.
#
# _audience_state <mode> <slug> [args...]   (python; state file may be absent)
#   view   <slug> <summary-json>       stdout: the summary JSON, rewritten to
#                                      status=refused on a downgrade
#   record <slug> <id> <aud> <sid> <rid> <text>   write/update the record; exit 3
#                                      (refusal JSON on stdout) on a downgrade
#   resume <slug> <sid>                exit 3 + refusal JSON when the session's
#                                      latest recorded question is an unreleased
#                                      stakeholder question; silent exit 0 otherwise
#   refresh <slug> <refusal-json> <send_text>   stdout: the refusal JSON with its
#                                      message re-read against the holds now on
#                                      file (the open-a-hold clause becomes
#                                      "hold <id> is open for the stakeholder"
#                                      once that hold is pending), plus `hold`
#                                      (the pending hold's name, else null) and
#                                      `hold_send_text` (the card, channel backend)
_audience_state() {
  need_python
  python3 - "$GAIA_STATE_DIR" "$@" <<'PY'
import sys, os, json, datetime
state_dir, mode, slug = sys.argv[1], sys.argv[2], sys.argv[3]
rest = sys.argv[4:]
try:
    import yaml
    def load(p):
        with open(p) as f: return yaml.safe_load(f) or {}
    def dump(p, d):
        tmp = p + ".tmp"
        with open(tmp, "w") as f: yaml.safe_dump(d, f, sort_keys=False, allow_unicode=True)
        os.replace(tmp, p)
except ImportError:
    def load(p):
        with open(p) as f: return json.load(f)
    def dump(p, d):
        tmp = p + ".tmp"
        with open(tmp, "w") as f: json.dump(d, f, indent=2, ensure_ascii=False)
        os.replace(tmp, p)

def now(): return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
def logline(d, msg): d.setdefault("log", []).append({"t": now(), "msg": msg})

path = os.path.join(state_dir, slug + ".yaml")
have_state = os.path.exists(path)
d = load(path) if have_state else {}
recs = d.get("question_audience") or {}

REQUIRE = "a stakeholder-answered hold is required"
def open_clause(qid):
    """The instruction to open the hold by hand: what the message says only
    while no hold named <qid> is pending (the refusal opens one itself)."""
    return (f"open one named after the question id "
            f"(gaia-hold.sh open {slug} {qid} --subject \"...\" --ask \"<the question, at its stakeholder audience>\")")
def hold_pending(qid):
    return ((d.get("holds") or {}).get(qid) or {}).get("status") == "pending"
def hold_note(qid):
    return f"hold {qid} is open for the stakeholder" if hold_pending(qid) else open_clause(qid)
def release_howto(qid):
    return (f"{REQUIRE}: {hold_note(qid)} "
            f"and let the stakeholder answer it (gaia-hold.sh answer {slug} {qid} approve|send_back|stop). "
            f"Gaia's own answers never release it: neither --by gaia (refused by gaia-hold.sh) nor a "
            f"questions[].answered value written by the loop counts as the stakeholder's word")

def released(qid, rec):
    """True when a hold named <qid> was opened no earlier than the question was
    last asked and has been answered by someone other than Gaia."""
    h = (d.get("holds") or {}).get(qid) or {}
    if h.get("status") not in ("approved", "send_back", "stopped"): return False
    by = str(h.get("by") or "").strip().lower()
    if by in ("", "gaia"): return False
    if not h.get("answered"): return False
    if str(h.get("opened") or "") < str(rec.get("asked") or ""): return False
    return True

def downgrade(qid, new_aud):
    """The (recorded, refused) pair when moving <qid> to <new_aud> is a
    stakeholder->technical downgrade without a stakeholder-answered hold."""
    rec = recs.get(qid)
    if not rec: return None
    if rec.get("audience") == "stakeholder" and new_aud == "technical" and not released(qid, rec):
        return rec
    return None

if mode == "view":
    out = json.loads(rest[0])
    qid = out.get("question_id")
    if have_state and out.get("status") == "question" and qid and downgrade(qid, out.get("audience")):
        msg = (f"refused re-tag of question '{qid}' from stakeholder to technical for project '{slug}': "
               f"it was asked with audience=stakeholder and the stakeholder has not released it — " + release_howto(qid))
        out.update({"ok": False, "status": "refused", "field": "question_audience", "audience": "stakeholder",
                    "refused_audience": "technical", "question_text": out.get("message"),
                    "asked_text": (recs.get(qid) or {}).get("text") or "", "message": msg})
    print(json.dumps(out))

elif mode == "record":
    qid, aud, sid, rid, text = rest[0], rest[1], rest[2], rest[3], rest[4]
    if not have_state: sys.exit(0)
    rec = downgrade(qid, aud)
    if rec:
        msg = (f"refused re-tag of question '{qid}' from stakeholder to technical for project '{slug}': " + release_howto(qid))
        print(json.dumps({"ok": False, "status": "refused", "field": "question_audience", "question_id": qid,
                          "audience": "stakeholder", "refused_audience": aud, "question_text": text,
                          "asked_text": rec.get("text") or "", "message": msg}))
        sys.exit(3)
    rec = recs.get(qid)
    t = now()
    if not rec:
        rec = {"id": qid, "first_audience": aud, "first_asked": t}
        logline(d, f"question {qid}: recorded audience={aud} (session {sid}, run {rid})")
    elif rec.get("audience") != aud:
        logline(d, f"question {qid}: audience {rec.get('audience')} -> {aud} (session {sid}, run {rid})"
                   + (" released by stakeholder-answered hold " + qid if rec.get("audience") == "stakeholder" else ""))
    rec.update({"audience": aud, "asked": t, "session_id": sid, "run_id": rid, "text": (text or "")[:300]})
    d.setdefault("question_audience", {})[qid] = rec
    d["updated"] = t; dump(path, d)

elif mode == "resume":
    sid = rest[0]
    if not have_state or not sid: sys.exit(0)
    mine = [r for r in recs.values() if r.get("session_id") == sid]
    if not mine: sys.exit(0)
    rec = max(mine, key=lambda r: str(r.get("asked") or ""))
    qid = rec.get("id")
    if rec.get("audience") == "stakeholder" and not released(qid, rec):
        msg = (f"refused resume of session {sid} for project '{slug}': it is waiting on question '{qid}', "
               f"asked with audience=stakeholder, and the stakeholder has not released it — the loop does not "
               f"answer a stakeholder question itself or re-tag it technical; " + release_howto(qid))
        print(json.dumps({"ok": False, "status": "refused", "field": "question_audience", "question_id": qid,
                          "audience": "stakeholder", "session_id": sid, "asked_text": rec.get("text") or "",
                          "message": msg}))
        sys.exit(3)

elif mode == "refresh":
    out = json.loads(rest[0]); send_text = rest[1] if len(rest) > 1 else ""
    qid = out.get("question_id")
    if qid and out.get("field") == "question_audience":
        # Same clause, same author: an exact swap of the open-by-hand
        # instruction for the note that the hold is now open (no-op when the
        # message already carries the note, or when no hold is pending).
        out["message"] = (out.get("message") or "").replace(open_clause(qid), hold_note(qid))
        out["hold"] = qid if hold_pending(qid) else None
        out["hold_send_text"] = send_text or None
    print(json.dumps(out))
else:
    sys.exit("gaia-claude: _audience_state view|record|resume|refresh")
PY
}

# _audience_refusal_hold <slug> <refusal-json>
# The audience guard's seam: open the hold named after the refused question
# (ask = the question's text as recorded when the stakeholder was asked it,
# `asked_text`) through _guard_hold, then re-read the refusal against the
# holds on file. Sets AUDIENCE_REFUSAL_JSON to the refreshed refusal JSON.
# Never returns non-zero: a hold that could not be opened is logged on the
# project as a hold-open error and the caller refuses exactly as before.
AUDIENCE_REFUSAL_JSON=""
_audience_refusal_hold() {
  local slug="$1" json="$2" qid qtext
  AUDIENCE_REFUSAL_JSON="$json"
  qid="$(printf '%s' "$json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("question_id") or "" if d.get("field") == "question_audience" else "")')"
  [ -n "$qid" ] || return 0
  qtext="$(printf '%s' "$json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("asked_text") or d.get("question_text") or "")')"
  [ -n "$qtext" ] || qtext="Question '$qid' was asked with audience=stakeholder (its text was not recorded); it is yours to answer."
  if ! _guard_hold "$slug" "$qid" "stakeholder question $qid" "$qtext"; then
    : # fail closed: the caller refuses regardless; the hold-open error is on the project log
  fi
  AUDIENCE_REFUSAL_JSON="$(_audience_state refresh "$slug" "$json" "$GUARD_HOLD_SEND_TEXT")"
}

# _audience_resume_guard <slug> <session_id>
# Refuse `run --resume` of a session whose latest routed question is an
# unreleased stakeholder question. Reads the structured record only. Returns
# 0 when there is no resume, no state file, no record for the session, the
# question is technical, or a stakeholder-answered hold released it. On
# refusal: the hold named after the question is opened for the stakeholder
# (nothing new if it is already pending), then one JSON line on stdout, a log
# line on the project, exit 3 before any run record exists.
_audience_resume_guard() {
  local slug="$1" sid="$2" out rc
  [ -n "$sid" ] || return 0
  [ -f "$GAIA_STATE_DIR/$slug.yaml" ] || return 0
  set +e
  out="$(_audience_state resume "$slug" "$sid")"; rc=$?
  set -e
  [ "$rc" -ne 0 ] || return 0
  [ "$rc" -eq 3 ] || die "audience guard failed (rc=$rc)"
  _audience_refusal_hold "$slug" "$out"; out="$AUDIENCE_REFUSAL_JSON"
  local msg
  msg="$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("message",""))')"
  "$SCRIPT_DIR/gaia-project.sh" log "$slug" "$msg" >/dev/null || true
  printf '%s\n' "$out"
  printf 'gaia: %s\n' "$msg" >&2
  exit 3
}

# ---------------------------------------------------------------- run --------
cmd_run() {
  local project="" label="run" resume="" background=0 max_turns="" model="" prompt=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --project) project="$2"; shift 2 ;;
      --label) label="$2"; shift 2 ;;
      --resume) resume="$2"; shift 2 ;;
      --background) background=1; shift ;;
      --max-turns) max_turns="$2"; shift 2 ;;
      --model) model="$2"; shift 2 ;;
      --) shift; prompt="$*"; break ;;
      -h|--help) usage ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [ -n "$project" ] || die "--project is required"
  [ -n "$prompt" ] || die "prompt is required after --"
  load_settings
  [ -f "$GAIA_SYSTEM_PROMPT_FILE" ] || die "missing $GAIA_SYSTEM_PROMPT_FILE"

  local slug dir
  case "$project" in
    /*|~*) dir="$project"; slug="$(basename "$project")" ;;
    *) slug="$project"; dir="$(project_path "$project")" ;;
  esac
  [ -n "$max_turns" ] || max_turns="$CLAUDE_MAX_TURNS"
  [ -n "$model" ] || model="$CLAUDE_MODEL"

  # Structured-field guard: no run id, run dir or meta file exists yet, so a
  # refusal leaves nothing under $GAIA_RUNS_DIR.
  _amend_revision_guard "$slug" "$prompt"
  # Audience guard: a resume that would answer an unreleased stakeholder
  # question is refused here, before any run record exists.
  _audience_resume_guard "$slug" "$resume"

  local run_id run_dir result_file err_file meta_file
  run_id="$(date -u +%Y%m%dT%H%M%SZ)-$(slugify "$label")"
  run_dir="$GAIA_RUNS_DIR/$slug"
  mkdir -p "$run_dir"
  result_file="$run_dir/$run_id.json"
  err_file="$run_dir/$run_id.stderr.log"
  meta_file="$run_dir/$run_id.meta"

  # Build the claude argv.
  set -- "$CLAUDE_BIN" -p --output-format json --dangerously-skip-permissions \
         --max-turns "$max_turns" \
         --append-system-prompt "$(cat "$GAIA_SYSTEM_PROMPT_FILE")"
  [ -n "$model" ] && set -- "$@" --model "$model"
  if [ "${CLAUDE_MAX_BUDGET:-0}" != "0" ] && [ -n "${CLAUDE_MAX_BUDGET:-}" ]; then
    set -- "$@" --max-budget-usd "$CLAUDE_MAX_BUDGET"
  fi
  [ -n "$resume" ] && set -- "$@" --resume "$resume"
  set -- "$@" "$prompt"

  {
    printf 'run_id=%s\nslug=%s\ndir=%s\nlabel=%s\nresume=%s\nstarted=%s\n' \
      "$run_id" "$slug" "$dir" "$label" "$resume" "$(now_iso)"
  } >"$meta_file"

  if [ "$background" = 1 ]; then
    (
      _execute "$dir" "$result_file" "$err_file" "$meta_file" "$@"
    ) >/dev/null 2>&1 </dev/null &
    disown 2>/dev/null || true
    printf '{"ok":true,"run_id":%s,"status":"running","result_file":%s,"message":"started in background; poll with: gaia-claude.sh wait %s"}\n' \
      "$(printf '%s' "$run_id" | json_escape)" "$(printf '%s' "$result_file" | json_escape)" "$run_id"
    return 0
  fi

  _execute "$dir" "$result_file" "$err_file" "$meta_file" "$@"
  _summarize "$result_file" | _record_state
}

# _record_state — pass-through filter: prints the summary JSON unchanged and,
# when a state file exists for the slug, records session/run/command on it,
# plus the audience of a routed question under question_audience.<id>.
# A summary already marked status=refused by the audience guard (a
# stakeholder question re-emitted as technical) opens the hold named after
# the question for the stakeholder (nothing new if it is already pending),
# then is printed, logged on the project, and exits 3: nothing is recorded
# for that run or question, whether or not the hold could be opened.
_record_state() {
  local json; json="$(cat)"
  local slug="" meta; meta="$(printf '%s' "$json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("result_file",""))')"
  meta="${meta%.json}.meta"
  [ -f "$meta" ] && slug="$(sed -n 's/^slug=//p' "$meta")"
  if [ -z "$slug" ] || [ ! -f "$GAIA_STATE_DIR/$slug.yaml" ]; then
    printf '%s\n' "$json"; return 0
  fi
  local sid rid st label
  sid="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("session_id") or "")')"
  rid="$(sed -n 's/^run_id=//p' "$meta")"; label="$(sed -n 's/^label=//p' "$meta")"
  st="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status") or "")')"
  if [ "$st" = refused ]; then
    local msg
    _audience_refusal_hold "$slug" "$json"; json="$AUDIENCE_REFUSAL_JSON"
    printf '%s\n' "$json"
    msg="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("message") or "")')"
    "$SCRIPT_DIR/gaia-project.sh" log "$slug" "run $rid ($label) -> refused: $msg" >/dev/null || true
    printf 'gaia: %s\n' "$msg" >&2
    exit 3
  fi
  printf '%s\n' "$json"
  [ -n "$sid" ] && "$SCRIPT_DIR/gaia-project.sh" set "$slug" last_session_id "$sid" >/dev/null
  "$SCRIPT_DIR/gaia-project.sh" set "$slug" last_run_id "$rid" >/dev/null
  "$SCRIPT_DIR/gaia-project.sh" set "$slug" last_command "$label" >/dev/null
  "$SCRIPT_DIR/gaia-project.sh" log "$slug" "run $rid ($label) -> $st" >/dev/null
  if [ "$st" = question ]; then
    local qid aud text
    qid="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("question_id") or "")')"
    aud="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("audience") or "")')"
    text="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("message") or "")')"
    if [ -n "$qid" ]; then
      _audience_state record "$slug" "$qid" "$aud" "$sid" "$rid" "$text"
    fi
  fi
}

# _execute <dir> <result_file> <err_file> <meta_file> <argv...>
_execute() {
  local dir="$1" result_file="$2" err_file="$3" meta_file="$4"; shift 4
  local start end rc
  start=$(date +%s)
  set +e
  host_exec_in "$dir" "$@" >"$result_file.partial" 2>"$err_file"
  rc=$?
  set -e
  end=$(date +%s)
  printf 'exit=%s\nfinished=%s\nduration_s=%s\n' "$rc" "$(now_iso)" "$((end - start))" >>"$meta_file"
  mv "$result_file.partial" "$result_file"
}

# _summarize <result_file> — parse Claude JSON + markers into Gaia's contract,
# then pass the summary through the audience guard's read-only view: a
# question re-emitted as technical while recorded stakeholder comes back
# status=refused at audience=stakeholder (run, wait and status all agree).
_summarize() {
  local result_file="$1" meta_file="${1%.json}.meta" slug raw
  slug="$(sed -n 's/^slug=//p' "$meta_file" 2>/dev/null || true)"
  raw="$(_summarize_raw "$result_file")"
  _audience_state view "$slug" "$raw"
}

# _summarize_raw <result_file> — the parse itself, audience taken as emitted
_summarize_raw() {
  local result_file="$1" meta_file="${1%.json}.meta" err_file="${1%.json}.stderr.log"
  need_python
  python3 - "$result_file" "$meta_file" "$err_file" <<'PY'
import json, re, sys, os
result_file, meta_file, err_file = sys.argv[1:4]
meta = {}
for line in open(meta_file):
    k, _, v = line.rstrip('\n').partition('=')
    meta[k] = v
out = {
    "ok": True, "run_id": meta.get("run_id"), "session_id": None, "status": "error",
    "audience": None, "question_id": None, "message": "", "num_turns": None,
    "cost_usd": None, "duration_s": int(meta.get("duration_s") or 0),
    "result_file": result_file,
}
raw = open(result_file).read().strip()
stderr = open(err_file).read().strip() if os.path.exists(err_file) else ""
data = None
if raw:
    # Claude prints exactly one JSON object with --output-format json; tolerate
    # stray lines (warnings) around it.
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        m = re.search(r'\{.*\}\s*$', raw, re.S)
        if m:
            try:
                data = json.loads(m.group(0))
            except json.JSONDecodeError:
                data = None
rc = meta.get("exit", "1")
if data is None:
    out["ok"] = False
    out["message"] = (f"claude exited {rc} without JSON output. stderr: {stderr[-1500:]}" if stderr
                      else f"claude exited {rc} without JSON output: {raw[-1500:]}")
    print(json.dumps(out)); sys.exit(0)

out["session_id"] = data.get("session_id")
out["num_turns"] = data.get("num_turns")
out["cost_usd"] = data.get("total_cost_usd")
text = data.get("result") or ""
if data.get("is_error") or rc not in ("0", ""):
    out["ok"] = False
    out["status"] = "error"
    out["message"] = (text or stderr or f"claude exited {rc}")[-3000:]
    print(json.dumps(out)); sys.exit(0)

def block(tag):
    m = re.search(r'<<GAIA-' + tag + r'(?P<attrs>[^>]*)>>\s*(?P<body>.*?)\s*<<END-GAIA-' + tag + r'>>', text, re.S)
    if not m:
        # tolerate a missing END marker at the very end of the text
        m = re.search(r'<<GAIA-' + tag + r'(?P<attrs>[^>]*)>>\s*(?P<body>.*)$', text, re.S)
    return m

q = block("QUESTION")
d = block("DONE")
b = block("BLOCKED")
def attr(m, name):
    a = re.search(name + r'="([^"]*)"', m.group("attrs") or "")
    return a.group(1) if a else None

if q:
    out["status"] = "question"
    out["audience"] = attr(q, "audience") or "stakeholder"
    out["question_id"] = attr(q, "id")
    out["message"] = q.group("body").strip()
elif b:
    out["status"] = "blocked"
    out["question_id"] = attr(b, "reason")
    out["message"] = b.group("body").strip()
elif d:
    out["status"] = "done"
    out["message"] = d.group("body").strip()
else:
    out["status"] = "ended"
    # Heuristic: a trailing question mark usually means an un-tagged question.
    tail = text.strip()[-600:]
    if tail.rstrip().endswith("?"):
        out["status"] = "question"
        out["audience"] = "stakeholder"
    out["message"] = text.strip()[-3000:]
print(json.dumps(out))
PY
}

# ------------------------------------------------------------ helpers --------
_resolve_result() {
  local ref="$1"
  case "$ref" in
    *.json) [ -f "$ref" ] && printf '%s' "$ref" && return 0 ;;
  esac
  local f
  f=$(find "$GAIA_RUNS_DIR" -name "$ref.json" -o -name "$ref.meta" 2>/dev/null | sed 's/\.meta$/.json/' | head -n1)
  [ -n "$f" ] || die "run not found: $ref"
  printf '%s' "$f"
}

cmd_status() {
  local f meta
  f="$(_resolve_result "$1")"; meta="${f%.json}.meta"
  if [ -f "$f" ] && grep -q '^exit=' "$meta" 2>/dev/null; then
    _summarize "$f"
  else
    printf '{"ok":true,"run_id":%s,"status":"running","result_file":%s}\n' \
      "$(printf '%s' "$(basename "${f%.json}")" | json_escape)" "$(printf '%s' "$f" | json_escape)"
  fi
}

cmd_wait() {
  local ref="$1"; shift
  local timeout=240 waited=0
  while [ $# -gt 0 ]; do
    case "$1" in --timeout) timeout="$2"; shift 2 ;; *) shift ;; esac
  done
  local f meta
  f="$(_resolve_result "$ref")"; meta="${f%.json}.meta"
  while ! grep -q '^exit=' "$meta" 2>/dev/null; do
    if [ "$waited" -ge "$timeout" ]; then
      printf '{"ok":true,"run_id":%s,"status":"running","waited_s":%s,"result_file":%s,"message":"still running; call wait again"}\n' \
        "$(printf '%s' "$(basename "${f%.json}")" | json_escape)" "$waited" "$(printf '%s' "$f" | json_escape)"
      return 0
    fi
    sleep 5; waited=$((waited + 5))
  done
  # tiny grace period for the mv of .partial -> .json
  sleep 1
  _summarize "$f" | _record_state
}

cmd_show() { cat "$(_resolve_result "$1")"; }
cmd_tail() { tail -n "${2:-40}" "$(_resolve_result "$1" | sed 's/\.json$/.stderr.log/')"; }

# --------------------------------------------------------------- main --------
[ $# -ge 1 ] || usage
sub="$1"; shift
case "$sub" in
  run) cmd_run "$@" ;;
  wait) cmd_wait "$@" ;;
  status) cmd_status "$@" ;;
  show) cmd_show "$@" ;;
  tail) cmd_tail "$@" ;;
  *) usage ;;
esac
MAIN_GAIA_CLAUDE_SH_BEC65E4D
chmod +x "$MAIN_S/gaia-claude.sh"
have_sha="$(python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$MAIN_S/gaia-claude.sh")"
if [ "$have_sha" != "$MAIN_SHA256" ]; then
  echo "FAIL: the embedded copy of main's gaia-claude.sh does not hash to $MAIN_SHA256 (got $have_sha)" >&2
  exit 1
fi
pass "main's copy: embedded gaia-claude.sh hashes to $MAIN_SHA256 (origin/main $MAIN_HEAD)"
if grep -q '_paused_guard' "$MAIN_S/gaia-claude.sh"; then
  echo "FAIL: main's copy carries the paused gate; the comparison would be against itself" >&2
  exit 1
fi
if ! grep -q '_paused_guard' "$S/gaia-claude.sh"; then
  echo "FAIL: $S/gaia-claude.sh carries no paused gate; there is nothing to compare" >&2
  exit 1
fi
if cmp -s "$MAIN_S/gaia-claude.sh" "$S/gaia-claude.sh"; then
  echo "FAIL: the branch's gaia-claude.sh is byte-identical to main's; this is a self-comparison" >&2
  exit 1
fi
pass "main's copy lacks the paused gate and the branch's copy carries it: the comparison is not against itself"

# ---- fixture ------------------------------------------------------------------
export HERMES_HOME="$TMP/hermes"
export GAIA_SETTINGS="$HERMES_HOME/gaia.yaml"
export GAIA_STATE_DIR="$HERMES_HOME/projects"
export GAIA_RUNS_DIR="$HERMES_HOME/gaia-runs"
mkdir -p "$HERMES_HOME" "$GAIA_STATE_DIR" "$GAIA_RUNS_DIR" "$TMP/bin" "$TMP/projects"

# Fake claude: prints one Claude-shaped JSON whose `result` is the staged block.
# Records its full argv (claude.argv) and one line per invocation (claude.calls).
cat >"$TMP/bin/claude" <<EOF
#!/usr/bin/env bash
printf 'call\n' >>"$TMP/claude.calls"
printf '%s\n' "\$*" >>"$TMP/claude.argv"
python3 - "$TMP/stage.result" "$TMP/stage.session" <<'PY'
import json, sys
print(json.dumps({"session_id": open(sys.argv[2]).read().strip(), "is_error": False, "num_turns": 1,
                  "total_cost_usd": 0, "result": open(sys.argv[1]).read()}))
PY
EOF
chmod +x "$TMP/bin/claude"
: >"$TMP/claude.argv"; : >"$TMP/claude.calls"

# Stubbed hold backend (hold_backend: command): records what it is asked to file.
cat >"$TMP/hold-file.sh" <<EOF
#!/usr/bin/env bash
printf '%s\t%s\t%s\n' "\$HOLD_NAME" "\$HOLD_SUBJECT" "\$HOLD_ASK" >>"$TMP/holds.filed"
n=\$(wc -l <"$TMP/holds.filed" | tr -d ' ')
printf '{"id": "stub-%s"}\n' "\$n"
EOF
cat >"$TMP/hold-status.sh" <<'EOF'
#!/usr/bin/env bash
echo pending
EOF
chmod +x "$TMP/hold-file.sh" "$TMP/hold-status.sh"
: >"$TMP/holds.filed"

cat >"$GAIA_SETTINGS" <<EOF
claude:
  mode: local
  bin: $TMP/bin/claude
  model: ""
  max_turns: 5
  max_budget_usd: 0
projects_root: $TMP/projects
hold_backend: command
hold_commands:
  file: "$TMP/hold-file.sh"
  status: "$TMP/hold-status.sh"
EOF

# ---- frozen clock -------------------------------------------------------------
# Every `date` the shell scripts call and every datetime.now() the python parts
# call answers 2026-09-23T00:00:00Z, so run ids, timestamps and durations are
# reproducible between main's copy and this branch's.
FROZEN_EPOCH=1790121600
FROZEN_STAMP="20260923T000000Z"
FROZEN_ISO="2026-09-23T00:00:00Z"
ORIG_PATH="$PATH"
ORIG_PYTHONPATH="${PYTHONPATH-}"
ORIG_PYTHONPATH_SET="${PYTHONPATH+set}"
mkdir -p "$TMP/frozen/bin" "$TMP/frozen/py"
cat >"$TMP/frozen/bin/date" <<EOF
#!/usr/bin/env bash
# frozen clock for the fixture: every date the scripts ask for is $FROZEN_ISO
fmt=""
for a in "\$@"; do
  case "\$a" in
    -u) ;;
    +%s) printf '%s\n' "$FROZEN_EPOCH"; exit 0 ;;
    +*) fmt="\${a#+}" ;;
    *) printf 'frozen date: unsupported argument %s\n' "\$a" >&2; exit 1 ;;
  esac
done
python3 -c 'import sys, datetime; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime(sys.argv[2]))' "$FROZEN_EPOCH" "\${fmt:-%c}"
EOF
chmod +x "$TMP/frozen/bin/date"
cat >"$TMP/frozen/py/sitecustomize.py" <<EOF
# frozen clock for the fixture: datetime.datetime.now() is always $FROZEN_ISO
import datetime as _dt
_FROZEN = $FROZEN_EPOCH
_real = _dt.datetime
class _FrozenDatetime(_real):
    @classmethod
    def now(cls, tz=None):
        if tz is None:
            return _real.fromtimestamp(_FROZEN, _dt.timezone.utc).replace(tzinfo=None)
        return _real.fromtimestamp(_FROZEN, tz)
_dt.datetime = _FrozenDatetime
EOF
export PATH="$TMP/frozen/bin:$PATH"
export PYTHONPATH="$TMP/frozen/py"
if [ "$(date -u +%Y%m%dT%H%M%SZ)" != "$FROZEN_STAMP" ] || [ "$(date +%s)" != "$FROZEN_EPOCH" ]; then
  echo "FAIL: fixture: shell clock not frozen: $(date -u +%Y%m%dT%H%M%SZ) $(date +%s)" >&2; exit 1
fi
if [ "$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')" != "$FROZEN_ISO" ]; then
  echo "FAIL: fixture: python clock not frozen" >&2; exit 1
fi
pass "fixture: shell and python clocks frozen at $FROZEN_ISO"

# ---- helpers ------------------------------------------------------------------
launches() { wc -l <"$TMP/claude.calls" | tr -d ' '; }
filed() { wc -l <"$TMP/holds.filed" | tr -d ' '; }
run_files() { find "$GAIA_RUNS_DIR" -type f | sort; }
registry_log_lines() { if [ -f "$GAIA_STATE_DIR/registry.log" ]; then wc -l <"$GAIA_STATE_DIR/registry.log" | tr -d ' '; else echo 0; fi; }
# stage <session_id> <audience> <id> <text> — what the next fake claude run emits
stage() {
  printf '%s' "$1" >"$TMP/stage.session"
  printf '<<GAIA-QUESTION audience="%s" id="%s">>\n%s\n<<END-GAIA-QUESTION>>' "$2" "$3" "$4" >"$TMP/stage.result"
}
stage_done() { printf '%s' "$1" >"$TMP/stage.session"; printf '<<GAIA-DONE>>done<<END-GAIA-DONE>>' >"$TMP/stage.result"; }
# state_py <record file> <python expr over d>
state_py() {
  python3 - "$1" "$2" <<'PY'
import sys, json
try:
    import yaml
    d = yaml.safe_load(open(sys.argv[1])) or {}
except ImportError:
    d = json.load(open(sys.argv[1]))
v = eval(sys.argv[2], {"d": d})
print("" if v is None else v)
PY
}
# json_field <field> — from the LAST JSON line of $OUT
json_field() {
  printf '%s\n' "$OUT" | python3 -c '
import sys, json
val = None
for line in sys.stdin:
    line = line.strip()
    if line.startswith("{"):
        try: val = json.loads(line).get(sys.argv[1])
        except json.JSONDecodeError: pass
print("" if val is None else val)' "$1"
}
# snapshot <name> / restore <name> — the whole $HERMES_HOME plus the stub logs
snapshot() { rm -rf "$TMP/snap/$1"; mkdir -p "$TMP/snap/$1"; cp -a "$HERMES_HOME" "$TMP/snap/$1/hermes"; }
restore() {
  rm -rf "$HERMES_HOME"; cp -a "$TMP/snap/$1/hermes" "$HERMES_HOME"
  : >"$TMP/claude.argv"; : >"$TMP/claude.calls"; : >"$TMP/holds.filed"
}
# run_split <scripts dir> <args...> -> RC, $TMP/cur.out, $TMP/cur.err (the command under test)
run_split() {
  local sdir="$1"; shift
  set +e
  bash "$sdir/gaia-claude.sh" run "$@" >"$TMP/cur.out" 2>"$TMP/cur.err"
  RC=$?
  set -e
}
# run_both <scripts dir> <args...> -> RC, $TMP/cur.both (combined stdout+stderr)
run_both() {
  local sdir="$1"; shift
  set +e
  bash "$sdir/gaia-claude.sh" run "$@" >"$TMP/cur.both" 2>&1
  RC=$?
  set -e
}
# wait_for_file <file> — a background run's record; fails the test after 30s
wait_for_file() {
  local n=0
  while [ ! -f "$1" ]; do
    sleep 0.2; n=$((n + 1))
    if [ "$n" -ge 150 ]; then echo "FAIL: background run never wrote $1" >&2; exit 1; fi
  done
}
# record_gained_one_line <before> <after> <msg>
# True when <after> is <before> with exactly one entry appended to `log`,
# {"t": $FROZEN_ISO, "msg": <msg>}, and NOTHING else different: every other
# key, `updated` included, compares equal.
record_gained_one_line() {
  python3 - "$1" "$2" "$3" "$FROZEN_ISO" <<'PY'
import sys, json
try:
    import yaml
    load = lambda p: yaml.safe_load(open(p)) or {}
except ImportError:
    load = lambda p: json.load(open(p))
a, b = load(sys.argv[1]), load(sys.argv[2])
msg, t = sys.argv[3], sys.argv[4]
a_log, b_log = list(a.get("log") or []), list(b.get("log") or [])
ok = b_log == a_log + [{"t": t, "msg": msg}]
a["log"] = a_log; b["log"] = a_log
print(ok and a == b)
PY
}

SLUG="pauseproof"
RECORD="$GAIA_STATE_DIR/$SLUG.yaml"
PAUSED_MSG="refused: project $SLUG is paused"

# ---- setup: an unpaused project with an answered hold on a stakeholder question
mkdir -p "$TMP/projects/$SLUG"
bash "$S/gaia-project.sh" init "$SLUG" --name "Paused proof" --path "$TMP/projects/$SLUG" >/dev/null
stage sess-q stakeholder vendor "Which vendor do we pay for?"
run_both "$S" --project "$SLUG" --label ask -- "/gaia-create-prd"
OUT="$(cat "$TMP/cur.both")"
[ "$RC" -eq 0 ] && [ "$(json_field status)" = question ] && [ "$(json_field audience)" = stakeholder ] \
  && pass "setup: stakeholder question 'vendor' asked in session sess-q (rc=0)" || flunk "setup: rc=$RC: $OUT"
bash "$S/gaia-hold.sh" open "$SLUG" vendor --subject "vendor" --ask "Which vendor do we pay for?" >/dev/null
bash "$S/gaia-hold.sh" answer "$SLUG" vendor approve --by Julien >/dev/null
[ "$(state_py "$RECORD" "d['holds']['vendor']['status']")" = approved ] && [ "$(filed)" = 1 ] \
  && pass "setup: hold 'vendor' opened through the stub backend and answered by the stakeholder" || flunk "setup: hold not answered"
[ "$(state_py "$RECORD" "d.get('paused')")" = False ] && [ "$(state_py "$RECORD" "'directive' in d")" = False ] \
  && pass "setup: project is not paused and has no directive set" || flunk "setup: record: $(cat "$RECORD")"
snapshot unpaused
bash "$S/gaia-project.sh" set "$SLUG" paused true >/dev/null
[ "$(state_py "$RECORD" "d.get('paused')")" = True ] && pass "setup: project paused (paused: true)" || flunk "setup: could not pause"
# Arm the "nothing else changed" assertion: with the clock frozen, `updated`
# already reads $FROZEN_ISO, so a refusal that re-stamped it to "now" would be
# invisible. Stamp the paused record's `updated` with a distinct value so any
# re-stamp shows up as a changed field.
UPDATED_SENTINEL="2026-09-22T12:34:56Z"
python3 - "$RECORD" "$UPDATED_SENTINEL" <<'PY'
import sys, os
try:
    import yaml
    def load(p):
        with open(p) as f: return yaml.safe_load(f)
    def dump(p, d):
        tmp = p + ".tmp"
        with open(tmp, "w") as f: yaml.safe_dump(d, f, sort_keys=False, allow_unicode=True)
        os.replace(tmp, p)
except ImportError:
    import json
    def load(p):
        with open(p) as f: return json.load(f)
    def dump(p, d):
        tmp = p + ".tmp"
        with open(tmp, "w") as f: json.dump(d, f, indent=2, ensure_ascii=False)
        os.replace(tmp, p)
d = load(sys.argv[1]); d["updated"] = sys.argv[2]; dump(sys.argv[1], d)
PY
[ "$(state_py "$RECORD" "d.get('updated')")" = "$UPDATED_SENTINEL" ] && [ "$UPDATED_SENTINEL" != "$FROZEN_ISO" ] \
  && pass "setup: paused record's 'updated' is $UPDATED_SENTINEL, distinct from the frozen now, so a re-stamp would be visible" \
  || flunk "setup: could not stamp 'updated': $(state_py "$RECORD" "d.get('updated')")"
snapshot paused

# ---- refused_paused <label> <snapshot> <args...> ------------------------------
# From <snapshot>, the run must: exit 3; print nothing on stdout; print exactly
# "$PAUSED_MSG\n" on stderr; launch nothing; file no hold; write no run file;
# append exactly one log entry whose text is $PAUSED_MSG to $RECORD and change
# nothing else in it (`updated` included); create no other file in the
# registry; leave the registry-wide log alone.
refused_paused() {
  local label="$1" snap="$2"; shift 2
  restore "$snap"
  local files_before state_before reglog_before
  files_before="$(run_files)"; reglog_before="$(registry_log_lines)"
  cp "$RECORD" "$TMP/record.before"
  state_before="$(find "$GAIA_STATE_DIR" | sort)"
  run_split "$S" "$@"
  [ "$RC" -eq 3 ] && pass "$label: exits 3" || flunk "$label: rc=$RC: $(cat "$TMP/cur.out" "$TMP/cur.err")"
  [ ! -s "$TMP/cur.out" ] && pass "$label: nothing on stdout" || flunk "$label: stdout: $(cat "$TMP/cur.out")"
  printf '%s\n' "$PAUSED_MSG" >"$TMP/want.err"
  cmp -s "$TMP/want.err" "$TMP/cur.err" && pass "$label: stderr is exactly '$PAUSED_MSG'" \
    || flunk "$label: stderr is '$(cat "$TMP/cur.err")'"
  [ "$(launches)" = 0 ] && pass "$label: the claude stub was not invoked" || flunk "$label: claude invoked: $(cat "$TMP/claude.argv")"
  [ "$(filed)" = 0 ] && pass "$label: no hold filed with the backend" || flunk "$label: holds filed: $(cat "$TMP/holds.filed")"
  [ "$(run_files)" = "$files_before" ] && pass "$label: no run record written" || flunk "$label: run files changed: $(run_files)"
  [ "$(state_py "$RECORD" "d['log'][-1]['msg']")" = "$PAUSED_MSG" ] && pass "$label: the project log's new line is '$PAUSED_MSG'" \
    || flunk "$label: last log line: $(state_py "$RECORD" "d['log'][-1]['msg']")"
  [ "$(record_gained_one_line "$TMP/record.before" "$RECORD" "$PAUSED_MSG")" = True ] \
    && pass "$label: exactly one new log line; every other field of the record, 'updated' included, is unchanged" \
    || flunk "$label: record changed beyond one log line:
$(diff "$TMP/record.before" "$RECORD")"
  [ "$(state_py "$RECORD" "d.get('updated')")" = "$UPDATED_SENTINEL" ] && pass "$label: 'updated' still reads $UPDATED_SENTINEL (not re-stamped)" \
    || flunk "$label: 'updated' was re-stamped to $(state_py "$RECORD" "d.get('updated')")"
  [ "$(find "$GAIA_STATE_DIR" | sort)" = "$state_before" ] && pass "$label: no other file in the registry" \
    || flunk "$label: registry files changed: $(find "$GAIA_STATE_DIR" | sort)"
  [ "$(registry_log_lines)" = "$reglog_before" ] && pass "$label: registry-wide log untouched" || flunk "$label: registry log written"
}

# ---- refused_unreadable <label> <file> <args...> ------------------------------
# Same, for a record that cannot be resolved inside the registry or parsed
# (the caller stages the registry first): stderr exactly "refused: project
# record <file> is unreadable\n", one new line in the registry-wide log ending
# in that string, no project record touched.
refused_unreadable() {
  local label="$1" file="$2"; shift 2
  local msg="refused: project record $file is unreadable"
  local files_before reglog_before
  files_before="$(run_files)"; reglog_before="$(registry_log_lines)"
  rm -rf "$TMP/state.before"; cp -a "$GAIA_STATE_DIR" "$TMP/state.before"
  run_split "$S" "$@"
  [ "$RC" -eq 3 ] && pass "$label: exits 3" || flunk "$label: rc=$RC: $(cat "$TMP/cur.out" "$TMP/cur.err")"
  [ ! -s "$TMP/cur.out" ] && pass "$label: nothing on stdout" || flunk "$label: stdout: $(cat "$TMP/cur.out")"
  printf '%s\n' "$msg" >"$TMP/want.err"
  cmp -s "$TMP/want.err" "$TMP/cur.err" && pass "$label: stderr is exactly '$msg'" || flunk "$label: stderr is '$(cat "$TMP/cur.err")'"
  [ "$(launches)" = 0 ] && pass "$label: the claude stub was not invoked" || flunk "$label: claude invoked: $(cat "$TMP/claude.argv")"
  [ "$(filed)" = 0 ] && pass "$label: no hold filed with the backend" || flunk "$label: holds filed"
  [ "$(run_files)" = "$files_before" ] && pass "$label: no run record written" || flunk "$label: run files changed"
  [ "$(registry_log_lines)" = "$((reglog_before + 1))" ] && pass "$label: registry-wide log gained exactly one line" \
    || flunk "$label: registry log lines: $reglog_before -> $(registry_log_lines)"
  case "$(tail -n 1 "$GAIA_STATE_DIR/registry.log")" in
    *"$msg") pass "$label: that line ends with '$msg'" ;;
    *) flunk "$label: registry log line: $(tail -n 1 "$GAIA_STATE_DIR/registry.log")" ;;
  esac
  if diff -r -x registry.log "$TMP/state.before" "$GAIA_STATE_DIR" >"$TMP/state.diff"; then
    pass "$label: no project record touched"
  else
    flunk "$label: registry changed: $(cat "$TMP/state.diff")"
  fi
}

# ---- 1. paused: every path a run can start ----------------------------------
stage_done sess-fg
refused_paused "paused, foreground" paused --project "$SLUG" --label fg -- "/gaia-init"
stage_done sess-bg
refused_paused "paused, background" paused --project "$SLUG" --label bg --background -- "/gaia-init"
sleep 1
[ "$(launches)" = 0 ] && [ "$(run_files | wc -l | tr -d ' ')" = "$(find "$TMP/snap/paused/hermes/gaia-runs" -type f | wc -l | tr -d ' ')" ] \
  && pass "paused, background: still nothing launched, no run record a second later" \
  || flunk "paused, background: something ran after the refusal"
stage_done sess-q
refused_paused "paused, resume after an answered hold" paused --project "$SLUG" --label resume --resume sess-q -- "Decision: approve. Continue."
refused_paused "paused, project given as a path" paused --project "$TMP/projects/$SLUG" --label path -- "/gaia-init"

# ---- 2. paused, reached by an alias of the record ----------------------------
restore paused; ln -s "$SLUG.yaml" "$GAIA_STATE_DIR/alias.yaml"; snapshot paused-alias
refused_paused "paused, symlink to the record (alias -> $SLUG)" paused-alias --project alias --label alias -- "/gaia-init"
[ -L "$GAIA_STATE_DIR/alias.yaml" ] && [ "$(readlink "$GAIA_STATE_DIR/alias.yaml")" = "$SLUG.yaml" ] \
  && pass "paused, symlink to the record: the symlink is still a symlink to $SLUG.yaml (the log went to the real record)" \
  || flunk "paused, symlink to the record: alias.yaml was replaced"
refused_paused "paused, relative path (./$SLUG)" paused --project "./$SLUG" --label rel -- "/gaia-init"
refused_paused "paused, ../ walk (../projects/$SLUG)" paused --project "../projects/$SLUG" --label walk -- "/gaia-init"

# ---- 3. records outside the registry directory are never read ---------------
# An UNPAUSED record placed outside the registry: if it were read, the run
# would proceed. It must be refused unread, as unreadable.
restore paused
cp "$TMP/snap/unpaused/hermes/projects/$SLUG.yaml" "$HERMES_HOME/outside.yaml"
ln -s "$HERMES_HOME/outside.yaml" "$GAIA_STATE_DIR/escape.yaml"
cp "$HERMES_HOME/outside.yaml" "$TMP/outside.before"
refused_unreadable "outside the registry, ../ walk (../outside)" outside.yaml --project ../outside --label out1 -- "/gaia-init"
refused_unreadable "outside the registry, symlink out (escape -> ../outside.yaml)" escape.yaml --project escape --label out2 -- "/gaia-init"
cmp -s "$TMP/outside.before" "$HERMES_HOME/outside.yaml" && pass "outside the registry: the outside record is untouched" \
  || flunk "outside the registry: the outside record was written"

# ---- 4. malformed state fails closed -----------------------------------------
restore unpaused
printf '{ [\n' >"$GAIA_STATE_DIR/broken.yaml"
python3 - "$RECORD" "$GAIA_STATE_DIR" <<'PY'
import sys, os, json
src, state_dir = sys.argv[1], sys.argv[2]
try:
    import yaml
    def load(p):
        with open(p) as f: return yaml.safe_load(f)
    def dump(p, d):
        with open(p, "w") as f: yaml.safe_dump(d, f, sort_keys=False)
except ImportError:
    def load(p):
        with open(p) as f: return json.load(f)
    def dump(p, d):
        with open(p, "w") as f: json.dump(d, f, indent=2)
base = load(src)
for name, val in (("nonbool", 1), ("strbool", "true")):
    d = dict(base); d["slug"] = name; d["paused"] = val; dump(os.path.join(state_dir, name + ".yaml"), d)
d = dict(base); d["slug"] = "nokey"; del d["paused"]; dump(os.path.join(state_dir, "nokey.yaml"), d)
PY
refused_unreadable "malformed: unparseable record" broken.yaml --project broken --label m1 -- "/gaia-init"
refused_unreadable "malformed: paused is an integer (1)" nonbool.yaml --project nonbool --label m2 -- "/gaia-init"
refused_unreadable "malformed: paused is a string (\"true\")" strbool.yaml --project strbool --label m3 -- "/gaia-init"
refused_unreadable "malformed: no paused key (fails closed, never 'not paused')" nokey.yaml --project nokey --label m4 -- "/gaia-init"
refused_unreadable "no such record" nosuch.yaml --project nosuch --label m5 -- "/gaia-init"

# ---- 5. unpaused: byte-identical to main, scenario by scenario ---------------
# compare_scenario <name> <stage args...> -- <run args...>
# From the `unpaused` snapshot, runs the scenario against main's copy and
# against this branch's copy, capturing for each: the exit code, the combined
# stdout+stderr, the whole $HERMES_HOME tree (run record, project record,
# settings) and the stub logs. Both must exit 0 and invoke the stub once, and
# the two raw captures must not differ in a single byte.
compare_scenario() {
  local name="$1"; shift
  local stage_kind="$1"; shift
  local stage_args=()
  while [ "$1" != "--" ]; do stage_args+=("$1"); shift; done
  shift
  local copy sdir bg=0 a
  for a in "$@"; do [ "$a" = "--background" ] && bg=1; done
  for copy in main branch; do
    if [ "$copy" = main ]; then sdir="$MAIN_S"; else sdir="$S"; fi
    restore unpaused
    if [ "$stage_kind" = done ]; then stage_done "${stage_args[@]}"; else stage "${stage_args[@]}"; fi
    run_both "$sdir" "$@"
    if [ "$bg" = 1 ]; then wait_for_file "$GAIA_RUNS_DIR/$SLUG/$FROZEN_STAMP-$name.json"; fi
    local cap="$TMP/cap/$name/$copy"
    rm -rf "$cap"; mkdir -p "$cap"
    printf '%s\n' "$RC" >"$cap/rc"
    cp "$TMP/cur.both" "$cap/out"
    cp -a "$HERMES_HOME" "$cap/hermes"
    cp "$TMP/claude.argv" "$cap/claude.argv"; cp "$TMP/claude.calls" "$cap/claude.calls"; cp "$TMP/holds.filed" "$cap/holds.filed"
    [ "$RC" -eq 0 ] && pass "$name ($copy): exits 0" || flunk "$name ($copy): rc=$RC: $(cat "$TMP/cur.both")"
    [ "$(launches)" = 1 ] && pass "$name ($copy): the claude stub was invoked exactly once" || flunk "$name ($copy): launches=$(launches)"
    [ -f "$GAIA_RUNS_DIR/$SLUG/$FROZEN_STAMP-$name.json" ] && [ -f "$GAIA_RUNS_DIR/$SLUG/$FROZEN_STAMP-$name.meta" ] \
      && pass "$name ($copy): run record $FROZEN_STAMP-$name written" || flunk "$name ($copy): no run record: $(run_files)"
  done
  if diff -r "$TMP/cap/$name/main" "$TMP/cap/$name/branch" >"$TMP/cap/$name/diff" && [ ! -s "$TMP/cap/$name/diff" ]; then
    pass "$name: exit code, combined output, run record, project record and stub invocations are byte-identical to main"
  else
    flunk "$name: differs from main:
$(cat "$TMP/cap/$name/diff")"
  fi
}

compare_scenario fg done sess-fg -- --project "$SLUG" --label fg -- "/gaia-init"
compare_scenario bg done sess-bg -- --project "$SLUG" --label bg --background -- "/gaia-init"
compare_scenario resume done sess-q -- --project "$SLUG" --label resume --resume sess-q -- "Decision: approve. Continue."
compare_scenario nodirective done sess-nd -- --project "$SLUG" --label nodirective -- "/gaia-create-prd"
compare_scenario technical question sess-ci technical ci-platform "Which CI platform? (1) GitHub Actions — recommended; (2) GitLab CI." -- --project "$SLUG" --label technical -- "/gaia-init"

# the resume scenario really resumed, and the technical question was really routed
grep -q -- "--resume sess-q" "$TMP/cap/resume/branch/claude.argv" && pass "resume: claude was called with --resume sess-q" \
  || flunk "resume: argv lacks --resume sess-q"
OUT="$(cat "$TMP/cap/technical/branch/out")"
[ "$(json_field status)" = question ] && [ "$(json_field audience)" = technical ] \
  && pass "technical: routed as status=question, audience=technical" || flunk "technical: $OUT"

# ---- 6. the existing suites, unfrozen -----------------------------------------
run_suite() {
  local t="$1"
  if [ -n "$ORIG_PYTHONPATH_SET" ]; then
    if env PATH="$ORIG_PATH" PYTHONPATH="$ORIG_PYTHONPATH" bash "$REPO_DIR/tests/$t" >"$TMP/$t.out" 2>&1; then
      pass "tests/$t passes in full (exit 0)"
    else
      flunk "tests/$t FAILED:"; grep -E '^FAIL|gaia' "$TMP/$t.out" | head -20
    fi
  else
    if env -u PYTHONPATH PATH="$ORIG_PATH" bash "$REPO_DIR/tests/$t" >"$TMP/$t.out" 2>&1; then
      pass "tests/$t passes in full (exit 0)"
    else
      flunk "tests/$t FAILED:"; grep -E '^FAIL|gaia' "$TMP/$t.out" | head -20
    fi
  fi
}
run_suite verify-guard-opens-hold.sh
run_suite verify-audience-no-reclassify.sh

if [ "$fail" -eq 0 ]; then
  echo "OK: a paused project refuses every way a run can start (foreground, background, resume, any alias of the record) before any backend call; malformed state fails closed; an unpaused project is byte-identical to main"
else
  echo "FAILED"; exit 1
fi
