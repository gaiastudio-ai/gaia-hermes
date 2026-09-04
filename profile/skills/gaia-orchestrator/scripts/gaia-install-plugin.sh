#!/usr/bin/env bash
# gaia-install-plugin.sh — install (or update) the GAIA framework plugin in
# Claude Code on the Claude host, then re-check with the doctor.
#
# Usage: gaia-install-plugin.sh [--update]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
load_settings

MARKETPLACE="gaiastudio-ai/gaia-framework"
PLUGIN="gaia@gaiastudio-ai-gaia-framework"

if [ "${1:-}" = "--update" ]; then
  log "updating marketplace + plugin on the Claude host"
  host_exec "$CLAUDE_BIN" plugin marketplace update gaiastudio-ai-gaia-framework || true
  host_exec "$CLAUDE_BIN" plugin update "$PLUGIN"
else
  log "adding marketplace $MARKETPLACE"
  host_exec "$CLAUDE_BIN" plugin marketplace add "$MARKETPLACE" || log "marketplace add returned non-zero (already added?) — continuing"
  log "installing $PLUGIN (user scope)"
  host_exec "$CLAUDE_BIN" plugin install "$PLUGIN" --scope user 2>/dev/null \
    || host_exec "$CLAUDE_BIN" plugin install "$PLUGIN"
fi

if host_exec "$CLAUDE_BIN" plugin list 2>/dev/null | grep -q "$PLUGIN"; then
  log "GAIA plugin present"
  printf '{"ok":true,"plugin":"%s"}\n' "$PLUGIN"
else
  printf '{"ok":false,"plugin":"%s","message":"plugin still not listed after install; run on the Claude host: %s plugin marketplace add %s && %s plugin install %s"}\n' \
    "$PLUGIN" "$CLAUDE_BIN" "$MARKETPLACE" "$CLAUDE_BIN" "$PLUGIN"
  exit 1
fi
