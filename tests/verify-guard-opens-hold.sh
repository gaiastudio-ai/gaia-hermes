#!/usr/bin/env bash
# verify-guard-opens-hold.sh — proof that gaia-claude.sh's two refusal guards
# open their own stakeholder hold at the seam where they refuse, through the
# existing gaia-hold.sh and the configured hold backend, one hold per cause,
# failing closed when the hold cannot be opened.
#
# ATTEMPTS THE 18 SEPTEMBER VIOLATIONS:
#   C — a new-revision command (/gaia-create-arch) while amend_revision is set;
#   D — the 00:10 "Override rc04-remainder audience to technical…" move: a
#       stakeholder-tagged question re-emitted technical, and the asking
#       session resumed with the override.
# For each: exit 3, exactly one hold opened (still exactly one after a
# repeat), the exact message, and a refusal that still stands when the hold
# backend fails (hold-open error on the project log). The unguarded paths
# open no hold. As its LAST STEP it runs D's own test
# (tests/verify-audience-no-reclassify.sh) and fails if that fails.
#
# Runs fully isolated: throwaway $HERMES_HOME, a fake `claude` that prints
# whatever GAIA block the test stages, hold backend `command` stubbed to record
# what it is asked to file. No model runs; nothing reaches a live channel.
#
#   bash tests/verify-guard-opens-hold.sh      # exit 0 == correct
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

# Fake claude: prints one Claude-shaped JSON whose `result` is the staged block.
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

# Stubbed hold backend (hold_backend: command). `file` records what it is asked
# to file — one line per hold: name, subject, ask — and prints an id; while
# $TMP/hold.fail exists it fails instead, like a backend that is down.
cat >"$TMP/hold-file.sh" <<EOF
#!/usr/bin/env bash
if [ -f "$TMP/hold.fail" ]; then echo "stub hold backend: down" >&2; exit 1; fi
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

fail=0
pass() { printf 'PASS  %s\n' "$*"; }
flunk() { printf 'FAIL  %s\n' "$*"; fail=1; }
count_runs() { find "$GAIA_RUNS_DIR" -type f 2>/dev/null | wc -l | tr -d ' '; }
launches() { wc -l <"$TMP/claude.argv" | tr -d ' '; }

new_project() {  # new_project <slug>
  mkdir -p "$TMP/projects/$1"
  bash "$S/gaia-project.sh" init "$1" --name "Guard hold $1" --path "$TMP/projects/$1" >/dev/null
}
# stage <session_id> <audience> <id> <text> — what the next fake claude run emits
stage() {
  printf '%s' "$1" >"$TMP/stage.session"
  printf '<<GAIA-QUESTION audience="%s" id="%s">>\n%s\n<<END-GAIA-QUESTION>>' "$2" "$3" "$4" >"$TMP/stage.result"
}
stage_done() { printf '%s' "$1" >"$TMP/stage.session"; printf '<<GAIA-DONE>>done<<END-GAIA-DONE>>' >"$TMP/stage.result"; }
# run_cmd <slug> <label> <args...> -> RC, OUT (stdout+stderr)
run_cmd() {
  local slug="$1" label="$2"; shift 2
  set +e
  OUT="$(bash "$S/gaia-claude.sh" run --project "$slug" --label "$label" "$@" 2>&1)"
  RC=$?
  set -e
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
# state_py <slug> <python expr over d> — read the project state (YAML or JSON)
state_py() {
  python3 - "$GAIA_STATE_DIR/$1.yaml" "$2" <<'PY'
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
holds_count() { state_py "$1" "len(d.get('holds') or {})"; }
hold_status() { state_py "$1" "((d.get('holds') or {}).get('$2') or {}).get('status')"; }
hold_history() { state_py "$1" "len(((d.get('holds') or {}).get('$2') or {}).get('history') or [])"; }
log_has() { state_py "$1" "any('$2' in (e.get('msg') or '') for e in d.get('log', []))"; }
filed_count() { awk -F'\t' -v n="$1" '$1 == n' "$TMP/holds.filed" | wc -l | tr -d ' '; }
filed_field() { awk -F'\t' -v n="$1" -v c="$2" '$1 == n { print $c; exit }' "$TMP/holds.filed"; }

# one_hold <slug> <name> <label> — exactly one hold on <name>: it is the only
# hold on the project, pending, opened once (no history), filed once
one_hold() {
  local slug="$1" name="$2" label="$3"
  [ "$(hold_status "$slug" "$name")" = pending ] && [ "$(holds_count "$slug")" = 1 ] && [ "$(hold_history "$slug" "$name")" = 0 ] \
    && pass "$label: exactly one hold on the project, '$name', pending, opened once" \
    || flunk "$label: holds are $(state_py "$slug" "d.get('holds')")"
  [ "$(filed_count "$name")" = 1 ] && pass "$label: backend asked to file hold '$name' exactly once" \
    || flunk "$label: backend filed '$name' $(filed_count "$name") times"
}

SLUG="holdproof"
new_project "$SLUG"
QID="rc04-remainder"
QTEXT="AD-50 rc04 remainder: which of the remaining rc04 items stay in scope for this release? (1) all of them — recommended; (2) only the blocking ones; (3) none, defer to the next release."
OVERRIDE="Override rc04-remainder audience to technical…"

# ---- the exact messages: main's wording, transformed exactly as required ----
# C: main's message, byte-for-byte, with " — hold <id> is open for the stakeholder" appended.
C_MAIN="refused /gaia-create-arch for project '$SLUG': amend_revision=18 is set — amend architecture revision 18 (/gaia-edit-arch) instead of writing a new one, or clear the field with: gaia-project.sh set $SLUG amend_revision null"
# D: main's message with ONLY the open-a-hold clause replaced by "hold <id> is open for the stakeholder".
D_CLAUSE="open one named after the question id (gaia-hold.sh open $SLUG $QID --subject \"...\" --ask \"<the question, at its stakeholder audience>\")"
D_MAIN="refused re-tag of question '$QID' from stakeholder to technical for project '$SLUG': it was asked with audience=stakeholder and the stakeholder has not released it — a stakeholder-answered hold is required: $D_CLAUSE and let the stakeholder answer it (gaia-hold.sh answer $SLUG $QID approve|send_back|stop). Gaia's own answers never release it: neither --by gaia (refused by gaia-hold.sh) nor a questions[].answered value written by the loop counts as the stakeholder's word"
case "$D_MAIN" in *"$D_CLAUSE"*) ;; *) echo "FAIL: test literal D_MAIN lacks the open clause" >&2; exit 1 ;; esac

# ---- 1. C refused, hold opened -----------------------------------------------
bash "$S/gaia-project.sh" set "$SLUG" amend_revision 18 >/dev/null
runs_before="$(count_runs)"
run_cmd "$SLUG" arch -- "/gaia-create-arch"
[ "$RC" -eq 3 ] && pass "C: /gaia-create-arch exits 3 while amend_revision=18" || flunk "C: rc=$RC: $OUT"
[ "$(count_runs)" = "$runs_before" ] && [ "$(launches)" = 0 ] && pass "C: nothing launched, no run record" || flunk "C: something launched"
C_HOLD="$(json_field hold)"
[ -n "$C_HOLD" ] && pass "C: refusal JSON names the hold it opened: $C_HOLD" || flunk "C: refusal JSON names no hold: $OUT"
one_hold "$SLUG" "$C_HOLD" "C"
C_ASK="$(filed_field "$C_HOLD" 3)"
case "$C_ASK" in
  *"amend revision 18 in place"*"draft a new revision"*"change the directive"*)
    pass "C: the hold offers the three options: amend revision 18 in place, draft a new revision, change the directive" ;;
  *) flunk "C: hold ask lacks the three options: $C_ASK" ;;
esac
C_EXPECTED="$C_MAIN — hold $C_HOLD is open for the stakeholder"
[ "$(json_field message)" = "$C_EXPECTED" ] && pass "C: message is main's message with ' — hold <id> is open for the stakeholder' appended" \
  || flunk "C: message differs.
   want: $C_EXPECTED
   got:  $(json_field message)"
case "$(json_field message)" in
  *"gaia-project.sh set $SLUG amend_revision null"*) pass "C: the clear-the-field clause is intact" ;;
  *) flunk "C: clear-the-field clause missing" ;;
esac
case "$(json_field message)" in
  *"gaia-hold.sh open"*) flunk "C: message still tells a human to run gaia-hold.sh open" ;;
  *) pass "C: no 'gaia-hold.sh open' instruction in the message" ;;
esac

# ---- 2. C repeated: still exactly one hold -----------------------------------
run_cmd "$SLUG" arch-again -- "/gaia-create-arch"
[ "$RC" -eq 3 ] && pass "C repeat: exits 3 again" || flunk "C repeat: rc=$RC"
one_hold "$SLUG" "$C_HOLD" "C repeat"
[ "$(json_field message)" = "$C_EXPECTED" ] && [ "$(json_field hold)" = "$C_HOLD" ] \
  && pass "C repeat: same message, same hold — the open hold stands" || flunk "C repeat: message/hold changed: $OUT"

# ---- 3. D refused, hold opened -----------------------------------------------
bash "$S/gaia-project.sh" set "$SLUG" amend_revision null >/dev/null
stage sess-rc04 stakeholder "$QID" "$QTEXT"
run_cmd "$SLUG" rc04 -- "/gaia-review-all"
[ "$RC" -eq 0 ] && [ "$(json_field audience)" = stakeholder ] && pass "D setup: $QID asked at audience=stakeholder (rc=0)" \
  || flunk "D setup: rc=$RC: $OUT"
[ "$(holds_count "$SLUG")" = 1 ] && pass "D setup: asking a stakeholder question opens no hold" || flunk "D setup: a hold was opened by the question itself"
stage sess-rc04-b technical "$QID" "$OVERRIDE"
run_cmd "$SLUG" override-reemit -- "/gaia-review-all"
[ "$RC" -eq 3 ] && pass "D: re-tag of $QID to technical exits 3" || flunk "D: rc=$RC: $OUT"
[ "$(json_field status)" = refused ] && [ "$(json_field audience)" = stakeholder ] && [ "$(json_field question_id)" = "$QID" ] \
  && pass "D: refusal is status=refused, audience=stakeholder, question_id=$QID" || flunk "D: refusal JSON wrong: $OUT"
[ "$(json_field hold)" = "$QID" ] && pass "D: refusal JSON names the hold it opened: $QID" || flunk "D: hold field is '$(json_field hold)'"
[ "$(hold_status "$SLUG" "$QID")" = pending ] && [ "$(holds_count "$SLUG")" = 2 ] && [ "$(hold_history "$SLUG" "$QID")" = 0 ] \
  && pass "D: exactly one hold on question id $QID, pending, opened once" || flunk "D: holds are $(state_py "$SLUG" "d.get('holds')")"
[ "$(filed_count "$QID")" = 1 ] && pass "D: backend asked to file hold '$QID' exactly once" || flunk "D: filed $(filed_count "$QID") times"
[ "$(filed_field "$QID" 3)" = "$QTEXT" ] && pass "D: the hold carries the question's text as asked" || flunk "D: hold ask is: $(filed_field "$QID" 3)"
case "$(filed_field "$QID" 2)" in
  *stakeholder*) pass "D: the hold is for the stakeholder (subject: $(filed_field "$QID" 2))" ;;
  *) flunk "D: hold subject does not say stakeholder: $(filed_field "$QID" 2)" ;;
esac
D_EXPECTED="${D_MAIN/"$D_CLAUSE"/hold $QID is open for the stakeholder}"
[ "$(json_field message)" = "$D_EXPECTED" ] && pass "D: message is main's message with only the open clause replaced by 'hold $QID is open for the stakeholder'" \
  || flunk "D: message differs.
   want: $D_EXPECTED
   got:  $(json_field message)"
case "$(json_field message)" in
  *"gaia-hold.sh open"*) flunk "D: message still tells a human to run gaia-hold.sh open" ;;
  *) pass "D: no 'gaia-hold.sh open' instruction in the message" ;;
esac
[ "$(state_py "$SLUG" "d['question_audience']['$QID'].get('audience')")" = stakeholder ] \
  && pass "D: $QID still recorded audience=stakeholder" || flunk "D: record changed"

# ---- 4. D repeated (re-emit, and the 00:10 resume): still exactly one hold ---
stage sess-rc04-c technical "$QID" "$OVERRIDE"
run_cmd "$SLUG" override-reemit-again -- "/gaia-review-all"
[ "$RC" -eq 3 ] && pass "D repeat: re-tag exits 3 again" || flunk "D repeat: rc=$RC"
[ "$(hold_status "$SLUG" "$QID")" = pending ] && [ "$(hold_history "$SLUG" "$QID")" = 0 ] && [ "$(filed_count "$QID")" = 1 ] \
  && pass "D repeat: still exactly one hold on $QID — the open hold stands" || flunk "D repeat: hold re-opened or missing"
[ "$(json_field message)" = "$D_EXPECTED" ] && pass "D repeat: same message" || flunk "D repeat: message changed: $(json_field message)"
launches_before="$(launches)"
run_cmd "$SLUG" override-resume --resume sess-rc04 -- "$OVERRIDE"
[ "$RC" -eq 3 ] && [ "$(launches)" = "$launches_before" ] && pass "D resume: the 00:10 override on the asking session exits 3, nothing launched" \
  || flunk "D resume: rc=$RC launched=$(( $(launches) - launches_before )): $OUT"
[ "$(hold_history "$SLUG" "$QID")" = 0 ] && [ "$(filed_count "$QID")" = 1 ] && [ "$(json_field hold)" = "$QID" ] \
  && pass "D resume: same cause, same hold — nothing new opened" || flunk "D resume: hold re-opened: $OUT"
case "$(json_field message)" in
  *"hold $QID is open for the stakeholder"*) pass "D resume: message names the open hold" ;;
  *) flunk "D resume: message: $(json_field message)" ;;
esac
case "$(json_field message)" in
  *"gaia-hold.sh open"*) flunk "D resume: message still tells a human to run gaia-hold.sh open" ;;
  *) pass "D resume: no 'gaia-hold.sh open' instruction" ;;
esac

# ---- 5. hold open fails: still refused, nothing proceeds, error logged --------
FSLUG="holdfail"
new_project "$FSLUG"
touch "$TMP/hold.fail"
bash "$S/gaia-project.sh" set "$FSLUG" amend_revision 7 >/dev/null
runs_before="$(count_runs)"; launches_before="$(launches)"; filed_before="$(wc -l <"$TMP/holds.filed" | tr -d ' ')"
run_cmd "$FSLUG" arch-fail -- "/gaia-create-arch"
[ "$RC" -eq 3 ] && pass "C, backend down: /gaia-create-arch still exits 3" || flunk "C, backend down: rc=$RC: $OUT"
[ "$(count_runs)" = "$runs_before" ] && [ "$(launches)" = "$launches_before" ] && pass "C, backend down: nothing launched, no run record" \
  || flunk "C, backend down: the command proceeded"
[ "$(hold_status "$FSLUG" amend-revision-7)" != pending ] && [ "$(wc -l <"$TMP/holds.filed" | tr -d ' ')" = "$filed_before" ] \
  && pass "C, backend down: no hold recorded as open, nothing filed" || flunk "C, backend down: a hold was recorded"
[ "$(log_has "$FSLUG" "hold-open error")" = True ] && pass "C, backend down: project log records the hold-open error" \
  || flunk "C, backend down: no hold-open error in the log: $(state_py "$FSLUG" "d.get('log')")"
[ -z "$(json_field hold)" ] && pass "C, backend down: refusal JSON claims no open hold (hold=null)" || flunk "C, backend down: hold=$(json_field hold)"
case "$(json_field message)" in
  *"is open for the stakeholder"*) flunk "C, backend down: message claims a hold is open" ;;
  *"amend_revision=7"*"could not be opened"*) pass "C, backend down: message keeps the refusal and says the hold could not be opened" ;;
  *) flunk "C, backend down: message: $(json_field message)" ;;
esac

bash "$S/gaia-project.sh" set "$FSLUG" amend_revision null >/dev/null
stage sess-fail stakeholder vendor "Which vendor do we pay for?"
run_cmd "$FSLUG" vendor -- "/gaia-create-prd"
[ "$RC" -eq 0 ] && pass "D, backend down setup: stakeholder question asked (rc=0)" || flunk "D setup rc=$RC: $OUT"
stage sess-fail-b technical vendor "Override vendor audience to technical…"
run_cmd "$FSLUG" vendor-reemit -- "/gaia-create-prd"
[ "$RC" -eq 3 ] && [ "$(json_field status)" = refused ] && pass "D, backend down: re-tag still exits 3, status=refused" || flunk "D, backend down: rc=$RC: $OUT"
[ "$(state_py "$FSLUG" "d['question_audience']['vendor'].get('audience')")" = stakeholder ] \
  && [ "$(bash "$S/gaia-project.sh" get "$FSLUG" last_session_id)" = sess-fail ] \
  && pass "D, backend down: nothing proceeded (record stays stakeholder, last_session_id not advanced)" \
  || flunk "D, backend down: something proceeded"
[ "$(hold_status "$FSLUG" vendor)" != pending ] && [ "$(wc -l <"$TMP/holds.filed" | tr -d ' ')" = "$filed_before" ] \
  && pass "D, backend down: no hold recorded as open, nothing filed" || flunk "D, backend down: a hold was recorded"
[ "$(log_has "$FSLUG" "hold-open error: hold vendor")" = True ] && pass "D, backend down: project log records the hold-open error for hold vendor" \
  || flunk "D, backend down: no hold-open error for vendor in the log"
case "$(json_field message)" in
  *"is open for the stakeholder"*) flunk "D, backend down: message claims a hold is open" ;;
  *"a stakeholder-answered hold is required"*) pass "D, backend down: message still says a stakeholder-answered hold is required" ;;
  *) flunk "D, backend down: message: $(json_field message)" ;;
esac
# backend back: the next refusal opens the hold (the failure did not consume the cause)
rm -f "$TMP/hold.fail"
stage sess-fail-c technical vendor "Override vendor audience to technical…"
run_cmd "$FSLUG" vendor-reemit-again -- "/gaia-create-prd"
[ "$RC" -eq 3 ] && [ "$(hold_status "$FSLUG" vendor)" = pending ] && [ "$(filed_count vendor)" = 1 ] \
  && pass "D, backend back: the next refusal opens hold vendor (still refused, exit 3)" || flunk "D, backend back: rc=$RC holds=$(state_py "$FSLUG" "d.get('holds')")"

# ---- 6. unguarded paths: unchanged, no hold ----------------------------------
PSLUG="plain"
new_project "$PSLUG"
filed_before="$(wc -l <"$TMP/holds.filed" | tr -d ' ')"
stage_done sess-plain
runs_before="$(count_runs)"
run_cmd "$PSLUG" arch -- "/gaia-create-arch"
[ "$RC" -eq 0 ] && [ "$(count_runs)" -gt "$runs_before" ] && pass "unguarded: /gaia-create-arch with no amend_revision launches (rc=0, run record)" \
  || flunk "unguarded: rc=$RC: $OUT"
stage sess-ci technical ci-platform "Which CI platform? (1) GitHub Actions — recommended; (2) GitLab CI."
run_cmd "$PSLUG" ci -- "/gaia-init"
stage sess-ci-b technical ci-platform "GitHub Actions."
run_cmd "$PSLUG" ci-again -- "/gaia-init"
[ "$RC" -eq 0 ] && [ "$(json_field audience)" = technical ] && pass "unguarded: born-technical question re-emitted technical proceeds (rc=0)" \
  || flunk "unguarded: born-technical refused rc=$RC: $OUT"
[ "$(holds_count "$PSLUG")" = 0 ] && [ "$(wc -l <"$TMP/holds.filed" | tr -d ' ')" = "$filed_before" ] \
  && pass "unguarded: no hold opened, nothing filed" || flunk "unguarded: holds=$(state_py "$PSLUG" "d.get('holds')")"

# ---- 7. D's own test, updated to assert the refusal opened the hold ----------
if bash "$REPO_DIR/tests/verify-audience-no-reclassify.sh" >"$TMP/audience.out" 2>&1; then
  pass "tests/verify-audience-no-reclassify.sh passes in full"
else
  flunk "tests/verify-audience-no-reclassify.sh FAILED:"; grep -E '^FAIL|gaia' "$TMP/audience.out" | head -20
fi
grep -q 'refusal opened hold rc04-remainder' "$TMP/audience.out" \
  && pass "D's test asserts the refusal opened the hold (it no longer opens one itself)" \
  || flunk "D's test does not assert the refusal opened the hold"
if grep -q 'gaia-hold.sh" open "\$SLUG" "\$QID"' "$REPO_DIR/tests/verify-audience-no-reclassify.sh"; then
  flunk "D's test still opens the hold on the question id by hand"
else pass "D's test opens no hold on the question id"; fi

if [ "$fail" -eq 0 ]; then
  echo "OK: both refusals open their own stakeholder hold (one per cause), stay refused when the hold cannot be opened, and name the hold in their message"
else
  echo "FAILED"; exit 1
fi
