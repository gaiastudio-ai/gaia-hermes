#!/usr/bin/env bash
# uninstall.sh — remove the Gaia profile from Hermes Agent.
#
# Usage: ./uninstall.sh [--profile gaia] [--keep-state] [--yes]
#   --keep-state   keep $PROFILE_HOME/projects and gaia-runs (copied to ~/gaia-state-backup-<ts>)
#
# Projects on the Claude Code host (the code itself) are never touched.

set -eu
PROFILE="gaia"; KEEP=0; YES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --keep-state) KEEP=1; shift ;;
    --yes|-y) YES="--yes"; shift ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done
HERMES_ROOT="${HERMES_ROOT:-$HOME/.hermes}"
PROFILE_HOME="$HERMES_ROOT/profiles/$PROFILE"
[ -d "$PROFILE_HOME" ] || { printf 'profile %s not found at %s\n' "$PROFILE" "$PROFILE_HOME"; exit 0; }

if [ "$KEEP" = 1 ]; then
  dest="$HOME/gaia-state-backup-$(date +%Y%m%d%H%M%S)"
  mkdir -p "$dest"
  cp -R "$PROFILE_HOME/projects" "$PROFILE_HOME/gaia-runs" "$PROFILE_HOME/gaia.yaml" "$dest/" 2>/dev/null || true
  printf 'state copied to %s\n' "$dest"
fi

if command -v hermes >/dev/null 2>&1; then
  # shellcheck disable=SC2086
  hermes profile delete "$PROFILE" $YES
else
  rm -rf "$PROFILE_HOME"
  printf 'removed %s\n' "$PROFILE_HOME"
fi
