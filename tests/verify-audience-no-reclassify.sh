#!/usr/bin/env bash
# verify-audience-no-reclassify.sh — proof that gaia-claude.sh refuses to
# downgrade a stakeholder-tagged question to technical without a hold the
# stakeholder answered.
#
# ATTEMPTS THE VIOLATION: the 00:10 move of 18 September, "Override
# rc04-remainder audience to technical…". A run emits rc04-remainder with
# audience="stakeholder"; the loop then tries to answer it itself (a resume of
# the asking session carrying that override text) and to re-tag it (a later
# block emitting the same id as technical). Both must exit non-zero, record
# no answer for the id and say a stakeholder-answered hold is required. A
# Gaia-written questions[].answered value, and a hold Gaia tries to answer
# itself, must not release it either. A hold on the id answered by the
# stakeholder must. A born-technical question needs no hold; a stakeholder
# question never re-tagged is routed to the stakeholder as today.
#
# Runs fully isolated: throwaway $HERMES_HOME, a fake `claude` that prints
# whatever GAIA block the test stages, no network.
#
#   bash tests/verify-audience-no-reclassify.sh      # exit 0 == correct
set -eu

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$REPO_DIR/profile/skills/gaia-orchestrator/scripts"
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HERMES_HOME="$TMP/hermes"
export GAIA_SETTINGS="$HERMES_HOME/gaia.yaml"
export GAIA_STATE_DIR="$HERMES_HOME/projects"
export GAIA_RUNS_DIR="$HERMES_HOME/gaia-runs"
mkdir -p "$HERMES_HOME" "$TMP/bin" "$TMP/projects"

# Fake claude: prints one Claude-shaped JSON whose `result` is the staged
# block ($TMP/stage.result) and whose session id is $TMP/stage.session; logs
# its argv so the test can see whether a launch actually happened.
cat >"$TMP/bin/claude" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$TMP/claude.argv"
python3 - "$TMP/stage.result" "$TMP/stage.session" <<'PY'
import json, sys
print(json.dumps({"session_id": open(sys.argv[2]).read().strip(), "is_error": False, "num_turns": 1,
                  "total_cost_usd": 0, "result": open(sys.argv[1]).read()}))
PY
EOF
chmod +x "$TMP/bin/claude"
: >"$TMP/claude.argv"

cat >"$GAIA_SETTINGS" <<EOF
claude:
  mode: local
  bin: $TMP/bin/claude
  model: ""
  max_turns: 5
  max_budget_usd: 0
projects_root: $TMP/projects
hold_backend: channel
EOF

SLUG="audguard"
STATE="$GAIA_STATE_DIR/$SLUG.yaml"
mkdir -p "$TMP/projects/$SLUG"
bash "$S/gaia-project.sh" init "$SLUG" --name "Audience guard" --path "$TMP/projects/$SLUG" >/dev/null

# The verbatim 00:10 decision text (the override the 18 September run opened with).
OVERRIDE="Override rc04-remainder audience to technical…"
QID="rc04-remainder"
QTEXT="AD-50 rc04 remainder: which of the remaining rc04 items stay in scope for this release? (1) all of them — recommended; (2) only the blocking ones; (3) none, defer to the next release."

fail=0
pass() { printf 'PASS  %s\n' "$*"; }
flunk() { printf 'FAIL  %s\n' "$*"; fail=1; }
count_runs() { find "$GAIA_RUNS_DIR" -type f 2>/dev/null | wc -l | tr -d ' '; }
launches() { wc -l <"$TMP/claude.argv" | tr -d ' '; }

# stage <session_id> <audience> <id> <text> — what the next fake claude run emits
stage() {
  printf '%s' "$1" >"$TMP/stage.session"
  printf '<<GAIA-QUESTION audience="%s" id="%s">>\n%s\n<<END-GAIA-QUESTION>>' "$2" "$3" "$4" >"$TMP/stage.result"
}
# run_cmd <label> <args...> -> RC, OUT (stdout+stderr)
run_cmd() {
  local label="$1"; shift
  set +e
  OUT="$(bash "$S/gaia-claude.sh" run --project "$SLUG" --label "$label" "$@" 2>&1)"
  RC=$?
  set -e
}
# json_field <field> — from the LAST JSON line of $OUT (refusals print one JSON line first)
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
# state_py <python expr over d> — read the project state (YAML or JSON)
state_py() {
  python3 - "$STATE" "$1" <<'PY'
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
recorded_audience() { state_py "((d.get('question_audience') or {}).get('$1') or {}).get('audience')"; }
# answers recorded anywhere for the id: questions[].answered plus the record's own fields
answers_for() {
  state_py "len([q for q in d.get('questions', []) if q.get('id') == '$1' and q.get('answered')]) + len([k for k in ((d.get('question_audience') or {}).get('$1') or {}) if k in ('answer', 'answered')])"
}

# refused_resume <label> <session> <prompt> — the resume must exit non-zero,
# launch nothing, record nothing, keep the record stakeholder, and name the hold requirement
refused_resume() {
  local label="$1" sid="$2" prompt="$3" runs_before launches_before last_before
  runs_before="$(count_runs)"; launches_before="$(launches)"
  last_before="$(bash "$S/gaia-project.sh" get "$SLUG" last_run_id)"
  run_cmd "$label" --resume "$sid" -- "$prompt"
  if [ "$RC" -ne 0 ]; then pass "$label: resume exits non-zero (rc=$RC)"; else flunk "$label: resume exited 0: $OUT"; fi
  [ "$(count_runs)" = "$runs_before" ] && [ "$(launches)" = "$launches_before" ] \
    && pass "$label: nothing launched, no run record created" || flunk "$label: claude was launched / a run record exists"
  [ "$(bash "$S/gaia-project.sh" get "$SLUG" last_run_id)" = "$last_before" ] \
    && pass "$label: last_run_id untouched" || flunk "$label: last_run_id changed"
  [ "$(json_field status)" = refused ] && [ "$(json_field audience)" = stakeholder ] && [ "$(json_field question_id)" = "$QID" ] \
    && pass "$label: refusal JSON is status=refused, audience=stakeholder, question_id=$QID" \
    || flunk "$label: refusal JSON wrong: $OUT"
  case "$OUT" in
    *"a stakeholder-answered hold is required"*) pass "$label: refusal says a stakeholder-answered hold is required" ;;
    *) flunk "$label: refusal text does not say a stakeholder-answered hold is required: $OUT" ;;
  esac
  [ "$(recorded_audience "$QID")" = stakeholder ] \
    && pass "$label: $QID still recorded audience=stakeholder" || flunk "$label: recorded audience is '$(recorded_audience "$QID")'"
}

# ---- 1. the question is emitted stakeholder and recorded as such ------------
stage sess-rc04 stakeholder "$QID" "$QTEXT"
run_cmd rc04 -- "/gaia-review-all"
if [ "$RC" -eq 0 ] && [ "$(json_field status)" = question ] && [ "$(json_field audience)" = stakeholder ] && [ "$(json_field question_id)" = "$QID" ]; then
  pass "stakeholder question: routed as status=question, audience=stakeholder, id=$QID"
else flunk "stakeholder question not routed as stakeholder (rc=$RC): $OUT"; fi
[ "$(recorded_audience "$QID")" = stakeholder ] \
  && pass "state records question_audience.$QID.audience=stakeholder" || flunk "audience not recorded: $(recorded_audience "$QID")"
[ "$(state_py "d['question_audience']['$QID'].get('session_id')")" = sess-rc04 ] \
  && pass "record carries the asking session id" || flunk "record lacks session id"

# ---- 2. THE VIOLATION, resume path: the loop answers it itself as technical --
refused_resume "override-resume" sess-rc04 "$OVERRIDE"
[ "$(answers_for "$QID")" = 0 ] && pass "override-resume: no answer recorded for $QID" || flunk "override-resume: an answer was recorded for $QID"

# ---- 3. THE VIOLATION, re-emit path: a later block re-tags the id technical --
runs_before="$(count_runs)"
stage sess-rc04-b technical "$QID" "$OVERRIDE"
run_cmd override-reemit -- "/gaia-review-all"
if [ "$RC" -ne 0 ]; then pass "override-reemit: exits non-zero (rc=$RC)"; else flunk "override-reemit: exited 0: $OUT"; fi
[ "$(json_field status)" = refused ] && [ "$(json_field audience)" = stakeholder ] && [ "$(json_field refused_audience)" = technical ] \
  && pass "override-reemit: summary is status=refused at audience=stakeholder (refused_audience=technical)" \
  || flunk "override-reemit: summary wrong: $OUT"
case "$OUT" in
  *"a stakeholder-answered hold is required"*) pass "override-reemit: refusal says a stakeholder-answered hold is required" ;;
  *) flunk "override-reemit: refusal text wrong: $OUT" ;;
esac
[ "$(recorded_audience "$QID")" = stakeholder ] && pass "override-reemit: record stays stakeholder" || flunk "override-reemit: record changed"
[ "$(answers_for "$QID")" = 0 ] && pass "override-reemit: no answer recorded for $QID" || flunk "override-reemit: an answer was recorded"
[ "$(bash "$S/gaia-project.sh" get "$SLUG" last_session_id)" = sess-rc04 ] \
  && pass "override-reemit: last_session_id not advanced to the refused run" || flunk "override-reemit: last_session_id advanced"
# `status` on that finished run agrees with `run` (the guard is in the view, not only in the recording)
reemit_run="$(find "$GAIA_RUNS_DIR/$SLUG" -name '*-override-reemit.json' | head -n1)"
set +e; OUT="$(bash "$S/gaia-claude.sh" status "$reemit_run" 2>&1)"; RC=$?; set -e
[ "$(json_field status)" = refused ] && [ "$(json_field audience)" = stakeholder ] \
  && pass "status <run> shows the same refusal at audience=stakeholder" || flunk "status <run> shows: $OUT"

# ---- 4. a Gaia-written ordinary answer does NOT release it -------------------
bash "$S/gaia-project.sh" question add "$SLUG" "$QID" "$QTEXT" >/dev/null
bash "$S/gaia-project.sh" question answer "$SLUG" "$QID" "$OVERRIDE" >/dev/null
[ "$(answers_for "$QID")" -ge 1 ] && pass "setup: Gaia wrote questions[].answered for $QID (ordinary answer, no provenance)" \
  || flunk "setup: could not write the ordinary answer"
refused_resume "self-answer-then-resume" sess-rc04 "$OVERRIDE"
stage sess-rc04-c technical "$QID" "$OVERRIDE"
run_cmd self-answer-then-reemit -- "/gaia-review-all"
[ "$RC" -ne 0 ] && [ "$(json_field status)" = refused ] && [ "$(recorded_audience "$QID")" = stakeholder ] \
  && pass "self-answer-then-reemit: re-tag still refused after Gaia's ordinary answer" \
  || flunk "self-answer-then-reemit: re-tag slipped after Gaia's ordinary answer (rc=$RC): $OUT"

# ---- 5. a hold Gaia opens is not enough: pending, or answered --by gaia -------
bash "$S/gaia-hold.sh" open "$SLUG" "$QID" --subject "rc04 remainder scope" --ask "$QTEXT" >/dev/null
refused_resume "pending-hold" sess-rc04 "$OVERRIDE"
set +e; bash "$S/gaia-hold.sh" answer "$SLUG" "$QID" approve --by gaia >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -ne 0 ] && pass "gaia-hold refuses --by gaia (task B), hold stays pending" || flunk "gaia-hold accepted --by gaia"
refused_resume "gaia-answered-hold" sess-rc04 "$OVERRIDE"

# ---- 6. the stakeholder answers the hold on that id: the question proceeds ---
bash "$S/gaia-hold.sh" answer "$SLUG" "$QID" approve --by Julien >/dev/null
runs_before="$(count_runs)"; launches_before="$(launches)"
stage sess-rc04 technical "$QID" "Proceeding with option (1) as approved; remaining rc04 items are implementation detail."
run_cmd released-resume --resume sess-rc04 -- "$OVERRIDE"
if [ "$RC" -eq 0 ] && [ "$(count_runs)" -gt "$runs_before" ] && [ "$(launches)" -gt "$launches_before" ]; then
  pass "released-resume: resume launches after the stakeholder answered hold $QID (rc=0, run record created)"
else flunk "released-resume: resume did not launch (rc=$RC): $OUT"; fi
grep -q -- "--resume sess-rc04" "$TMP/claude.argv" && pass "released-resume: claude was called with --resume sess-rc04" \
  || flunk "released-resume: claude argv lacks --resume sess-rc04"
[ "$(json_field status)" = question ] && [ "$(json_field audience)" = technical ] \
  && pass "released-resume: re-tag to technical is now allowed in the summary" || flunk "released-resume: summary: $OUT"
[ "$(recorded_audience "$QID")" = technical ] \
  && pass "released-resume: record moved stakeholder -> technical" || flunk "released-resume: record is '$(recorded_audience "$QID")'"
case "$(bash "$S/gaia-project.sh" get "$SLUG" last_run_id)" in
  *released-resume) pass "released-resume: answer run recorded as last_run_id" ;;
  *) flunk "released-resume: last_run_id not recorded" ;;
esac
bash "$S/gaia-project.sh" log "$SLUG" "decision: $OVERRIDE" >/dev/null
# once technical, the loop answers it as any technical question: no further hold
refused_before="$(launches)"
run_cmd released-followup --resume sess-rc04 -- "continue"
[ "$RC" -eq 0 ] && [ "$(launches)" -gt "$refused_before" ] && pass "released-resume: follow-up resume of the released session launches" \
  || flunk "released-resume: follow-up resume refused (rc=$RC): $OUT"

# ---- 7. born-technical: no hold, answered as today ----------------------------
stage sess-ci technical ci-platform "Which CI platform? (1) GitHub Actions — recommended; (2) GitLab CI."
run_cmd ci -- "/gaia-init"
[ "$RC" -eq 0 ] && [ "$(json_field audience)" = technical ] && [ "$(recorded_audience ci-platform)" = technical ] \
  && pass "born-technical: routed technical, recorded technical" || flunk "born-technical: rc=$RC $OUT"
launches_before="$(launches)"
stage sess-ci technical ci-platform "ok"
run_cmd ci-answer --resume sess-ci -- "Decision: GitHub Actions (the repo is on GitHub)."
[ "$RC" -eq 0 ] && [ "$(launches)" -gt "$launches_before" ] && grep -q -- "--resume sess-ci" "$TMP/claude.argv" \
  && pass "born-technical: Gaia's answer resumes without any hold" || flunk "born-technical: resume refused (rc=$RC): $OUT"

# ---- 8. stakeholder stays stakeholder: routed to the stakeholder as today -----
stage sess-org stakeholder org-visibility "Which GitHub organisation, and public or private?"
run_cmd org -- "/gaia-init"
[ "$RC" -eq 0 ] && [ "$(json_field status)" = question ] && [ "$(json_field audience)" = stakeholder ] \
  && [ "$(recorded_audience org-visibility)" = stakeholder ] \
  && pass "stakeholder stays stakeholder: routed and recorded stakeholder" || flunk "stakeholder question: rc=$RC $OUT"
stage sess-org-b stakeholder org-visibility "Which GitHub organisation, and public or private? (asked again)"
run_cmd org-again -- "/gaia-init"
[ "$RC" -eq 0 ] && [ "$(json_field audience)" = stakeholder ] && [ "$(recorded_audience org-visibility)" = stakeholder ] \
  && pass "stakeholder stays stakeholder: re-asking at stakeholder audience is not a transition (rc=0)" \
  || flunk "re-asking a stakeholder question was refused (rc=$RC): $OUT"
# an upgrade technical -> stakeholder is never refused
stage sess-up technical hosting-region "Which region? (1) eu-west — recommended."
run_cmd up -- "/gaia-create-arch"
stage sess-up-b stakeholder hosting-region "Which region? This commits to EU data residency."
run_cmd up-2 -- "/gaia-create-arch"
[ "$RC" -eq 0 ] && [ "$(recorded_audience hosting-region)" = stakeholder ] \
  && pass "upgrade technical -> stakeholder is allowed and recorded" || flunk "upgrade refused (rc=$RC): $OUT"

# ---- 9. a hold answered BEFORE the question was asked does not release it ----
bash "$S/gaia-hold.sh" open "$SLUG" stale-q --subject "stale" --ask "approve?" >/dev/null
bash "$S/gaia-hold.sh" answer "$SLUG" stale-q approve --by Julien >/dev/null
sleep 1
stage sess-stale stakeholder stale-q "Which vendor do we pay for?"
run_cmd stale -- "/gaia-create-prd"
set +e
OUT="$(bash "$S/gaia-claude.sh" run --project "$SLUG" --label stale-resume --resume sess-stale -- "technical, proceed" 2>&1)"; RC=$?
set -e
[ "$RC" -ne 0 ] && [ "$(json_field status)" = refused ] \
  && pass "stale hold: a hold answered before the ask does not release the question" \
  || flunk "stale hold released the question (rc=$RC): $OUT"

if [ "$fail" -eq 0 ]; then
  echo "OK: the 00:10 override is refused on resume and on re-emit; only a stakeholder-answered hold on the question id releases it"
else
  echo "FAILED"; exit 1
fi
