# Gaia ⇄ Claude Code protocol

Every headless run is `claude -p` on the Claude Code host. Claude Code cannot
ask interactive questions in `-p` mode (there is no TTY and `AskUserQuestion`
is unavailable), so Gaia appends the system prompt below to every run. It turns
"I need input" into a machine-readable block that `gaia-claude.sh` extracts.

## System prompt appended to every run

```
You are running NON-INTERACTIVELY under Gaia, an orchestrator agent, via `claude -p`.
There is no human at the terminal. Follow these rules exactly:

1. Work autonomously. Make reasonable engineering decisions yourself and record them.
2. NEVER wait for input mid-turn. If you need an answer before you can continue,
   STOP and end your response with exactly one block:

   <<GAIA-QUESTION audience="stakeholder|technical" id="short-id">>
   <one clear question, plus numbered options with a recommended default if applicable>
   <<END-GAIA-QUESTION>>

   audience="stakeholder" = business, product vision, users, scope, priorities,
   budget, timeline, brand, legal/compliance, GitHub org/visibility, spending money.
   audience="technical" = stack within agreed direction, architecture trade-offs,
   sprint length/capacity, story order, test strategy, tooling, naming, CI platform.
   If unsure, use audience="stakeholder".
   Ask ONE question per block. Bundle related sub-questions into that one block.
   Gaia will answer by resuming this session; continue from where you stopped.

3. When the requested command/phase has fully completed, end with:

   <<GAIA-DONE>>
   <3-8 line summary: artifacts written, gates passed, next recommended command>
   <<END-GAIA-DONE>>

4. If you are blocked by something you cannot fix (missing tool, failing gate after
   retries, broken environment), end with:

   <<GAIA-BLOCKED reason="short-reason">>
   <what failed, what you tried, what would unblock it>
   <<END-GAIA-BLOCKED>>

5. Never print secrets. Refer to credentials by environment-variable name only.
6. Do not run `git push` to a remote unless the instruction explicitly says to.
```

## Output contract of `gaia-claude.sh run`

`gaia-claude.sh` always prints one JSON object on stdout (the full Claude Code
JSON result is saved alongside the transcript under `$HERMES_HOME/gaia-runs/`):

```json
{
  "ok": true,
  "run_id": "20260904T101500Z-init",
  "session_id": "3e7d…",
  "status": "question | done | blocked | ended | error",
  "audience": "stakeholder | technical | null",
  "question_id": "short-id | null",
  "message": "the question / summary / error text",
  "num_turns": 42,
  "cost_usd": 1.23,
  "duration_s": 310,
  "result_file": "/home/you/.hermes/gaia-runs/<slug>/20260904T101500Z-init.json"
}
```

`status` meanings:

| status   | what happened                                             | what Gaia does next                                   |
|----------|-----------------------------------------------------------|-------------------------------------------------------|
| question | Claude stopped with a `GAIA-QUESTION` block               | route by `audience` (see question-routing.md), then `run --resume <session_id>` with the answer |
| done     | Claude emitted `GAIA-DONE`                                | log, update state, start the next lifecycle command   |
| blocked  | Claude emitted `GAIA-BLOCKED`                             | retry once if transient, else escalate to stakeholder |
| ended    | Claude ended its turn without any marker (e.g. hit `max_turns`) | inspect `message`; usually `run --resume` with "continue" |
| error    | the CLI failed (non-zero exit, auth, SSH, plugin missing) | run doctor, fix, retry; escalate if it persists       |

## Resuming

`gaia-claude.sh run --project <slug> --resume <session_id> -- "<answer>"`

Sessions are stored on the Claude Code host, so resuming works identically in
`local` and `ssh` mode. Always resume the session that asked the question —
never start a fresh session to answer a question.

## Slash commands in headless mode

GAIA skills are invoked by putting the slash command in the prompt:

```
gaia-claude.sh run --project my-app --label init -- "/gaia-init"
gaia-claude.sh run --project my-app --label prd  -- "/gaia-create-prd"
gaia-claude.sh run --project my-app --label story-3 -- "/gaia-dev-story 1.3"
```

Anything after the command is passed as the skill's `$ARGUMENTS`. Extra context
for the team (e.g. answers Gaia already collected) can follow on new lines in
the same prompt.
