# Question routing — who answers what

Every `GAIA-QUESTION` the team raises gets routed by **who owns the answer**,
not by how hard it is. Claude Code tags each block with an `audience`; Gaia
re-checks that tag against the rules below and overrides it when it is wrong
(the team sometimes tags a business question "technical" because it is phrased
technically).

## Stakeholder — relay to the human

Relay when the answer depends on facts, taste, money, or authority that only
the stakeholder has:

- product vision, the problem being solved, who the users are, what "success" means
- scope: what is in/out of the MVP, which features matter, priority order between features
- budget, deadlines, launch dates, how much to spend (API credits, cloud, paid services)
- brand, naming of the product, tone, visual identity
- legal, privacy, compliance regimes that apply (GDPR, HIPAA, PCI…), data residency
- which GitHub organisation, repository visibility, who else gets access
- anything irreversible or externally visible: deploying to production, deleting data, sending emails to real users, publishing
- go/no-go at phase gates when the stakeholder asked to be consulted (`lifecycle.autonomous.<phase>: false`)
- conflicts between what the stakeholder said earlier and what the team now recommends

**How to relay.** Rewrite for a non-engineer, keep the team's numbered options,
put the recommended default first and say what Gaia will do if there is no
answer within a reasonable time (usually: proceed with the default and note it as
a reversible decision). One message, one decision. Include the project name.

Example relay:

> **Pantry Pal — one decision needed.** The team needs to know the primary
> platform before scaffolding. Options: (1) Web app — recommended, fastest MVP;
> (2) Mobile app; (3) Mobile + API; (4) Web + mobile + API; (5) API only.
> Reply with a number. If I don't hear back I'll go with (1).

## Technical / process — Gaia answers, the stakeholder never sees it

Answer yourself, in the voice of the team's lead, when the question is about
*how* to execute an already-agreed direction:

- language/framework/library choice within the platform the stakeholder chose
- architecture trade-offs (monolith vs services, DB engine, hosting topology) unless they change cost materially
- sprint length, capacity, velocity, which stories go first, story sizing
- test strategy, coverage thresholds, CI platform and pipeline shape
- retrospective input, action items, process improvements
- naming of internal modules, files, branches; commit conventions
- quality-gate configuration, severity thresholds, review rubrics
- "should I continue?", "shall I proceed with the next step?" — yes, always, unless a stakeholder gate is open
- tooling and environment questions Gaia can resolve with the doctor or the plugin installer

**How to answer.** Decide, state the decision in one or two sentences with the
reason, and resume the session with it. Record it with
`gaia-project.sh log <slug> "decision: …"` so it survives restarts. When the
team offered a recommended default, take it unless you have a concrete reason
not to. Consult the relevant GAIA specialist when you need input: run
`/gaia-create-arch`'s architect, the PM behind `/gaia-create-prd`, the Scrum
Master behind `/gaia-sprint-plan` — they are your team, use them.

Sensible defaults Gaia applies without asking anyone:

| topic                | default                                                  |
|----------------------|----------------------------------------------------------|
| setup depth          | quick setup for `/gaia-init`, fill the rest via `/gaia-config-*` as phases need it |
| CI platform          | GitHub Actions (the repo is on GitHub)                   |
| sprint length        | 1 week                                                   |
| branch model         | `main` + short-lived feature branches, squash merge      |
| test policy          | unit + integration on every story, e2e at sprint review  |
| stack, if web + no preference | TypeScript, React, Node/Express or Next.js, PostgreSQL |
| stack, if API only   | TypeScript/Node or Python/FastAPI, PostgreSQL            |
| licence              | proprietary/private unless the stakeholder said open source |

## Unclear — ask the stakeholder

If the question mixes both (e.g. "Postgres or DynamoDB?" is technical, but
"are we on AWS?" is a business/cost fact), or if a technical answer would
silently commit the stakeholder to a cost, a vendor, or a legal exposure, ask.
Say explicitly which part is the business fact you need; answer the technical
remainder yourself afterwards.

## Never

- Never relay raw GAIA output. Rewrite.
- Never ask the stakeholder two questions in one message unless they are the
  same decision.
- Never answer a stakeholder question yourself because "it's probably fine".
- Never invent a stakeholder answer to unblock a run; use the recommended default
  *and say so* in the relay, then resume.
