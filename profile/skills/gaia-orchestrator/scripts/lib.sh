#!/usr/bin/env bash
# lib.sh — shared helpers for the gaia-orchestrator skill scripts.
# Sourced, never executed. bash 3.2 compatible (macOS default).
# shellcheck disable=SC2034,SC2088  # globals are consumed by the sourcing scripts; ~ is expanded on the Claude host

set -eu

GAIA_HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
GAIA_SETTINGS="${GAIA_SETTINGS:-$GAIA_HERMES_HOME/gaia.yaml}"
GAIA_STATE_DIR="${GAIA_STATE_DIR:-$GAIA_HERMES_HOME/projects}"
GAIA_RUNS_DIR="${GAIA_RUNS_DIR:-$GAIA_HERMES_HOME/gaia-runs}"
GAIA_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mkdir -p "$GAIA_STATE_DIR" "$GAIA_RUNS_DIR"

die() { printf 'gaia: %s\n' "$*" >&2; exit "${2:-1}"; }
log() { printf '[gaia] %s\n' "$*" >&2; }

need_python() {
  command -v python3 >/dev/null 2>&1 || die "python3 is required on the Hermes host"
}

# settings_get <dotted.key> [default]
# Reads gaia.yaml with PyYAML when available, else a forgiving fallback parser.
settings_get() {
  need_python
  python3 - "$GAIA_SETTINGS" "$1" "${2:-}" <<'PY'
import sys, os
path, key, default = sys.argv[1], sys.argv[2], sys.argv[3]
data = {}
if os.path.exists(path):
    try:
        import yaml
        with open(path) as f:
            data = yaml.safe_load(f) or {}
    except ImportError:
        # Minimal 2-level YAML reader (key: value / nested one level). Good enough
        # for gaia.yaml written by install.sh; PyYAML is strongly recommended.
        cur = data
        stack = [(0, data)]
        for raw in open(path):
            line = raw.split('#', 1)[0].rstrip()
            if not line.strip():
                continue
            indent = len(line) - len(line.lstrip())
            k, _, v = line.strip().partition(':')
            v = v.strip().strip('"').strip("'")
            while stack and stack[-1][0] > indent:
                stack.pop()
            parent = stack[-1][1]
            if v == '':
                parent[k] = {}
                stack.append((indent + 2, parent[k]))
            else:
                if v.lower() in ('true', 'false'):
                    v = v.lower() == 'true'
                else:
                    try:
                        v = int(v)
                    except ValueError:
                        pass
                parent[k] = v
val = data
for part in key.split('.'):
    if isinstance(val, dict) and part in val:
        val = val[part]
    else:
        val = None
        break
if val is None or val == '':
    print(default)
elif isinstance(val, bool):
    print('true' if val else 'false')
else:
    print(val)
PY
}

# Resolve settings once into globals.
load_settings() {
  [ -f "$GAIA_SETTINGS" ] || die "settings file not found: $GAIA_SETTINGS (run install.sh, or copy gaia.yaml.example)"
  CLAUDE_MODE="$(settings_get claude.mode local)"
  CLAUDE_BIN="$(settings_get claude.bin claude)"
  CLAUDE_SSH_HOST="$(settings_get claude.ssh_host "")"
  CLAUDE_SSH_OPTS="$(settings_get claude.ssh_opts "-o BatchMode=yes -o ConnectTimeout=10")"
  CLAUDE_MODEL="$(settings_get claude.model "")"
  CLAUDE_MAX_TURNS="$(settings_get claude.max_turns 300)"
  CLAUDE_MAX_BUDGET="$(settings_get claude.max_budget_usd 0)"
  PROJECTS_ROOT="$(settings_get projects_root "~/projects")"
  case "$CLAUDE_MODE" in
    local|ssh) ;;
    *) die "claude.mode must be 'local' or 'ssh' (got '$CLAUDE_MODE')" ;;
  esac
  if [ "$CLAUDE_MODE" = ssh ] && [ -z "$CLAUDE_SSH_HOST" ]; then
    die "claude.mode is ssh but claude.ssh_host is empty"
  fi
}

# shell_quote <args...>  -> one line, each arg single-quoted for a remote bash
shell_quote() {
  local out="" a
  for a in "$@"; do
    a=$(printf '%s' "$a" | sed "s/'/'\\\\''/g")
    out="$out '$a'"
  done
  printf '%s' "${out# }"
}

# host_exec <cmd...> — run a command on the Claude Code host (local or ssh).
# stdin is /dev/null; stdout/stderr pass through.
host_exec() {
  if [ "$CLAUDE_MODE" = local ]; then
    "$@" </dev/null
  else
    # shellcheck disable=SC2086
    ssh $CLAUDE_SSH_OPTS "$CLAUDE_SSH_HOST" "bash -lc $(shell_quote "$(shell_quote "$@")")" </dev/null
  fi
}

# host_exec_in <dir> <cmd...> — same, but cd into <dir> on the host first.
host_exec_in() {
  local dir="$1"; shift
  if [ "$CLAUDE_MODE" = local ]; then
    ( cd "$(expand_home "$dir")" && "$@" </dev/null )
  else
    local remote
    remote="cd $(shell_quote "$dir") && $(shell_quote "$@")"
    # shellcheck disable=SC2086
    ssh $CLAUDE_SSH_OPTS "$CLAUDE_SSH_HOST" "bash -lc $(shell_quote "$remote")" </dev/null
  fi
}

# expand_home <path> — expand a leading ~ locally (host side does it via bash -lc)
expand_home() {
  case "$1" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s/%s' "$HOME" "${1#\~/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# project_path <slug> — absolute-ish path of a project on the Claude host
project_path() {
  printf '%s/%s' "${PROJECTS_ROOT%/}" "$1"
}

# slugify <text>
slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]+/-/g' -e 's/[^a-z0-9]/-/g' -e 's/--*/-/g' -e 's/^-//' -e 's/-$//'
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
