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

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

json_escape() { python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }

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
# when a state file exists for the slug, records session/run/command on it.
_record_state() {
  local json; json="$(cat)"
  printf '%s\n' "$json"
  local slug meta; meta="$(printf '%s' "$json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("result_file",""))')"
  meta="${meta%.json}.meta"
  [ -f "$meta" ] || return 0
  slug="$(sed -n 's/^slug=//p' "$meta")"
  [ -f "$GAIA_STATE_DIR/$slug.yaml" ] || return 0
  local sid rid st label
  sid="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("session_id") or "")')"
  rid="$(sed -n 's/^run_id=//p' "$meta")"; label="$(sed -n 's/^label=//p' "$meta")"
  st="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status") or "")')"
  [ -n "$sid" ] && "$SCRIPT_DIR/gaia-project.sh" set "$slug" last_session_id "$sid" >/dev/null
  "$SCRIPT_DIR/gaia-project.sh" set "$slug" last_run_id "$rid" >/dev/null
  "$SCRIPT_DIR/gaia-project.sh" set "$slug" last_command "$label" >/dev/null
  "$SCRIPT_DIR/gaia-project.sh" log "$slug" "run $rid ($label) -> $st" >/dev/null
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

# _summarize <result_file> — parse Claude JSON + markers into Gaia's contract
_summarize() {
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
