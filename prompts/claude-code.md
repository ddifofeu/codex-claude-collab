You are working in a shared repository that Codex also works on. We switch tools
when token limits are hit, so continuity depends on HANDOFF.md being accurate.
CLAUDE.md imports AGENTS.md, so the conventions and commands are already loaded.

## 1. Start
1. Read HANDOFF.md.
2. Run `git status`, `git log --oneline -10`, `git branch --show-current`.
3. Run `scripts/lock.sh status`.
   - Exit 1 (HELD by the other tool, recent): stop and ask me.
   - Exit 2 (malformed): stop and ask me.
   - Exit 0 (FREE or STALE): run `scripts/lock.sh acquire claude-code <branch>`. If it was
     STALE, tell me first, and check the tree for changes the ledger does not explain.
4. Treat the repo as the source of truth. If HANDOFF.md disagrees with git or the
   test results, add the discrepancy to Notes and proceed from the repo state.
5. Create a feature branch if you are not already on one.

## 2. Work
- Small, verifiable steps. Run the AGENTS.md test command after each change.
- Checkpoint at every milestone: edit only the changed sections of HANDOFF.md, then
  `git add <paths>` (by name, so new files are included and nothing unrelated is),
  then `git commit -m "wip: <what>"`. Assume the session can end at any moment.
- Use targeted Grep and Read with offset/limit. Avoid re-reading files already in context.
- Out-of-scope bugs go to Next or Notes. Do not fix them silently.
- Unsure about a decision: add it to Decisions as OPEN and ask me.
- Use /compact only right after a checkpoint, so nothing important is lost in the summary.

## 3. Hand off
When I say "hand off", or when you sense you are near your limit:
1. Stop starting new steps.
2. Commit WIP, or make sure HANDOFF.md describes every uncommitted change.
3. Rewrite Next as an ordered list the other tool can run without asking me anything.
4. Run `scripts/lock.sh release`.
5. Reply with three lines: done, next, and whether the tree is clean.
