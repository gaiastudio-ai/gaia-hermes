#!/usr/bin/env bash
# gaia-new-project.sh — create a project directory on the Claude Code host,
# put it under git, optionally publish it to GitHub, and register it in Gaia's
# state. Does NOT run /gaia-init — that is a separate gaia-claude.sh run.
#
# Usage:
#   gaia-new-project.sh <slug> --name "<Project Name>"
#                       [--description "<one line>"]
#                       [--org <github-org|"">] [--visibility private|public|internal]
#                       [--no-github]
#
# Prints one JSON line: {"ok":true,"slug":..,"path":..,"github":..,"state_file":..}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

[ $# -ge 1 ] || { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
slug="$(slugify "$1")"; shift
name="$slug"; desc=""; org=""; vis=""; github=1
while [ $# -gt 0 ]; do
  case "$1" in
    --name) name="$2"; shift 2 ;;
    --description) desc="$2"; shift 2 ;;
    --org) org="$2"; shift 2 ;;
    --visibility) vis="$2"; shift 2 ;;
    --no-github) github=0; shift ;;
    *) die "unknown option: $1" ;;
  esac
done
load_settings
[ -n "$org" ] || org="$(settings_get github.default_org "")"
[ -n "$vis" ] || vis="$(settings_get github.default_visibility "")"
if [ "$github" = 1 ] && [ -z "$vis" ]; then
  die "GitHub visibility not decided: pass --visibility private|public|internal (a stakeholder decision) or --no-github"
fi

dir="$(project_path "$slug")"
if host_exec bash -c "test -e $(shell_quote "$dir")"; then
  die "directory already exists on the Claude host: $dir — pick another slug or use /gaia-brownfield on the existing project"
fi

# Create + git init + first commit on the Claude host.
bootstrap_script=$(cat <<EOS
set -eu
mkdir -p $(shell_quote "$dir")
cd $(shell_quote "$dir")
git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
printf '# %s\n\n%s\n\n_Managed by Gaia (Hermes) with the GAIA framework._\n' $(shell_quote "$name") $(shell_quote "$desc") > README.md
printf 'node_modules/\n.env\n.env.*\n*.log\n.DS_Store\n' > .gitignore
git add -A
git -c user.name="\${GIT_AUTHOR_NAME:-\$(git config user.name || echo Gaia)}" -c user.email="\${GIT_AUTHOR_EMAIL:-\$(git config user.email || echo gaia@localhost)}" commit -q -m "chore: bootstrap project (Gaia)"
echo BOOTSTRAP_OK
EOS
)
out="$(host_exec bash -c "$bootstrap_script" 2>&1)" || die "bootstrap failed on the Claude host: $out"
printf '%s' "$out" | grep -q BOOTSTRAP_OK || die "bootstrap did not complete: $out"

gh_url=""
if [ "$github" = 1 ]; then
  repo="$slug"; [ -n "$org" ] && repo="$org/$slug"
  gh_script="cd $(shell_quote "$dir") && gh repo create $(shell_quote "$repo") --$vis --source . --remote origin --push --description $(shell_quote "$desc") 2>&1 && gh repo view --json url -q .url"
  if gh_out="$(host_exec bash -lc "$gh_script" 2>&1)"; then
    gh_url="$(printf '%s' "$gh_out" | grep -Eo 'https://github\.com/[^ ]+' | tail -n1)"
    log "GitHub repo created: $gh_url"
  else
    log "WARNING: gh repo create failed — project exists locally without a remote. Output: $gh_out"
    gh_url=""
  fi
fi

state="$("$SCRIPT_DIR/gaia-project.sh" init "$slug" --name "$name" --path "$dir" --github "$gh_url")"
"$SCRIPT_DIR/gaia-project.sh" log "$slug" "project created at $dir${gh_url:+, github $gh_url}" >/dev/null
python3 - "$slug" "$dir" "$gh_url" "$state" <<'PY'
import json, sys
slug, path, gh, state = sys.argv[1:5]
print(json.dumps({"ok": True, "slug": slug, "path": path, "github": gh or None,
                  "state_file": json.loads(state)["file"],
                  "next": f"gaia-claude.sh run --project {slug} --label init -- \"/gaia-init\""}))
PY
