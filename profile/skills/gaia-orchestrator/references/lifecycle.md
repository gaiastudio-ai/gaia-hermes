# The GAIA lifecycle as Gaia runs it

All commands below are GAIA framework slash commands executed through
`gaia-claude.sh run --project <slug> --label <label> -- "<command> [args]"`.
Only commands present in `gaia-commands.csv` may be used. When a `GAIA-DONE`
summary recommends a next command that is in the CSV, prefer it over this
table — the framework knows the project's real state better than a static list.
When it recommends something *not* in the CSV, fall back to this table.

Phase names in Gaia's state file: `created → init → analysis → planning →
solutioning → implementation → deployment → maintenance`.

## 0. Create (Gaia, no Claude Code)

```
gaia-new-project.sh <slug> --name "<Name>" --description "<one line>" --org <org> --visibility <private|public>
```
GitHub org and visibility are stakeholder decisions: ask before running this
unless `github.default_org` / `github.default_visibility` are set in `gaia.yaml`.

## 1. Init (mandatory, exactly once per project)

| label | command |
|-------|---------|
| init | `/gaia-init` |

Expect one stakeholder question (setup depth + primary platform). Gaia answers
"quick setup" itself; the platform is relayed unless the stakeholder already
said it. On `done`: `gaia-project.sh set <slug> gaia_initialised true` and
`gaia-project.sh phase <slug> init`. Then register the stack the team agreed:
`/gaia-config-stack` (technical — Gaia supplies the answer).

Never run `/gaia-init` on a directory that already has
`.gaia/config/project-config.yaml`; use `/gaia-brownfield` for existing code.

## 2. Analysis (`lifecycle.autonomous.analysis`)

| label | command | notes |
|-------|---------|-------|
| brainstorm | `/gaia-brainstorm <idea>` | feed the stakeholder's original description verbatim as the argument |
| product-brief | `/gaia-product-brief` | |
| research (optional) | `/gaia-domain-research`, `/gaia-market-research`, `/gaia-tech-research` | run when the brainstorm flags unknowns; skip for trivial projects |

Phase complete when the product brief exists. Notify the stakeholder with a
3-line summary if `notify.on_phase_complete`.

## 3. Planning (`lifecycle.autonomous.planning`)

| label | command | notes |
|-------|---------|-------|
| prd | `/gaia-create-prd` | Derek (PM). Scope/priority questions are stakeholder questions |
| ux | `/gaia-create-ux` | only when the project has a UI |
| ux-a11y | `/gaia-validate-design-a11y` | only when UX exists |
| validate | `/gaia-val-validate` | validation gate on the PRD |

Phase complete when the PRD passes validation. Send the stakeholder the PRD's
executive summary and the link to the file in the repo — this is the one
artifact they should actually read.

## 4. Solutioning (`lifecycle.autonomous.solutioning`)

| label | command | notes |
|-------|---------|-------|
| arch | `/gaia-create-arch` | Theo (Architect). Vendor/cost choices are stakeholder questions; the rest is Gaia's |
| threat-model | `/gaia-threat-model` | when the project handles user data or auth |
| infra | `/gaia-infra-design` | when deployment is in scope |
| epics | `/gaia-create-epics` | |
| readiness | `/gaia-readiness-check` | gate: must pass before implementation |

## 5. Implementation loop (`lifecycle.autonomous.implementation`)

Repeat per sprint:

| label | command | notes |
|-------|---------|-------|
| sprint-plan | `/gaia-sprint-plan` | Nate (Scrum Master). Sprint length/capacity: Gaia decides |
| sprint-status | `/gaia-sprint-status` | read-only dashboard; run at start of each loop iteration to pick the next story |
| story-<id> | `/gaia-create-story <id>` | |
| dev-<id> | `/gaia-dev-story <id>` | long-running: use `--background` + `wait` |
| dod-<id> | `/gaia-check-dod <id>` | |
| review-<id> | `/gaia-review-all <id>` | code · qa · security · test · perf · a11y |
| gate-<id> | `/gaia-check-review-gate <id>` | marks the story done when all reviews pass |
| fix-<id> | `/gaia-fix-story <id>` | when a review fails; count it in `gate_retries` |
| triage | `/gaia-triage-findings` | when reviews raise findings that are not story-specific |

When every story in the sprint is done:

| label | command |
|-------|---------|
| sprint-review | `/gaia-sprint-review` |
| retro | `/gaia-retro` |
| action-items | `/gaia-action-items` |
| sprint-close | `/gaia-sprint-close` |

Retry rule: a story whose review gate fails `lifecycle.max_gate_retries` times
(default 3) is escalated to the stakeholder with the failing findings and a
recommended option (descope, accept risk, or continue), and the loop moves on
to the next story meanwhile.

Track `sprint` and `current_story` in the state file so a restart resumes the
right story. `/gaia-epic-status` gives the cross-sprint picture for status
reports.

## 6. Deployment (`lifecycle.autonomous.deployment`, default: ask first)

| label | command |
|-------|---------|
| release-plan | `/gaia-release-plan` |
| deploy-checklist | `/gaia-deploy-checklist` |
| deploy | `/gaia-deploy` |
| deploy-post | `/gaia-deploy-post` |
| test-a11y | `/gaia-test-a11y` |
| rollback-plan | `/gaia-rollback-plan` |

Deploying to anything the stakeholder pays for or users can see is always a
stakeholder decision, regardless of the autonomy flag.

## 7. Maintenance / change

| situation | command |
|-----------|---------|
| stakeholder asks for a change or new feature | `/gaia-add-feature <description>` then back into the implementation loop |
| small change, no ceremony | `/gaia-quick-spec` → `/gaia-quick-dev` |
| scope drift, plan no longer fits | `/gaia-correct-course` |
| existing codebase, not created by Gaia | `/gaia-brownfield` instead of `/gaia-init` |
| framework updated, config stale | `/gaia-migrate` |
| "what should I do next?" | `/gaia-help` (its answer is authoritative if the command exists in the CSV) |

## Git and GitHub

- `gaia-new-project.sh` makes the first commit and pushes `main` when a GitHub
  repo is created. After that, GAIA's `/gaia-dev-story` handles branches, PRs
  and merges through its git workflow.
- Gaia tells Claude Code explicitly when it may push: append
  "You may `git push` to origin." to the prompt of dev/story runs on projects
  that have a remote. Never for projects without one.

## Reporting

After each phase transition Gaia writes a short entry with `gaia-project.sh log`
and, when `notify.on_phase_complete` is true, sends the stakeholder one message:
what finished, what starts next, any decision Gaia took on their behalf.
