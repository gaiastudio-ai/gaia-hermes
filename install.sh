#!/usr/bin/env bash
# install.sh — install the Gaia orchestrator profile into Hermes Agent.
#
# What it does:
#   1. creates a Hermes profile (default name: gaia) cloned from your default
#      profile's config + API keys, so Gaia uses the same model/provider
#   2. copies SOUL.md and the gaia-orchestrator skill into that profile
#   3. asks where Claude Code is installed (this machine, or another one over SSH)
#      and writes $PROFILE_HOME/gaia.yaml
#   4. runs the doctor to verify Claude Code, its login, and the GAIA plugin
#
# Usage:
#   ./install.sh                      # interactive
#   ./install.sh --profile gaia --claude-mode ssh --ssh-host julien@um890 \
#                --claude-bin /home/julien/.local/bin/claude \
#                --projects-root /home/julien/projects --stakeholder "Julien" --yes
#
# Re-running is safe: files are refreshed, gaia.yaml is kept unless --reconfigure.

set -eu

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="gaia"
CLAUDE_MODE=""; CLAUDE_BIN=""; SSH_HOST=""; PROJECTS_ROOT=""; STAKEHOLDER=""; TZ_NAME=""
GH_ORG=""; GH_VIS=""
YES=0; RECONFIGURE=0; SKIP_DOCTOR=0

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --claude-mode) CLAUDE_MODE="$2"; shift 2 ;;
    --claude-bin) CLAUDE_BIN="$2"; shift 2 ;;
    --ssh-host) SSH_HOST="$2"; shift 2 ;;
    --projects-root) PROJECTS_ROOT="$2"; shift 2 ;;
    --stakeholder) STAKEHOLDER="$2"; shift 2 ;;
    --timezone) TZ_NAME="$2"; shift 2 ;;
    --github-org) GH_ORG="$2"; shift 2 ;;
    --github-visibility) GH_VIS="$2"; shift 2 ;;
    --yes|-y) YES=1; shift ;;
    --reconfigure) RECONFIGURE=1; shift ;;
    --skip-doctor) SKIP_DOCTOR=1; shift ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
ask()  { # ask <var> <prompt> <default>
  local var="$1" prompt="$2" def="$3" val
  if [ "$YES" = 1 ] || [ ! -t 0 ]; then eval "$var=\"\${$var:-\$def}\""; return; fi
  eval "val=\"\${$var:-}\""
  [ -n "$val" ] && return
  printf '%s [%s]: ' "$prompt" "$def"; read -r val
  eval "$var=\"\${val:-\$def}\""
}

# ---------------------------------------------------------------- checks -----
command -v python3 >/dev/null 2>&1 || die "python3 is required on this (Hermes) machine"
HERMES_ROOT="${HERMES_ROOT:-$HOME/.hermes}"
[ -d "$HERMES_ROOT" ] || die "Hermes Agent does not seem to be installed ($HERMES_ROOT missing). Install it first: https://hermes-agent.nousresearch.com"
command -v hermes >/dev/null 2>&1 || warn "'hermes' CLI not on PATH — the profile directory will be created manually; run 'hermes profile list' later to confirm it is picked up"

# ---------------------------------------------------------------- profile ----
PROFILE_HOME="$HERMES_ROOT/profiles/$PROFILE"
if [ -d "$PROFILE_HOME" ]; then
  say "profile '$PROFILE' already exists at $PROFILE_HOME — refreshing files"
else
  if command -v hermes >/dev/null 2>&1; then
    say "creating Hermes profile '$PROFILE' (cloning config + API keys from your default profile)"
    hermes profile create "$PROFILE" --clone || die "hermes profile create failed"
  else
    say "creating profile directory manually at $PROFILE_HOME"
    mkdir -p "$PROFILE_HOME/skills"
    [ -f "$HERMES_ROOT/config.yaml" ] && cp "$HERMES_ROOT/config.yaml" "$PROFILE_HOME/config.yaml"
    [ -f "$HERMES_ROOT/.env" ] && cp "$HERMES_ROOT/.env" "$PROFILE_HOME/.env"
  fi
fi
[ -d "$PROFILE_HOME" ] || die "profile directory not found after creation: $PROFILE_HOME"

# ---------------------------------------------------------------- files ------
if [ -f "$PROFILE_HOME/SOUL.md" ] && ! cmp -s "$PROFILE_HOME/SOUL.md" "$HERE/profile/SOUL.md"; then
  cp "$PROFILE_HOME/SOUL.md" "$PROFILE_HOME/SOUL.md.bak.$(date +%Y%m%d%H%M%S)"
  say "existing SOUL.md backed up"
fi
cp "$HERE/profile/SOUL.md" "$PROFILE_HOME/SOUL.md"

mkdir -p "$PROFILE_HOME/skills"
rm -rf "$PROFILE_HOME/skills/gaia-orchestrator"
cp -R "$HERE/profile/skills/gaia-orchestrator" "$PROFILE_HOME/skills/gaia-orchestrator"
chmod +x "$PROFILE_HOME/skills/gaia-orchestrator/scripts/"*.sh
mkdir -p "$PROFILE_HOME/projects" "$PROFILE_HOME/gaia-runs"
say "installed SOUL.md and skills/gaia-orchestrator into $PROFILE_HOME"

# ---------------------------------------------------------------- settings ---
SETTINGS="$PROFILE_HOME/gaia.yaml"
if [ -f "$SETTINGS" ] && [ "$RECONFIGURE" = 0 ]; then
  say "keeping existing $SETTINGS (use --reconfigure to change it)"
else
  printf '\nWhere is Claude Code installed?\n'
  printf '  local  = on this machine\n  ssh    = on another machine I can reach with key-based SSH\n'
  ask CLAUDE_MODE "Claude Code location (local/ssh)" "local"
  case "$CLAUDE_MODE" in local|ssh) ;; *) die "claude mode must be local or ssh" ;; esac
  if [ "$CLAUDE_MODE" = ssh ]; then
    ask SSH_HOST "SSH target (user@host)" ""
    [ -n "$SSH_HOST" ] || die "ssh host is required in ssh mode"
    ask CLAUDE_BIN "Path to 'claude' on $SSH_HOST" "claude"
    # shellcheck disable=SC2088  # literal ~ is expanded on the remote host
    ask PROJECTS_ROOT "Projects directory on $SSH_HOST" "~/projects"
  else
    default_bin="$(command -v claude 2>/dev/null || echo claude)"
    ask CLAUDE_BIN "Path to 'claude' on this machine" "$default_bin"
    ask PROJECTS_ROOT "Projects directory" "$HOME/projects"
  fi
  ask STAKEHOLDER "Your name (how Gaia addresses you)" "${USER:-}"
  ask TZ_NAME "Your timezone" "$( (command -v timedatectl >/dev/null 2>&1 && timedatectl show -p Timezone --value 2>/dev/null) || cat /etc/timezone 2>/dev/null || echo UTC)"
  ask GH_ORG "Default GitHub org for new repos (empty = Gaia asks per project)" ""
  ask GH_VIS "Default repo visibility private/public (empty = Gaia asks per project)" ""

  python3 - "$HERE/profile/gaia.yaml.example" "$SETTINGS" "$CLAUDE_MODE" "$CLAUDE_BIN" "$SSH_HOST" "$PROJECTS_ROOT" "$STAKEHOLDER" "$TZ_NAME" "$GH_ORG" "$GH_VIS" <<'PY'
import sys, re
src, dst, mode, binp, ssh, root, name, tz, org, vis = sys.argv[1:11]
text = open(src).read()
def setkey(text, key, value, indent):
    # replace "key: <anything>" at the given indent, keep trailing comment
    pat = re.compile(r'^(' + ' ' * indent + key + r':)[^\n#]*(#.*)?$', re.M)
    q = value if re.match(r'^[A-Za-z0-9_./~@:-]+$', value) or value == '' else '"' + value.replace('"', '\\"') + '"'
    if value == '':
        q = '""'
    return pat.sub(lambda m: f'{m.group(1)} {q}' + (f'   {m.group(2)}' if m.group(2) else ''), text, count=1)
text = setkey(text, 'mode', mode, 2)
text = setkey(text, 'bin', binp, 2)
text = setkey(text, 'ssh_host', ssh, 2)
text = setkey(text, 'projects_root', root, 0)
text = setkey(text, 'name', name, 2)
text = setkey(text, 'timezone', tz, 2)
text = setkey(text, 'default_org', org, 2)
text = setkey(text, 'default_visibility', vis, 2)
open(dst, 'w').write(text)
PY
  say "wrote $SETTINGS"
fi

# ---------------------------------------------------------------- doctor -----
if [ "$SKIP_DOCTOR" = 0 ]; then
  printf '\n'
  set +e
  HERMES_HOME="$PROFILE_HOME" bash "$PROFILE_HOME/skills/gaia-orchestrator/scripts/gaia-doctor.sh"
  rc=$?
  set -e
  if [ $rc -ne 0 ]; then
    warn "the doctor found problems. Gaia will refuse to run projects until they are fixed."
    warn "If only the GAIA plugin is missing, let Gaia install it:  HERMES_HOME=$PROFILE_HOME bash $PROFILE_HOME/skills/gaia-orchestrator/scripts/gaia-install-plugin.sh"
  fi
fi

# ---------------------------------------------------------------- done -------
cat <<EOF

Gaia is installed as Hermes profile '$PROFILE'.

  Chat with her:            $PROFILE chat            (alias created by Hermes)
                            hermes -p $PROFILE chat  (equivalent)
  Settings:                 $SETTINGS
  Project state:            $PROFILE_HOME/projects/<slug>.yaml
  Run transcripts:          $PROFILE_HOME/gaia-runs/<slug>/

Telegram / messaging (optional):
  1. put the bot token for THIS profile in $PROFILE_HOME/.env
     (a token must not be shared with another profile's gateway)
  2. $PROFILE gateway start           # or: $PROFILE gateway install  (systemd/launchd service)

First thing to say to her:  "Gaia, run your doctor check."  Then describe a project.
EOF
