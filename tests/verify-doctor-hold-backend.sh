#!/usr/bin/env bash
# verify-doctor-hold-backend.sh — prove gaia-doctor.sh checks the hold backend.
#
# Attempts the violation: writes, in turn, six gaia.yaml configs, runs
# `gaia-doctor.sh --json-only` for each, and asserts on its exit code and on the
# `failed` array of its single JSON line:
#   empty-file, empty-status, non-executable-file -> exit 1 AND "hold-backend" in failed
#   both-good, channel, unset                     -> "hold-backend" NOT in failed
# Also asserts .github/workflows/ci.yml runs this script. Exits 0 only if every
# assertion holds.
#
# Usage: bash tests/verify-doctor-hold-backend.sh

set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCTOR="$REPO/profile/skills/gaia-orchestrator/scripts/gaia-doctor.sh"
CI="$REPO/.github/workflows/ci.yml"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export HERMES_HOME="$TMP/hermes"
export GAIA_SETTINGS="$HERMES_HOME/gaia.yaml"
mkdir -p "$HERMES_HOME" "$TMP/projects" "$TMP/bin"

# A stub `claude` so the unrelated checks do not depend on this machine's Claude
# Code install; yq/jq are stubbed only when absent (the doctor only looks them up).
cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  --version)     echo "0.0.0 (stub)" ;;
  "auth status") echo '{"loggedIn": true}' ;;
  "plugin list") echo "  gaia@gaiastudio-ai-gaia-framework  enabled" ;;
esac
STUB
chmod +x "$TMP/bin/claude"
for t in yq jq; do
  command -v "$t" >/dev/null 2>&1 || { printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/$t"; chmod +x "$TMP/bin/$t"; }
done
export PATH="$TMP/bin:$PATH"

# The hold commands under test. Each leaves a marker if it is ever run: the
# doctor must only check them, never execute them.
for f in hold-file.sh hold-status.sh hold-file-noexec.sh; do
  printf '#!/bin/sh\ntouch "%s/EXECUTED-%s"\necho pending\n' "$TMP" "$f" > "$TMP/$f"
done
chmod +x "$TMP/hold-file.sh" "$TMP/hold-status.sh"
chmod -x "$TMP/hold-file-noexec.sh"

FAILS=0
ok()  { printf 'ok    %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }

# write_config <hold-lines...> — common settings plus the given hold lines
write_config() {
  {
    printf 'claude:\n  mode: local\n  bin: %s\n' "$TMP/bin/claude"
    printf 'projects_root: %s\n' "$TMP/projects"
    for line in "$@"; do printf '%s\n' "$line"; done
  } > "$GAIA_SETTINGS"
}

# run_case <name> <flagged|clean> — run the doctor on the current config
run_case() {
  local name="$1" expect="$2" out rc json failed
  out="$(bash "$DOCTOR" --json-only 2>&1)"; rc=$?
  json="$(printf '%s\n' "$out" | tail -n 1)"
  failed="$(printf '%s' "$json" | sed -n 's/.*"failed":[[:space:]]*\(\[[^]]*\]\).*/\1/p')"
  printf -- '--- %s: exit=%s %s\n' "$name" "$rc" "$json"
  if [ -z "$failed" ]; then bad "$name: no failed array in the doctor's JSON line"; return; fi
  if [ "$expect" = flagged ]; then
    if [ "$rc" -eq 1 ]; then ok "$name: exit 1"; else bad "$name: expected exit 1, got $rc"; fi
    if printf '%s' "$failed" | grep -q '"hold-backend"'; then ok "$name: hold-backend in failed"; else bad "$name: hold-backend missing from failed $failed"; fi
  else
    if printf '%s' "$failed" | grep -q '"hold-backend"'; then bad "$name: hold-backend wrongly in failed $failed"; else ok "$name: hold-backend absent from failed"; fi
    # exit reflects only the unrelated checks: 0 exactly when nothing failed
    if { [ "$failed" = "[]" ] && [ "$rc" -eq 0 ]; } || { [ "$failed" != "[]" ] && [ "$rc" -eq 1 ]; }; then ok "$name: exit $rc matches failed $failed"; else bad "$name: exit $rc does not match failed $failed"; fi
  fi
}

write_config 'hold_backend: command' 'hold_commands:' '  file: ""' "  status: \"$TMP/hold-status.sh\""
run_case empty-file flagged

write_config 'hold_backend: command' 'hold_commands:' "  file: \"$TMP/hold-file.sh\"" '  status: ""'
run_case empty-status flagged

write_config 'hold_backend: command' 'hold_commands:' "  file: \"$TMP/hold-file-noexec.sh\"" "  status: \"$TMP/hold-status.sh\""
run_case non-executable-file flagged

write_config 'hold_backend: command' 'hold_commands:' "  file: \"$TMP/hold-file.sh hold-file\"" "  status: \"$TMP/hold-status.sh status\""
run_case both-good clean

write_config 'hold_backend: channel' 'hold_commands:' '  file: ""' "  status: \"$TMP/hold-file-noexec.sh\""
run_case channel clean

write_config
run_case unset clean

# the doctor checks the commands; it must never have run them
if ls "$TMP"/EXECUTED-* >/dev/null 2>&1; then bad "doctor executed a configured hold command"; else ok "no configured hold command was executed"; fi

# CI runs this proof
if grep -q 'verify-doctor-hold-backend\.sh' "$CI"; then ok "ci.yml runs verify-doctor-hold-backend.sh"; else bad "ci.yml does not run verify-doctor-hold-backend.sh"; fi

if [ "$FAILS" -eq 0 ]; then printf '\nPASS — all assertions hold\n'; exit 0; fi
printf '\n%s assertion(s) FAILED\n' "$FAILS"; exit 1
