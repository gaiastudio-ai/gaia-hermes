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
