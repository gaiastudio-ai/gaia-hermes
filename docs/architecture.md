# Architecture

## Components

```
┌──────────────────────── Hermes host ────────────────────────┐
│  Hermes Agent, profile "gaia"  (HERMES_HOME=~/.hermes/profiles/gaia)
│   ├── SOUL.md                 identity + doctrine
│   ├── config.yaml / .env      model, provider, gateway token (cloned from default)
│   ├── gaia.yaml               Gaia settings (Claude host, projects root, policy)
│   ├── skills/gaia-orchestrator/
│   │    ├── SKILL.md           procedures Gaia follows
│   │    ├── references/        routing rules, lifecycle map, protocol, command list
│   │    └── scripts/           doctor · new-project · claude runner · state
│   ├── projects/<slug>.yaml    per-project state
│   └── gaia-runs/<slug>/       every claude -p result (json), stderr, meta
└──────────────┬───────────────────────────────────────────────┘
               │ local exec  — or —  ssh user@host 'bash -lc …'
┌──────────────▼──────────── Claude Code host ─────────────────┐
│  claude -p --output-format json --dangerously-skip-permissions
│         --append-system-prompt <protocol> [--resume <sid>] "<prompt>"
│  GAIA plugin (gaia@gaiastudio-ai-gaia-framework): /gaia-* skills, agents, scripts
│  projects_root/<slug>/  git repo, .gaia/ config + state, code
└──────────────────────────────────────────────────────────────┘
```

## Control flow for one GAIA command

1. Gaia (LLM, in Hermes) decides the next command from `lifecycle.md` + project state.
2. `gaia-claude.sh run --project <slug> --label <l> [--resume <sid>] -- "<cmd>"`
   - resolves the project dir on the Claude host
   - builds the `claude` argv, appends the protocol system prompt
   - executes locally or over SSH with stdin closed; stdout → `gaia-runs/<slug>/<run>.json`, stderr → `.stderr.log`, timing → `.meta`
   - parses the JSON result, finds `GAIA-QUESTION | GAIA-DONE | GAIA-BLOCKED`, and prints the compact contract
   - records `last_session_id`, `last_run_id`, `last_command` on the project state
3. Gaia branches on `status`:
   - `question` → routing (stakeholder ⇒ relay + stop; technical ⇒ decide + `--resume`)
   - `done` → update phase/sprint/story, next command
   - `blocked` / `ended` / `error` → retry policy, doctor, escalate

Long commands (`/gaia-dev-story`, `/gaia-review-all`) use `--background` and
`wait --timeout 240` polling so Hermes' terminal tool never blocks for the
whole build.

## Why an appended system prompt instead of parsing free text

`claude -p` has no interactive channel: `AskUserQuestion` is unavailable and a
GAIA skill that "asks the user" simply ends its turn with prose. The appended
prompt converts that into a tagged block with an `audience` attribute that
Claude Code fills in from its own understanding of the question. Gaia still
re-validates the audience against `question-routing.md`, because Claude Code
occasionally tags a business question "technical" when it is phrased
technically. A trailing-`?` heuristic covers runs that forget the tag.

## Why state lives in Hermes, not only in the repo

GAIA keeps its own state in `.gaia/` (config, sprint-status.yaml, story files)
and that stays authoritative for the *project*. Gaia's `projects/<slug>.yaml`
holds what GAIA cannot know: the Claude session id to resume, questions
relayed to the human and their answers, decisions Gaia took on the team's
behalf, and pause/retry counters. Both survive a Hermes restart.

## Extending

- New GAIA release with new commands: regenerate `references/gaia-commands.csv`
  from `plugins/gaia/knowledge/workflow-manifest.csv` in the gaia-framework repo
  (plus the few skills that are not in the manifest: sprint-review, sprint-close, deploy).
- Different messaging transport: nothing to change — Hermes' gateway handles it;
  `notify.*` only governs *when* Gaia interrupts.
- Multiple Claude hosts: one Hermes profile per host (`./install.sh --profile gaia-lab --ssh-host …`).
