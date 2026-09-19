#!/usr/bin/env bash
# verify-revision-directive-refusal.sh — proof that gaia-claude.sh refuses a
# new-revision command while the project's STRUCTURED amend_revision field is
# set, and launches it again once the field is cleared.
#
# The violation is attempted through the structured field, never through
# directive prose. Runs fully isolated: a throwaway $HERMES_HOME, a fake
# `claude` binary that prints a GAIA-DONE JSON result, no network.
#
#   bash tests/verify-revision-directive-refusal.sh      # exit 0 == correct
set -eu

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$REPO_DIR/profile/skills/gaia-orchestrator/scripts"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HERMES_HOME="$TMP/hermes"
export GAIA_SETTINGS="$HERMES_HOME/gaia.yaml"
export GAIA_STATE_DIR="$HERMES_HOME/projects"
export GAIA_RUNS_DIR="$HERMES_HOME/gaia-runs"
mkdir -p "$HERMES_HOME" "$TMP/bin" "$TMP/projects"

# Fake claude: accepts any argv, prints one Claude-shaped JSON object.
cat >"$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf '{"session_id":"sess-%s","is_error":false,"num_turns":1,"total_cost_usd":0,"result":"<<GAIA-DONE>>fake run finished<<END-GAIA-DONE>>"}\n' "$$"
EOF
chmod +x "$TMP/bin/claude"

cat >"$GAIA_SETTINGS" <<EOF
claude:
  mode: local
  bin: $TMP/bin/claude
  model: ""
  max_turns: 5
  max_budget_usd: 0
projects_root: $TMP/projects
EOF

SLUG="revguard"
mkdir -p "$TMP/projects/$SLUG"
bash "$S/gaia-project.sh" init "$SLUG" --name "Revision guard" --path "$TMP/projects/$SLUG" >/dev/null

fail=0
pass() { printf 'PASS  %s\n' "$*"; }
flunk() { printf 'FAIL  %s\n' "$*"; fail=1; }
count_runs() { find "$GAIA_RUNS_DIR" -type f 2>/dev/null | wc -l | tr -d ' '; }

# run_cmd <label> <prompt> -> sets RC, OUT (stdout+stderr)
run_cmd() {
  set +e
  OUT="$(bash "$S/gaia-claude.sh" run --project "$SLUG" --label "$1" -- "$2" 2>&1)"
  RC=$?
  set -e
}

# ---- 1. amend_revision=18: /gaia-create-arch must be refused -----------------
bash "$S/gaia-project.sh" set "$SLUG" amend_revision 18 >/dev/null
[ "$(bash "$S/gaia-project.sh" get "$SLUG" amend_revision)" = "18" ] \
  && pass "set stores amend_revision as integer 18" || flunk "amend_revision not stored as 18"

before="$(count_runs)"
run_cmd arch "/gaia-create-arch"
if [ "$RC" -ne 0 ]; then pass "/gaia-create-arch exits non-zero (rc=$RC) while amend_revision=18"
else flunk "/gaia-create-arch exited 0 while amend_revision=18"; fi
if [ "$(count_runs)" = "$before" ]; then pass "no run record created under $GAIA_RUNS_DIR"
else flunk "a run record was created despite the refusal"; fi
case "$OUT" in
  *amend_revision*18*) pass "refusal names amend_revision and 18" ;;
  *) flunk "refusal text does not name amend_revision and 18: $OUT" ;;
esac
[ "$(bash "$S/gaia-project.sh" get "$SLUG" last_run_id)" = "null" ] \
  && pass "last_run_id untouched by the refusal" || flunk "last_run_id was recorded on refusal"

# The guard keys on the command, not on where it sits in a multi-line prompt.
run_cmd arch2 "/gaia-create-arch
You may git push to origin."
[ "$RC" -ne 0 ] && pass "multi-line /gaia-create-arch prompt also refused" \
  || flunk "multi-line /gaia-create-arch prompt was launched"

# ---- 2. summary prints the field --------------------------------------------
SUMMARY="$(bash "$S/gaia-project.sh" summary "$SLUG")"
case "$SUMMARY" in
  *"amend_revision: 18"*) pass "summary prints amend_revision: 18" ;;
  *) flunk "summary does not print amend_revision: $SUMMARY" ;;
esac

# ---- 3. amend_revision=18: /gaia-edit-arch and /gaia-trace launch normally ---
before="$(count_runs)"
run_cmd edit-arch "/gaia-edit-arch"
if [ "$RC" -eq 0 ] && [ "$(count_runs)" -gt "$before" ]; then pass "/gaia-edit-arch launches while amend_revision=18"
else flunk "/gaia-edit-arch did not launch while amend_revision=18 (rc=$RC): $OUT"; fi

before="$(count_runs)"
run_cmd trace "/gaia-trace"
if [ "$RC" -eq 0 ] && [ "$(count_runs)" -gt "$before" ]; then pass "/gaia-trace launches while amend_revision=18"
else flunk "/gaia-trace did not launch while amend_revision=18 (rc=$RC): $OUT"; fi

# ---- 4. field rejects prose: it is structured, never directive text ----------
set +e
bash "$S/gaia-project.sh" set "$SLUG" amend_revision "amend revision 18" >/dev/null 2>&1; rc=$?
set -e
[ "$rc" -ne 0 ] && pass "set amend_revision rejects non-integer prose" \
  || flunk "set amend_revision accepted prose"
[ "$(bash "$S/gaia-project.sh" get "$SLUG" amend_revision)" = "18" ] \
  && pass "rejected set left amend_revision at 18" || flunk "rejected set changed amend_revision"

# ---- 5. amend_revision=null: /gaia-create-arch launches and records a run ---
bash "$S/gaia-project.sh" set "$SLUG" amend_revision null >/dev/null
[ "$(bash "$S/gaia-project.sh" get "$SLUG" amend_revision)" = "null" ] \
  && pass "set amend_revision null clears the field" || flunk "amend_revision not cleared"

before="$(count_runs)"
run_cmd arch "/gaia-create-arch"
if [ "$RC" -eq 0 ] && [ "$(count_runs)" -gt "$before" ]; then pass "/gaia-create-arch launches once amend_revision is null (rc=0, run record created)"
else flunk "/gaia-create-arch did not launch after clearing amend_revision (rc=$RC): $OUT"; fi
sid="$(bash "$S/gaia-project.sh" get "$SLUG" last_session_id)"
case "$sid" in
  sess-*) pass "session id recorded on the project ($sid)" ;;
  *) flunk "no session id recorded after the launch: $sid" ;;
esac
if bash "$S/gaia-project.sh" summary "$SLUG" | grep -q '^  amend_revision: '; then
  flunk "summary still prints the amend_revision line after clearing"
else pass "summary omits the amend_revision line when null"; fi

if [ "$fail" -eq 0 ]; then
  echo "OK: refusal fires while amend_revision is set and lifts when cleared"
else
  echo "FAILED"; exit 1
fi
