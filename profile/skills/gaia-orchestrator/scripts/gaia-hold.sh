#!/usr/bin/env bash
# gaia-hold.sh — stakeholder holds: the loop stops, a document goes to the
# stakeholder, and nothing proceeds until they answer.
#
# A hold is a RECORDED STATE in the project file (projects/<slug>.yaml under
# `holds.<name>`), not a message. The loop refuses to cross an unanswered hold
# whatever transport carried the card, which is what makes it work in both
# backends and what separates it from a notification that a phase completed
# and then continued anyway.
#
# Usage:
#   gaia-hold.sh open   <slug> <name> --subject "<one line>" --ask "<the question, plain prose>" \
#                       [--artifact "<label>: <path or URL>"]... [--sender "<who is asking>"]
#   gaia-hold.sh check  <slug> <name>            # -> {"status": none|pending|approved|send_back|stopped|skipped|withdrawn, ...}
#   gaia-hold.sh answer <slug> <name> <approve|send_back|stop> [--by "<who>"]   # channel backend: record the reply
#   gaia-hold.sh skip   <slug> <name> --reason "<why this hold did not fire>"    # recorded, never silent
#
# Backends (gaia.yaml `hold_backend`):
#   channel  — `open` prints the card text; Gaia sends it on its messaging channel
#              and the stakeholder answers by replying; Gaia records it with `answer`.
#   command  — `open` runs `hold_commands.file` with HOLD_* in the environment and
#              keeps the id it prints; `check` runs `hold_commands.status` with HOLD_ID
#              and reads `pending` | `decided:<text>` | `withdrawn`.
#   Answers map by their first word: approve → approved, send → send_back, stop → stopped.
#   `stop` also sets `paused: true` on the project: a stopped hold with the loop still
#   ticking is the blocked-retry-silent shape this exists to prevent.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
need_python

usage() { sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[ $# -ge 3 ] || usage

python3 - "$GAIA_STATE_DIR" "$GAIA_SETTINGS" "$@" <<'PY'
import sys, os, json, datetime, subprocess, shlex
state_dir, settings_path = sys.argv[1], sys.argv[2]
args = sys.argv[3:]
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
def die(m): sys.exit("gaia-hold: " + m)
def opt(a, flag, default=None):
    if flag in a:
        i = a.index(flag); v = a[i+1]; del a[i:i+2]; return v
    return default
def opts(a, flag):
    out = []
    while flag in a:
        i = a.index(flag); out.append(a[i+1]); del a[i:i+2]
    return out
def settings():
    return load(settings_path) if os.path.exists(settings_path) else {}
def must(slug):
    p = os.path.join(state_dir, slug + ".yaml")
    if not os.path.exists(p): die(f"unknown project '{slug}' (state file {p} not found)")
    return p, load(p)
def logline(d, msg): d.setdefault("log", []).append({"t": now(), "msg": msg})
def classify(text):
    t = (text or "").strip().lower()
    if t.startswith("decided:"): t = t[len("decided:"):].strip()
    if t.startswith("approve"): return "approved"
    if t.startswith("send"): return "send_back"
    if t.startswith("stop"): return "stopped"
    if t.startswith("withdrawn"): return "withdrawn"
    if t.startswith("pending"): return "pending"
    return None
def card_text(slug, name, h):
    L = [f"HOLD — {h['subject']}", f"Project: {slug} · hold: {name}", "", h["ask"], ""]
    for a in h.get("artifacts", []): L.append(f"- {a}")
    L += ["", "Reply with one word: approve, send back, or stop.",
          "approve = the phase proceeds · send back = I will ask you for direction and redo it · stop = the whole project pauses until you resume it."]
    return "\n".join(L)

cmd, slug, name = args[0], args[1], args[2]; rest = args[3:]
p, d = must(slug); holds = d.setdefault("holds", {})
cfg = settings(); backend = (cfg.get("hold_backend") or "channel").strip().lower()
cmds = cfg.get("hold_commands") or {}
h = holds.get(name) or {}

if cmd == "open":
    subject = opt(rest, "--subject"); ask = opt(rest, "--ask"); sender = opt(rest, "--sender", "Gaia")
    artifacts = opts(rest, "--artifact")
    if not subject or not ask: die("open needs --subject and --ask")
    if h.get("status") == "pending": die(f"hold '{name}' is already pending (id {h.get('id')}); check it instead")
    h = {"status": "pending", "backend": backend, "subject": subject, "ask": ask, "sender": sender,
         "artifacts": artifacts, "opened": now(), "id": None, "answered": None, "answer": None, "by": None,
         "history": (h.get("history") or []) + ([{k: h.get(k) for k in ("status", "opened", "answered", "answer", "by", "reason")}] if h else [])}
    if backend == "command":
        fc = (cmds.get("file") or "").strip()
        if not fc: die("hold_backend is 'command' but hold_commands.file is empty")
        env = dict(os.environ, HOLD_SLUG=slug, HOLD_NAME=name, HOLD_REF=f"{slug}:{name}:{h['opened']}",
                   HOLD_SENDER=sender, HOLD_SUBJECT=subject, HOLD_ASK=ask, HOLD_ARTIFACTS="\n".join(artifacts))
        r = subprocess.run(["bash", "-c", fc], env=env, capture_output=True, text=True, timeout=120)
        if r.returncode != 0: die(f"hold_commands.file failed rc={r.returncode}: {(r.stderr or r.stdout).strip()[:300]}")
        out = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else ""
        try: h["id"] = str(json.loads(out).get("id"))
        except Exception: h["id"] = out
        if not h["id"]: die("hold_commands.file printed no id")
    else:
        d.setdefault("questions", []).append({"id": f"hold:{name}", "audience": "stakeholder",
            "text": f"HOLD {name}: {subject} — reply approve / send back / stop", "asked": now(), "answer": None, "answered": None})
    holds[name] = h; logline(d, f"hold {name}: opened via {backend}" + (f" (id {h['id']})" if h["id"] else "")); d["updated"] = now(); dump(p, d)
    print(json.dumps({"ok": True, "hold": name, "status": "pending", "backend": backend, "id": h["id"],
                      "send_text": None if backend == "command" else card_text(slug, name, h)}))

elif cmd == "check":
    if not h: print(json.dumps({"ok": True, "hold": name, "status": "none"})); sys.exit(0)
    if h.get("status") == "pending" and h.get("backend") == "command":
        sc = (cmds.get("status") or "").strip()
        if not sc: die("hold_backend is 'command' but hold_commands.status is empty")
        r = subprocess.run(["bash", "-c", sc], env=dict(os.environ, HOLD_ID=str(h.get("id") or "")), capture_output=True, text=True, timeout=60)
        if r.returncode != 0: die(f"hold_commands.status failed rc={r.returncode}: {(r.stderr or r.stdout).strip()[:300]}")
        verdict = classify(r.stdout.strip().splitlines()[-1] if r.stdout.strip() else "")
        if verdict is None: die(f"hold_commands.status printed something unreadable: {r.stdout.strip()[:120]!r}")
        if verdict != "pending":
            h["status"] = verdict; h["answered"] = now(); h["answer"] = r.stdout.strip().splitlines()[-1]; h["by"] = "stakeholder"
            logline(d, f"hold {name}: {verdict} ({h['answer']})")
            if verdict == "stopped":
                d["paused"] = True; logline(d, "project paused by a stop on hold " + name)
            d["updated"] = now(); dump(p, d)
    print(json.dumps({"ok": True, "hold": name, "status": h.get("status"), "id": h.get("id"), "opened": h.get("opened"),
                      "answered": h.get("answered"), "answer": h.get("answer"), "paused": bool(d.get("paused"))}))

elif cmd == "answer":
    if not rest: die("answer needs approve|send_back|stop")
    verdict = classify(rest[0].replace("_", " ")); by = opt(rest, "--by", "stakeholder")
    # A hold is answered by the stakeholder, never by the agent that opened it.
    if (by or "").strip().lower() == "gaia": die("answer refused: a hold cannot be answered by Gaia; it stays pending until the stakeholder replies")
    if verdict not in ("approved", "send_back", "stopped"): die("answer must be approve, send_back or stop")
    if h.get("status") != "pending": die(f"hold '{name}' is not pending (status {h.get('status') or 'none'})")
    h["status"] = verdict; h["answered"] = now(); h["answer"] = rest[0]; h["by"] = by
    for q in d.get("questions", []):
        if q.get("id") == f"hold:{name}" and not q.get("answered"): q["answer"] = rest[0]; q["answered"] = now()
    logline(d, f"hold {name}: {verdict} by {by}")
    if verdict == "stopped":
        d["paused"] = True; logline(d, "project paused by a stop on hold " + name)
    d["updated"] = now(); dump(p, d)
    print(json.dumps({"ok": True, "hold": name, "status": verdict, "paused": bool(d.get("paused"))}))

elif cmd == "skip":
    reason = opt(rest, "--reason")
    if not reason: die("skip needs --reason: a hold that did not fire must say why")
    if h.get("status") == "pending": die(f"hold '{name}' is pending; it cannot be skipped")
    holds[name] = {"status": "skipped", "reason": reason, "opened": None, "answered": now(), "by": "gaia",
                   "history": (h.get("history") or [])}
    d.setdefault("decisions", []).append({"t": now(), "decision": f"hold {name} skipped", "reason": reason})
    logline(d, f"hold {name}: skipped — {reason}"); d["updated"] = now(); dump(p, d)
    print(json.dumps({"ok": True, "hold": name, "status": "skipped", "reason": reason}))
else:
    die("open|check|answer|skip")
PY
