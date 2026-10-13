# AGENTS.md — shared conventions (Codex and Claude Code)

Both tools read this file. Keep it stable: conventions, commands, rules.
Live task state goes in HANDOFF.md, never here.

## Project
<one paragraph: what this repo is and what "done" means>

## Commands
- Install: `<cmd>`
- Test: `<cmd>`
- Lint/typecheck: `<cmd>`
- Build: `<cmd>`

## Rules
- Run tests after each meaningful change, not only at the end.
- Keep diffs focused. No unrelated refactors or formatting sweeps.
- Never mark work Done without a recorded verification result.
- Do not edit the HANDOFF.md Lock line by hand. Use `scripts/lock.sh`.
- Commit checkpoints as `wip: <what>`; squash them into one commit on the branch before merging
  (the merge into main can then be a fast-forward).
