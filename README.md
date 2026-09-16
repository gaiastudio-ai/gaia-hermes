# Gaia — an orchestrator profile for Hermes Agent

**Gaia** is a [Hermes Agent](https://hermes-agent.nousresearch.com) profile that runs software projects end to end with the [GAIA framework](https://github.com/gaiastudio-ai/gaia-framework) inside headless Claude Code (`claude -p`).

You describe what you want built. Gaia creates the project, puts it on GitHub, initialises it with `/gaia-init`, and then drives the whole GAIA lifecycle — brainstorm, PRD, architecture, epics, sprints, stories, development, reviews, retros — on her own. She has a full technical team (the GAIA personas: PM, Architect, Scrum Master, developers, QA, security, DevOps) and she manages them. You are the **stakeholder**: she only comes to you with decisions that are yours — scope, priorities, budget, product questions — and with failures she cannot fix. Sprint planning, retros, stack trade-offs and the like she settles herself.

```
you  ──Telegram / CLI──▶  Gaia (Hermes profile)  ──claude -p──▶  Claude Code + GAIA plugin
                          ▲ stakeholder questions                   │ /gaia-init, /gaia-create-prd,
                          │ phase reports, failures                  │ /gaia-dev-story, /gaia-review-all …
                          └──────────────────────────────────────────┘ GAIA-QUESTION / GAIA-DONE blocks
```

Claude Code can live on the same machine as Hermes or on another one reachable over SSH — the installer asks.

## Requirements

On the **Hermes** machine:

- Hermes Agent installed (`~/.hermes` exists); `python3` (PyYAML recommended)
- for SSH mode: key-based, non-interactive SSH to the Claude Code machine

On the **Claude Code** machine (may be the same one):

- [Claude Code](https://docs.claude.com/en/docs/claude-code) installed and **authenticated** (`claude auth login` or `ANTHROPIC_API_KEY`)
- the GAIA plugin — Gaia checks for it and, if it is missing, tells you she cannot work and offers to install it (`claude plugin marketplace add gaiastudio-ai/gaia-framework` + `claude plugin install gaia@gaiastudio-ai-gaia-framework`)
- `git`, `yq`; optionally `gh` (authenticated) so Gaia can create GitHub repos, and `jq`

## Install

```bash
git clone https://github.com/gaiastudio-ai/gaia-hermes.git
cd gaia-hermes
./install.sh
```

The installer creates the Hermes profile `gaia` (cloned from your default profile so it uses the same model and API keys), copies `SOUL.md` and the `gaia-orchestrator` skill into it, asks where Claude Code is, writes `~/.hermes/profiles/gaia/gaia.yaml`, and runs a doctor check.

Non-interactive example, Claude Code on another machine:

```bash
./install.sh --claude-mode ssh --ssh-host julien@um890 \
             --claude-bin /home/julien/.local/bin/claude \
             --projects-root /home/julien/projects \
             --stakeholder "Julien" --timezone Europe/Berlin --yes
```

Then:

```bash
gaia chat                 # alias Hermes creates for the profile
hermes -p gaia chat       # same thing
```

To have Gaia reach you on Telegram, put a bot token for this profile in `~/.hermes/profiles/gaia/.env` and run `gaia gateway start` (or `gaia gateway install` for a service). Each Hermes profile needs its own bot token.

## First conversation

> **You:** Gaia, run your doctor check.
> **Gaia:** Claude Code 2.1 found on um890, logged in, GAIA plugin 1.216 installed, gh authenticated. Ready.
>
> **You:** Build me a household pantry tracker: scan groceries, track expiry dates, suggest recipes from what's about to expire.
> **Gaia:** One decision before I create it: GitHub org and visibility? (1) `julien/pantry-pal`, private — recommended; (2) public; (3) another org. Reply with a number.
> **You:** 1
> **Gaia:** Created `github.com/julien/pantry-pal`, GAIA initialised. The team needs one thing from you: primary platform — (1) web app, recommended; (2) mobile; (3) mobile + API; (4) web + mobile + API; (5) API only. If I don't hear back I'll go with (1).
> **You:** 1
> **Gaia:** Thanks. Brainstorm and product brief are running; I'll send you the PRD summary when it's ready. Everything else — stack, sprint length, story order — I'm handling with the team.

From here Gaia keeps going. Ask "status" any time, "pause pantry-pal" to stop, "continue pantry-pal" to resume.

## What Gaia does and does not do

| Gaia does | Gaia never does |
|-----------|-----------------|
| creates the project folder, `git init`, first commit, GitHub repo (via `gh`) | edits project files herself — Claude Code does all the work |
| runs `/gaia-init` on every new project before anything else | skips `/gaia-init`, or runs it on an initialised project (that is `/gaia-brownfield`) |
| runs the lifecycle autonomously, phase by phase, sprint by sprint | uses a GAIA command that is not in `references/gaia-commands.csv` |
| answers technical/process questions as the team's lead | asks you sprint-planning or retro questions |
| relays business/product/budget questions to you, rewritten for a non-engineer | invents a stakeholder answer to unblock a run |
| stops at two holds — the product brief she wrote, and the PRD + architecture before any story — until you answer | continues past a hold, answers it herself, or lets it time out into a default |
| messages you on phase completion, gate rejections, failures | pings you on routine progress (unless `notify.on_progress: true`) |
| keeps per-project state and resumes after a restart | stores credentials — env-var names only |

## How it works

**Profile.** `profile/SOUL.md` is Gaia's identity and doctrine. `profile/gaia.yaml.example` is the settings template (Claude Code location, projects root, GitHub defaults, notification policy, per-phase autonomy flags).

**Skill.** `profile/skills/gaia-orchestrator/` is a standard Hermes skill: `SKILL.md` holds the procedures (first use, new project, drive lifecycle, handle a run result, status/continue, changes), `references/` the routing rules, the lifecycle map, the Claude Code protocol and the GAIA command list, and `scripts/` the deterministic helpers:

| script | purpose |
|--------|---------|
| `gaia-doctor.sh` | verifies Claude Code, its login, the GAIA plugin, git/gh/yq and the projects root — locally or over SSH |
| `gaia-install-plugin.sh` | installs/updates the GAIA plugin in Claude Code |
| `gaia-new-project.sh` | creates the directory, git repo and (optionally) GitHub repo; registers state |
| `gaia-claude.sh` | runs `claude -p` for a project, foreground or background; parses the result |
| `gaia-project.sh` | per-project state file: phase, sessions, open questions, decisions, log |

**Headless protocol.** Every `claude -p` run gets `--dangerously-skip-permissions --output-format json` and an appended system prompt that tells Claude Code it is unattended. When the GAIA team needs input, Claude Code stops and emits a tagged block:

```
<<GAIA-QUESTION audience="stakeholder" id="init-scope-platform">>
1. Setup depth: (1) quick — recommended (2) full
2. Primary platform: (1) web (2) mobile (3) …
<<END-GAIA-QUESTION>>
```

`gaia-claude.sh` extracts it and returns `{"status":"question","audience":"stakeholder","session_id":…}`. Gaia routes it (`references/question-routing.md`), gets or makes the answer, and resumes the *same* session with `claude -p --resume <session_id> "<answer>"`. `GAIA-DONE` and `GAIA-BLOCKED` blocks mark completion and hard stops. Sessions live on the Claude Code host, so resuming works over SSH too.

**State.** `~/.hermes/profiles/gaia/projects/<slug>.yaml` tracks phase, sprint, current story, the last Claude session id, open questions and Gaia's own decisions. Full Claude JSON results and stderr of every run are kept under `~/.hermes/profiles/gaia/gaia-runs/<slug>/`.

**Lifecycle.** See [`references/lifecycle.md`](profile/skills/gaia-orchestrator/references/lifecycle.md). Deployment is the only phase that asks first by default (`lifecycle.autonomous.deployment: false`), because it touches real infrastructure.

## Settings reference

`~/.hermes/profiles/gaia/gaia.yaml` — see [`profile/gaia.yaml.example`](profile/gaia.yaml.example) for every key with comments. The ones you are most likely to touch:

| key | meaning |
|-----|---------|
| `claude.mode` | `local` or `ssh` |
| `claude.ssh_host` | `user@host` of the Claude Code machine (ssh mode) |
| `claude.bin` | path to `claude` on that machine |
| `claude.model` | optional `--model` override for headless runs |
| `claude.max_turns` | safety cap per run (default 300) |
| `projects_root` | where new projects are created on the Claude Code machine |
| `github.default_org` / `default_visibility` | leave empty and Gaia asks per project |
| `lifecycle.autonomous.*` | set a phase to `false` to make Gaia ask go/no-go before starting it |
| `lifecycle.holds.*` | `product_brief` and `implementation`, both on by default: the loop stops and the document goes to you; nothing proceeds until you answer |
| `hold_backend` / `hold_commands.*` | `channel` (a card on your messaging channel, you reply) or `command` (plug in an approvals system with buttons and re-sends) |
| `notify.on_progress` | `true` if you want a message after every GAIA command |

## Using the scripts by hand

Everything Gaia runs you can run yourself, which is handy for debugging:

```bash
export HERMES_HOME=~/.hermes/profiles/gaia
S=$HERMES_HOME/skills/gaia-orchestrator/scripts

bash $S/gaia-doctor.sh
bash $S/gaia-new-project.sh pantry-pal --name "Pantry Pal" --description "…" --org julien --visibility private
bash $S/gaia-claude.sh run --project pantry-pal --label init -- "/gaia-init"
bash $S/gaia-claude.sh run --project pantry-pal --label init-answer --resume <session_id> -- "Stakeholder answer: web app. Continue."
bash $S/gaia-claude.sh run --project pantry-pal --label dev-1.1 --background -- "/gaia-dev-story 1.1"
bash $S/gaia-claude.sh wait <run_id> --timeout 240
bash $S/gaia-project.sh summary pantry-pal
```

## Security notes

- Headless runs use `--dangerously-skip-permissions`: Claude Code will run any command the GAIA workflows need inside the project directory. Run it on a machine you dedicate to this, with a user account that owns only `projects_root`.
- Gaia never receives credentials; GAIA's config schema rejects literal secrets, and Gaia's prompts refer to environment-variable names only.
- The SSH user Gaia uses should be able to run `claude`, `git`, `gh` and write to `projects_root` — nothing more.

## Uninstall

```bash
./uninstall.sh                # removes the profile (hermes profile delete gaia)
./uninstall.sh --keep-state   # copies projects/ and gaia-runs/ to ~/gaia-state-backup-<ts> first
```

Project code on the Claude Code machine is never touched.

## License

AGPL-3.0, like the GAIA framework. See [LICENSE](LICENSE).
