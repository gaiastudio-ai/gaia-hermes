#!/usr/bin/env bash
# gaia-doctor.sh — verify everything Gaia needs before she runs a project.
#
# Checks (on the Claude Code host, local or over SSH):
#   1. the host is reachable (ssh mode)
#   2. `claude` binary present + version
#   3. Claude Code is authenticated
#   4. the GAIA plugin (gaia@gaiastudio-ai-gaia-framework) is installed
#   5. git, gh (authenticated), yq, jq present
#   6. projects_root exists and is writable
# Checks (on the Hermes host):
#   7. python3 present, settings file readable
#
# Exit 0 when all REQUIRED checks pass, 1 otherwise. Prints a report, then one
# JSON line ({"ok":bool,"failed":[...],"warnings":[...]}) as the last line.
#
# Usage: gaia-doctor.sh [--json-only]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

JSON_ONLY=0
[ "${1:-}" = "--json-only" ] && JSON_ONLY=1

FAILED=""; WARN=""
pass() { [ $JSON_ONLY = 1 ] || printf '  PASS  %s\n' "$*"; }
fail() { FAILED="$FAILED|$1"; [ $JSON_ONLY = 1 ] || printf '  FAIL  %s\n' "$*"; }
warn() { WARN="$WARN|$1"; [ $JSON_ONLY = 1 ] || printf '  WARN  %s\n' "$*"; }
hint() { [ $JSON_ONLY = 1 ] || printf '        -> %s\n' "$*"; }

[ $JSON_ONLY = 1 ] || printf 'Gaia doctor\n===========\n'

# 7. Hermes host basics
if command -v python3 >/dev/null 2>&1; then pass "python3 on Hermes host"; else fail "python3" "python3 missing on Hermes host"; fi
if [ -f "$GAIA_SETTINGS" ]; then pass "settings file $GAIA_SETTINGS"; else fail "settings" "settings file missing: $GAIA_SETTINGS"; hint "run install.sh or copy profile/gaia.yaml.example"; fi
python3 -c 'import yaml' 2>/dev/null && pass "PyYAML available (full YAML settings)" || warn "pyyaml" "PyYAML not importable by python3 — using minimal YAML parser (keep gaia.yaml simple)"

if [ -z "$FAILED" ]; then
  load_settings
  [ $JSON_ONLY = 1 ] || printf '\nClaude Code host: mode=%s%s\n' "$CLAUDE_MODE" "$([ "$CLAUDE_MODE" = ssh ] && printf ' host=%s' "$CLAUDE_SSH_HOST")"

  # 1. reachability
  if [ "$CLAUDE_MODE" = ssh ]; then
    if host_exec true >/dev/null 2>&1; then pass "ssh $CLAUDE_SSH_HOST reachable (non-interactive)"; else
      fail "ssh" "cannot ssh to $CLAUDE_SSH_HOST non-interactively"; hint "ssh-copy-id $CLAUDE_SSH_HOST  and test:  ssh $CLAUDE_SSH_OPTS $CLAUDE_SSH_HOST true"; fi
  fi

  if [ -z "$FAILED" ]; then
    # 2. claude binary
    ver="$(host_exec "$CLAUDE_BIN" --version 2>/dev/null | head -n1 || true)"
    if [ -n "$ver" ]; then pass "claude found: $ver"; else
      fail "claude" "'$CLAUDE_BIN' not found on the Claude host"; hint "install: curl -fsSL https://claude.ai/install.sh | bash   (or npm install -g @anthropic-ai/claude-code), then set claude.bin in $GAIA_SETTINGS"; fi

    if [ -n "$ver" ]; then
      # 3. auth
      auth="$(host_exec "$CLAUDE_BIN" auth status 2>&1 || true)"
      if printf '%s' "$auth" | grep -qiE '"loggedIn": *true|logged in|authenticated|api key'; then pass "claude authenticated"; else
        fail "auth" "Claude Code is not authenticated"; hint "on the Claude host run:  $CLAUDE_BIN auth login   (or export ANTHROPIC_API_KEY)"; fi

      # 4. GAIA plugin
      plugins="$(host_exec "$CLAUDE_BIN" plugin list 2>/dev/null || true)"
      if printf '%s' "$plugins" | grep -q 'gaia@gaiastudio-ai-gaia-framework'; then
        pv="$(printf '%s' "$plugins" | grep 'gaia@gaiastudio-ai-gaia-framework' | head -n1 | sed 's/^[ >]*//' | tr -s ' ')"
        if printf '%s' "$pv" | grep -qi 'disabled'; then warn "gaia-disabled" "GAIA plugin installed but disabled: $pv"; hint "$CLAUDE_BIN plugin enable gaia@gaiastudio-ai-gaia-framework"; else pass "GAIA plugin installed: $pv"; fi
      else
        fail "gaia-plugin" "GAIA plugin NOT installed on the Claude host — Gaia cannot work without it"
        hint "let Gaia install it:  bash $SCRIPT_DIR/gaia-install-plugin.sh"
        hint "or manually on the Claude host:  $CLAUDE_BIN plugin marketplace add gaiastudio-ai/gaia-framework && $CLAUDE_BIN plugin install gaia@gaiastudio-ai-gaia-framework"
      fi
    fi

    # 5. tooling
    for tool in git yq jq; do
      if host_exec bash -c "command -v $tool" >/dev/null 2>&1; then pass "$tool present"; else
        case "$tool" in
          git) fail "git" "git missing on the Claude host" ;;
          yq)  fail "yq" "yq missing on the Claude host (GAIA scripts need it)"; hint "https://github.com/mikefarah/yq#install" ;;
          jq)  warn "jq" "jq missing on the Claude host (recommended)" ;;
        esac
      fi
    done
    if host_exec bash -c 'command -v gh' >/dev/null 2>&1; then
      if host_exec gh auth status >/dev/null 2>&1; then pass "gh present and authenticated"; else
        warn "gh-auth" "gh present but not authenticated — Gaia cannot create GitHub repos"; hint "on the Claude host:  gh auth login"; fi
    else
      warn "gh" "gh (GitHub CLI) missing — Gaia will create local git repos only"; hint "https://cli.github.com/"
    fi

    # 6. projects root
    if host_exec bash -c "mkdir -p $PROJECTS_ROOT && test -w $PROJECTS_ROOT" >/dev/null 2>&1; then pass "projects_root writable: $PROJECTS_ROOT"; else
      fail "projects-root" "projects_root not writable on the Claude host: $PROJECTS_ROOT"; fi
  fi
fi

ok=true; [ -z "$FAILED" ] || ok=false
to_json_list() { printf '%s' "${1#|}" | python3 -c 'import sys,json; s=sys.stdin.read(); print(json.dumps([x for x in s.split("|") if x]))'; }
[ $JSON_ONLY = 1 ] || printf '\nResult: %s\n' "$([ "$ok" = true ] && echo "READY — Gaia can run projects" || echo "NOT READY — fix the FAIL items above")"
printf '{"ok":%s,"failed":%s,"warnings":%s}\n' "$ok" "$(to_json_list "$FAILED")" "$(to_json_list "$WARN")"
[ "$ok" = true ]
