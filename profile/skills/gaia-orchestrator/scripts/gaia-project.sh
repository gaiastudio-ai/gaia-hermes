#!/usr/bin/env bash
# gaia-project.sh — per-project state registry for Gaia.
# State lives at $HERMES_HOME/projects/<slug>.yaml (JSON is valid YAML, so the
# file is always readable by yq/PyYAML even when PyYAML is absent on this host).
#
# Usage:
#   gaia-project.sh init <slug> --name "<Project Name>" [--path <dir>] [--github <url>]
#   gaia-project.sh list
#   gaia-project.sh get <slug> [dotted.key]
#   gaia-project.sh set <slug> <dotted.key> <value>      # value: string|number|true|false|null
#   gaia-project.sh log <slug> "<message>"               # append to decision/progress log
#   gaia-project.sh question add <slug> <id> "<question text>" [--audience stakeholder]
#   gaia-project.sh question answer <slug> <id> "<answer>"
#   gaia-project.sh question open <slug>                 # list unanswered
#   gaia-project.sh phase <slug> <phase>                 # shorthand for set phase + log
#   gaia-project.sh summary <slug>                       # human-readable status
#   gaia-project.sh delete <slug>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
need_python

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[ $# -ge 1 ] || usage

python3 - "$GAIA_STATE_DIR" "$@" <<'PY'
import sys, os, json, datetime
state_dir = sys.argv[1]
args = sys.argv[2:]
try:
    import yaml
    def load(p):
        with open(p) as f: return yaml.safe_load(f) or {}
    def dump(p, d):
        tmp = p + ".tmp"
        with open(tmp, "w") as f: yaml.safe_dump(d, f, sort_keys=False, allow_unicode=True)
        os.replace(tmp, p)
except ImportError:
    def load(p):
        with open(p) as f: return json.load(f)
    def dump(p, d):
        tmp = p + ".tmp"
        with open(tmp, "w") as f: json.dump(d, f, indent=2, ensure_ascii=False)
        os.replace(tmp, p)

def now(): return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
def path(slug): return os.path.join(state_dir, slug + ".yaml")
def must(slug):
    p = path(slug)
    if not os.path.exists(p):
        sys.exit(f"gaia: unknown project '{slug}' (state file {p} not found)")
    return p, load(p)
def coerce(v):
    if v in ("true", "false"): return v == "true"
    if v == "null": return None
    try: return int(v)
    except ValueError: pass
    try: return float(v)
    except ValueError: return v
def setdot(d, key, val):
    parts = key.split(".")
    for k in parts[:-1]:
        d = d.setdefault(k, {})
    d[parts[-1]] = val
def getdot(d, key):
    for k in key.split("."):
        if isinstance(d, dict) and k in d: d = d[k]
        else: return None
    return d
def opt(args, flag, default=None):
    if flag in args:
        i = args.index(flag); v = args[i+1]; del args[i:i+2]; return v
    return default

cmd = args[0]; rest = args[1:]
if cmd == "init":
    slug = rest[0]; rest = rest[1:]
    name = opt(rest, "--name", slug); p = opt(rest, "--path", ""); gh = opt(rest, "--github", "")
    if os.path.exists(path(slug)): sys.exit(f"gaia: project '{slug}' already exists")
    d = {
        "slug": slug, "name": name, "path": p, "github": gh,
        "created": now(), "updated": now(),
        "phase": "created",            # created -> init -> analysis -> planning -> solutioning -> implementation -> deployment -> maintenance
        "gaia_initialised": False,
        "last_session_id": None, "last_run_id": None, "last_command": None,
        "sprint": None, "current_story": None,
        "gate_retries": 0,
        "paused": False,
        "questions": [],               # {id, audience, text, asked, answer, answered}
        "decisions": [],               # decisions Gaia made on the team's behalf
        "log": [],                     # {t, msg}
    }
    os.makedirs(state_dir, exist_ok=True); dump(path(slug), d)
    print(json.dumps({"ok": True, "slug": slug, "file": path(slug)}))
elif cmd == "list":
    rows = []
    for f in sorted(os.listdir(state_dir)) if os.path.isdir(state_dir) else []:
        if f.endswith(".yaml"):
            d = load(os.path.join(state_dir, f))
            openq = [q for q in d.get("questions", []) if not q.get("answered")]
            rows.append({"slug": d.get("slug"), "name": d.get("name"), "phase": d.get("phase"),
                         "sprint": d.get("sprint"), "open_questions": len(openq), "updated": d.get("updated")})
    print(json.dumps(rows, indent=2))
elif cmd == "get":
    p, d = must(rest[0])
    if len(rest) > 1:
        v = getdot(d, rest[1]); print(json.dumps(v) if not isinstance(v, str) else v)
    else:
        print(json.dumps(d, indent=2, default=str))
elif cmd == "set":
    p, d = must(rest[0]); setdot(d, rest[1], coerce(rest[2])); d["updated"] = now(); dump(p, d)
    print(json.dumps({"ok": True, rest[1]: coerce(rest[2])}))
elif cmd == "log":
    p, d = must(rest[0]); d.setdefault("log", []).append({"t": now(), "msg": rest[1]}); d["updated"] = now(); dump(p, d)
    print(json.dumps({"ok": True}))
elif cmd == "phase":
    p, d = must(rest[0]); d["phase"] = rest[1]
    d.setdefault("log", []).append({"t": now(), "msg": f"phase -> {rest[1]}"}); d["updated"] = now(); dump(p, d)
    print(json.dumps({"ok": True, "phase": rest[1]}))
elif cmd == "question":
    sub = rest[0]; slug = rest[1]; p, d = must(slug); qs = d.setdefault("questions", [])
    if sub == "add":
        qid = rest[2]; text = rest[3]; aud = opt(rest, "--audience", "stakeholder")
        qs.append({"id": qid, "audience": aud, "text": text, "asked": now(), "answer": None, "answered": None})
    elif sub == "answer":
        qid = rest[2]; ans = rest[3]; hit = [q for q in qs if q["id"] == qid and not q.get("answered")]
        if not hit: sys.exit(f"gaia: no open question '{qid}'")
        hit[-1]["answer"] = ans; hit[-1]["answered"] = now()
    elif sub == "open":
        print(json.dumps([q for q in qs if not q.get("answered")], indent=2)); sys.exit(0)
    else: sys.exit("gaia: question add|answer|open")
    d["updated"] = now(); dump(p, d); print(json.dumps({"ok": True}))
elif cmd == "summary":
    p, d = must(rest[0])
    openq = [q for q in d.get("questions", []) if not q.get("answered")]
    print(f"{d['name']} ({d['slug']})")
    print(f"  path:      {d.get('path')}")
    print(f"  github:    {d.get('github') or '-'}")
    print(f"  phase:     {d.get('phase')}   gaia-init: {'yes' if d.get('gaia_initialised') else 'no'}{'   PAUSED' if d.get('paused') else ''}")
    print(f"  sprint:    {d.get('sprint') or '-'}   story: {d.get('current_story') or '-'}")
    print(f"  last cmd:  {d.get('last_command') or '-'}  (session {d.get('last_session_id') or '-'})")
    print(f"  open questions: {len(openq)}")
    for q in openq: print(f"    [{q['audience']}] {q['id']}: {q['text'][:120]}")
    for e in d.get("log", [])[-5:]: print(f"  {e['t']}  {e['msg']}")
elif cmd == "delete":
    p, d = must(rest[0]); os.remove(p); print(json.dumps({"ok": True}))
else:
    sys.exit("gaia: unknown subcommand " + cmd)
PY
