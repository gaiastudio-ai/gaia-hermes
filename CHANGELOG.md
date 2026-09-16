# Changelog

## 1.1.1 — 2026-09-16

- Standing stakeholder directive: `gaia-project.sh set <slug> directive "<text>"`
  records an instruction the loop follows ahead of the lifecycle table until the
  stakeholder clears it. `summary` prints it. Used to make blocker-clearing work
  visible and ordered rather than discovered by validation passes.

## 1.1.0 — 2026-09-16

Stakeholder holds: a hold stops the loop, puts a document in front of the
stakeholder, and nothing proceeds until they answer. Not a notification.

- Two holds, both on by default (`lifecycle.holds.*`): `product_brief` after a
  brief Gaia authored (skipped, and the skip recorded with its reason, when the
  stakeholder supplied the brief); `implementation` before any story runs — the
  PRD and the architecture together, with the readiness verdict on the card.
- Answers are three taps or three words: approve / send back / stop. Send back
  asks the stakeholder for direction as a follow-up question, never a field on
  the card. Stop pauses the whole project.
- The hold lives in the project file (`holds.<name>`), so it holds whatever
  transport carried the card. Two backends: `channel` (Gaia sends the card, the
  stakeholder replies) and `command` (an external approvals system files the
  hold, re-sends it, and reports the answer).
- New script `gaia-hold.sh` (`open`, `check`, `answer`, `skip`); `summary` and
  `list` show holds; a hard rule that a hold is never answered by Gaia.

Why: on Portfolio Agents (Sept 2026) the brief, the PRD, eighteen architecture
revisions and a merge to `main` happened without the stakeholder being asked
once; the phase-complete notification fired and the loop continued.

## 1.0.0 — 2026-09-04

Initial release.

- Hermes profile `gaia`: `SOUL.md` orchestrator identity and doctrine, `gaia.yaml` settings
- Skill `gaia-orchestrator`: procedures for first use, new project, autonomous lifecycle, run-result handling, status/continue, changes
- Headless Claude Code protocol (`GAIA-QUESTION` / `GAIA-DONE` / `GAIA-BLOCKED`) with session resume
- Scripts: doctor, plugin installer, project bootstrap (git + GitHub via `gh`), `claude -p` runner (local/SSH, foreground/background), project state registry
- Installer / uninstaller
