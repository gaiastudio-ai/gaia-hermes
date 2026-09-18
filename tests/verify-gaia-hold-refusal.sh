#!/usr/bin/env bash
# verify-gaia-hold-refusal.sh — proof that `gaia-hold.sh answer` refuses an
# answer attributed to Gaia and records every other answer normally.
#
# Self-contained: runs against a throwaway HERMES_HOME, touches nothing real.
# Usage: bash tests/verify-gaia-hold-refusal.sh      (exit 0 == correct)

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOLD="$REPO_ROOT/profile/skills/gaia-orchestrator/scripts/gaia-hold.sh"
[ -f "$HOLD" ] || { echo "FAIL: $HOLD not found" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HERMES_HOME="$TMP/hermes"
export GAIA_SETTINGS="$HERMES_HOME/gaia.yaml"
export GAIA_STATE_DIR="$HERMES_HOME/projects"
export GAIA_RUNS_DIR="$HERMES_HOME/gaia-runs"
mkdir -p "$GAIA_STATE_DIR"
printf 'hold_backend: channel\n' > "$GAIA_SETTINGS"

SLUG="verify-refusal"
STATE="$GAIA_STATE_DIR/$SLUG.yaml"
# JSON is valid YAML, so this seed loads with or without PyYAML on the host.
printf '{"slug": "%s", "holds": {}}\n' "$SLUG" > "$STATE"

fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1" >&2; fails=$((fails + 1)); }

# status_of <hold> / by_of <hold> — read the recorded state through `check`
field_of() {
  bash "$HOLD" check "$SLUG" "$1" 2>/dev/null \
    | python3 -c 'import sys, json; print(json.load(sys.stdin).get(sys.argv[1]))' "$2"
}
status_of() { field_of "$1" status; }
by_of() {
  python3 - "$STATE" "$1" <<'PY'
import sys, json
try:
    import yaml
    d = yaml.safe_load(open(sys.argv[1]))
except ImportError:
    d = json.load(open(sys.argv[1]))
print(d["holds"][sys.argv[2]].get("by"))
PY
}
open_hold() {
  bash "$HOLD" open "$SLUG" "$1" --subject "verify $1" --ask "approve?" >/dev/null 2>&1 \
    || { fail "could not open hold $1"; return 1; }
  [ "$(status_of "$1")" = pending ] || { fail "hold $1 is not pending after open"; return 1; }
}

# refused <hold> <by-value> <label> — the answer must exit non-zero, leave the
# state file byte-identical (nothing recorded), and leave the hold pending.
refused() {
  local hold="$1" by="$2" label="$3" rc
  open_hold "$hold" || return
  cp "$STATE" "$TMP/before"
  bash "$HOLD" answer "$SLUG" "$hold" approve --by "$by" >"$TMP/out" 2>"$TMP/err"; rc=$?
  if [ "$rc" -ne 0 ]; then pass "$label: exits non-zero (rc=$rc)"; else fail "$label: exited 0"; fi
  if cmp -s "$STATE" "$TMP/before"; then pass "$label: state file unchanged (answer not recorded)"
  else fail "$label: state file changed"; fi
  if [ "$(status_of "$hold")" = pending ]; then pass "$label: hold still pending"
  else fail "$label: status is '$(status_of "$hold")', expected pending"; fi
}

# recorded <hold> <label> <expected-by> [--by <value>] — the answer must exit 0
# and set the hold to approved, attributed to <expected-by>.
recorded() {
  local hold="$1" label="$2" want_by="$3" rc; shift 3
  open_hold "$hold" || return
  bash "$HOLD" answer "$SLUG" "$hold" approve "$@" >"$TMP/out" 2>"$TMP/err"; rc=$?
  if [ "$rc" -eq 0 ]; then pass "$label: exits 0"; else fail "$label: exited $rc ($(cat "$TMP/err"))"; fi
  if [ "$(status_of "$hold")" = approved ]; then pass "$label: status approved"
  else fail "$label: status is '$(status_of "$hold")', expected approved"; fi
  if [ "$(by_of "$hold")" = "$want_by" ]; then pass "$label: recorded by $want_by"
  else fail "$label: by is '$(by_of "$hold")', expected $want_by"; fi
}

# Acceptance 1: --by gaia is refused and the hold stays pending.
refused h-gaia "gaia" "--by gaia"
# The rule is "lowercased and trimmed equals gaia": case and edge whitespace do not evade it.
refused h-gaia-case "Gaia" "--by Gaia"
refused h-gaia-space "  GAIA  " "--by '  GAIA  '"

# A refused hold is genuinely still open: the stakeholder can answer it afterwards.
bash "$HOLD" answer "$SLUG" h-gaia approve --by Julien >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ "$(status_of h-gaia)" = approved ]; then pass "refused hold: later answered by Julien -> approved"
else fail "refused hold: could not be answered afterwards (rc=$rc, status $(status_of h-gaia))"; fi

# Acceptance 2: --by Julien records normally.
recorded h-julien "--by Julien" "Julien" --by Julien
# Acceptance 3: no --by records normally (default attribution).
recorded h-default "no --by" "stakeholder"
# Only the exact token counts: a value that merely contains "gaia" records normally.
recorded h-near "--by gaia-ops" "gaia-ops" --by gaia-ops

if [ "$fails" -eq 0 ]; then echo "PASS: gaia-hold answer refuses Gaia, records everyone else"; exit 0; fi
echo "FAILED: $fails check(s)" >&2; exit 1
