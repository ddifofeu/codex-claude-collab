# Codex + Claude Code collaboration: architecture

This kit lets two coding agents, OpenAI Codex and Anthropic Claude Code, work on one repository in turns. You switch tools when one hits its usage limit. The next one picks up from the repository alone, with no shared memory and no conversation history.

The whole design follows from one fact: **neither agent remembers anything the other did.** Each session starts cold. So everything needed to continue has to live in files both tools read, and those files have to be committed with the work.

## 1. Architecture

### 1.1 Components

```
target repo (committed)                 local only (never committed)
├── AGENTS.md      conventions, commands, rules    ├── .collab/prompts/codex.md
├── CLAUDE.md      @AGENTS.md + Claude-only notes  ├── .collab/prompts/claude-code.md
├── HANDOFF.md     live state + Lock line          ├── .git/hooks/pre-commit
└── scripts/lock.sh  the only writer of the Lock   └── .git/info/exclude  (+ ".collab/")

kit repo (codex-claude-collab): template/, prompts/, scripts/, hooks/
```

| Component | Who reads it | Changes how often | Purpose |
|---|---|---|---|
| `AGENTS.md` | Codex natively; Claude Code via `CLAUDE.md` | Rarely | Stable conventions: project summary, commands, rules |
| `CLAUDE.md` | Claude Code | Rarely | Imports `AGENTS.md` (`@AGENTS.md`) and adds Claude-only rules (memory, `/compact`) |
| `HANDOFF.md` | Both, first thing | Every checkpoint | The single source of live state: lock, goal, status, decisions, verification, files touched, notes |
| `scripts/lock.sh` | Both | Never by hand | Reads and writes the Lock line; status, validate, acquire, release |
| `.collab/prompts/*.md` | You paste or point each tool at its prompt | Rarely | The per-tool session protocol: start, work, hand off |
| `.git/hooks/pre-commit` | git | Never | Refuses a commit if the Lock line is malformed |

### 1.2 Splitting stable from live

There are two kinds of files, kept apart deliberately:

- **Stable** (`AGENTS.md`, `CLAUDE.md`, the prompts) holds *how we work*. These files change rarely, so both tools can load them every session without the cost of churn.
- **Live** (`HANDOFF.md`) holds *where we are*. It is rewritten at every checkpoint, kept short (validation warns past 150 lines), and organised in fixed sections so a cold agent knows where to look.

Putting live state into `AGENTS.md` would make the instructions drift. Keeping a second live ledger alongside it would let two state files disagree. The kit has exactly one live file.

### 1.3 The lock

The Lock is one line in `HANDOFF.md`:

```
ACTIVE: none
ACTIVE: codex | started 2026-01-15 14:30 | branch feature/login-form
```

`lock.sh status` turns that line into a state and an exit code:

| State | Condition | Exit | Agent does |
|---|---|---|---|
| FREE | `ACTIVE: none` | 0 | acquire, then work |
| HELD | holder set, younger than `STALE_HOURS` (default 2) | 1 | stop and ask the user |
| STALE | holder set, older than `STALE_HOURS` | 0 | tell the user, check the tree for unexplained changes, then acquire |
| MALFORMED | no `ACTIVE:` line, or a holder line without `started YYYY-MM-DD HH:MM` | 2 | stop and ask the user |

`acquire` refuses on HELD or MALFORMED, and otherwise writes the holder line. `release` writes `ACTIVE: none`. `validate` passes unless the line is malformed, and warns when the file grows past 150 lines. The pre-commit hook runs `validate`, so a broken lock line can't be committed. The hook does nothing in repositories or branches without `HANDOFF.md` and `scripts/lock.sh`.

The lock is **advisory**. It stops two cooperating agents from colliding; it can't stop an agent that skips the protocol.

### 1.4 Session lifecycle

```
 START                          WORK (loop)                        HAND OFF
 read AGENTS/HANDOFF            small verifiable step              stop new steps
 git status / log / branch  ──▶ run tests                      ──▶ commit WIP or describe it
 lock.sh status                 checkpoint: update HANDOFF,         rewrite Next as runnable list
   FREE/STALE → acquire           git add <paths>; commit "wip: …"  lock.sh release
   HELD/MALFORMED → ask user    out-of-scope → Next/Notes          reply: done / next / tree clean
 repo wins over HANDOFF         unsure → Decisions: OPEN, ask
 feature branch
```

Three rules make a cold start work:

1. **The repo is the source of truth.** If `HANDOFF.md` disagrees with git or the tests, the agent records the discrepancy in Notes and goes with the repo.
2. **Checkpoint as if the session could end any moment.** A usage limit can cut a session off mid-step, so `HANDOFF.md` is updated and committed at every milestone, not only at the end.
3. **"Next" must run without the user.** It's an ordered list with file paths and the first command, so the other tool can start at once.

### 1.5 Installing

`scripts/install.sh <repo>` copies the templates, `lock.sh` and the prompts, installs the hook and adds `.collab/` to `.git/info/exclude`. It **never overwrites**: an existing file that differs is reported as `EXISTS, differs` and left for you to merge. A pre-commit hook that isn't the kit's is also left alone, and the script tells you to add the kit's hook by hand. It ends by reminding you to fill in the `AGENTS.md` placeholders and commit.

## 2. Pros and cons

### Pros

- **Tool-neutral, plain files.** Markdown, one bash script and git. No server, daemon, API or account. Either tool, or a human, can read and edit every part.
- **Survives memory loss.** Continuity doesn't depend on either tool's memory, conversation history or summaries. Claude Code is told explicitly not to keep handoff state in its own auto-memory.
- **Versioned and auditable.** `HANDOFF.md` changes in the same commit as the work, so `git log -p HANDOFF.md` shows who did what, what was verified, and when.
- **Cheap on tokens.** One short live file, read once per session. The stable files are loaded automatically and rarely change.
- **Fails safe.** Unclear states (HELD, MALFORMED, STALE, decisions marked OPEN) stop the agent and hand the decision to you instead of letting it guess.
- **Verification is part of the record.** Work isn't Done without a recorded test result, so the next agent can trust Status or see what's unverified.
- **Non-destructive install.** It refuses to overwrite and shows differences, so existing `AGENTS.md` and `CLAUDE.md` files are merged by you, not clobbered.

### Cons and limits

- **The lock is advisory and on-disk only.** It works only if both agents follow the protocol. Two agents sharing a checkout can still switch its branch under each other if one never checks the lock.
- **There is one lock per working tree, not per repository.** `HANDOFF.md` is a file on a branch. Two worktrees or two branches each have their own copy, so each one's lock only covers its own checkout. Two agents on two worktrees don't see each other's locks. Use one shared checkout plus the lock, or separate worktrees plus your own coordination.
- **`HANDOFF.md` conflicts on every merge or rebase.** Every branch edits the same sections. Expect to resolve them by hand, as in the migration in section 3.
- **A committed lock can travel.** If a branch is committed while its Lock line is HELD, merging it brings a held lock onto `main`. Always `release` and commit *before* merging. The pre-commit hook checks the format, not the holder.
- **`release` leaves the tree dirty** until the `HANDOFF.md` change is committed. Commit right after releasing, or release before the final commit.
- **Staleness uses local clock time** with no timezone, and a fixed 2-hour threshold. A long but live session reads as STALE; set `STALE_HOURS` to suit.
- **Hooks and prompts aren't versioned.** `.git/hooks` and `.collab/` live outside git, so every fresh clone or new machine needs `install.sh` again. The hook can also be skipped with `git commit --no-verify`.
- **Checkpoints stage files by name.** The prompts say `git add <paths>` then `git commit -m "wip: …"`. An earlier version used `git commit -am`, which silently skips new files; `git add -A` would be worse, sweeping in scratch files and the user's own media.
- **Squash, then fast-forward.** Checkpoints leave a trail of `wip:` commits; `AGENTS.md` asks for them to be squashed into one commit on the branch, so the merge into `main` can be a fast-forward. Rewriting a pushed branch then needs `git push --force-with-lease`.
- **Discipline costs time.** Checkpoints, verification records and lock steps add work to every session, and an agent that skips them breaks the handoff for the other.
- **Tool approvals interrupt you.** Codex asks before shell commands such as `git restore` or `lock.sh`. Approve them one at a time ("Yes, proceed"). An "always allow" match is by command prefix, and a command that *starts* with an allowed prefix can chain anything after it.

## 3. Adopting it in an existing repository

A typical case: the repository already has its own `AGENTS.md`, `CLAUDE.md` and a hand-kept ledger file. The installer adds `HANDOFF.md`, `scripts/lock.sh`, `.collab/prompts/` and the hook, and reports `AGENTS.md` and `CLAUDE.md` as `EXISTS, differs`. Merge them by hand:

- **`AGENTS.md`:** keep the kit's structure (Project, Commands, Rules), fill in the repo's real commands (including any full verification chain), and append the repo's own rules after the kit's.
- **`CLAUDE.md`:** `@AGENTS.md`, the kit's Claude rules, then any Claude-only notes the repo already had (commit trailer, how to run visual checks).
- **Move live state.** Sections of an older ledger that hold current state, recent work, open issues or next steps move into `HANDOFF.md`. The old file keeps only stable reference and points to `HANDOFF.md`, so there's one live file.
- **Check tools that walk the folder.** Any script that scans the working directory rather than `git ls-files` (inventory, integrity or lint checks) will see the untracked `.collab/` and agent dirs such as `.claude/`, and give different results per checkout. Exclude them there.
- **Bring in-flight branches across.** A branch started before the setup won't have `HANDOFF.md`. Rebase it onto the setup commit, take the base's versions of the moved ledger files, carry its live state into `HANDOFF.md`, acquire the lock, rebuild generated files instead of hand-merging them, re-run verification, squash, `git push --force-with-lease`, and release the lock.

Checks to run on the kit after installing: `status` on a fresh file prints FREE (exit 0); `acquire` then `status` prints HELD (exit 1), and `release` returns it to FREE; a corrupted Lock line makes `validate` exit 2; in a throwaway clone, the hook blocks a commit with a corrupted lock and allows it once fixed.

### Lessons

- **Use `git worktree add` when both tools are active at once.** One checkout shared by two live agents means one can switch the branch under the other.
- **Release and commit before handing off.** Otherwise the next agent finds HELD and stops.
- **Paste a migration prompt when an agent is mid-branch at setup.** The other tool needs to know where live state moved and how to resolve the expected conflicts.
- **Regenerate build outputs after a rebase rather than hand-merging them,** then amend.

## 4. Full implementation

Layout of the kit:

```
codex-claude-collab/
├── template/AGENTS.md      → <repo>/AGENTS.md
├── template/CLAUDE.md      → <repo>/CLAUDE.md
├── template/HANDOFF.md     → <repo>/HANDOFF.md
├── scripts/lock.sh         → <repo>/scripts/lock.sh
├── scripts/install.sh      (run from the kit: install.sh <repo>)
├── prompts/codex.md        → <repo>/.collab/prompts/codex.md
├── prompts/claude-code.md  → <repo>/.collab/prompts/claude-code.md
└── hooks/pre-commit        → <repo>/.git/hooks/pre-commit
```

Usage:

```bash
/path/to/codex-claude-collab/scripts/install.sh /path/to/repo
# merge any "EXISTS, differs" files by hand, fill in AGENTS.md placeholders
cd /path/to/repo && git add AGENTS.md CLAUDE.md HANDOFF.md scripts/lock.sh && git commit
scripts/lock.sh status        # FREE / HELD / STALE / MALFORMED
scripts/lock.sh acquire codex "$(git branch --show-current)"
scripts/lock.sh release
```

Every file follows, verbatim.


### `template/AGENTS.md`

~~~~markdown
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
~~~~

### `template/CLAUDE.md`

~~~~markdown
@AGENTS.md

Claude Code specific:
- Follow the Lock and handoff protocol in HANDOFF.md and .collab/prompts/claude-code.md.
- Do not store handoff state in auto-memory. Live state belongs in HANDOFF.md.
- Use /compact only at a checkpoint, after HANDOFF.md is updated.
~~~~

### `template/HANDOFF.md`

~~~~markdown
# Handoff

## Lock
ACTIVE: none

## Goal
<what we are building and the definition of done>

## Status
- Done: <bullets with commit hashes>
- In progress: <item and exact stopping point>
- Next: <ordered steps, with file paths and the first command to run>

## Decisions
- <decision> — <why> — <date>
- OPEN: <question awaiting the user>

## Verification
- Last test run: <command> → <pass/fail>, <date>, <commit>
- Known failures: <list or none>

## Files touched this session
- <path> — <what changed>

## Notes for the next agent
- <gotchas, and approaches that failed and why>
~~~~

### `prompts/codex.md`

~~~~markdown
You are working in a shared repository that Claude Code also works on. We switch
tools when token limits are hit, so continuity depends on HANDOFF.md being accurate.

## 1. Start
1. Read AGENTS.md and HANDOFF.md.
2. Run `git status`, `git log --oneline -10`, `git branch --show-current`.
3. Run `scripts/lock.sh status`.
   - Exit 1 (HELD by the other tool, recent): stop and ask me.
   - Exit 2 (malformed): stop and ask me.
   - Exit 0 (FREE or STALE): run `scripts/lock.sh acquire codex <branch>`. If it was
     STALE, tell me first, and check the tree for changes the ledger does not explain.
4. Treat the repo as the source of truth. If HANDOFF.md disagrees with git or the
   test results, add the discrepancy to Notes and proceed from the repo state.
5. Create a feature branch if you are not already on one.

## 2. Work
- Small, verifiable steps. Run the AGENTS.md test command after each change.
- Checkpoint at every milestone (passing test, finished module, resolved bug): edit
  only the changed sections of HANDOFF.md (Status, Verification, Files touched), then
  `git add <paths>` (by name, so new files are included and nothing unrelated is),
  then `git commit -m "wip: <what>"`. Assume the session can end at any moment.
- Search before opening large files. Do not re-read files already in context unless
  they changed.
- Out-of-scope bugs go to Next or Notes. Do not fix them silently.
- Unsure about a decision: add it to Decisions as OPEN and ask me.

## 3. Hand off
When I say "hand off", or when you sense you are near your limit:
1. Stop starting new steps.
2. Commit WIP, or make sure HANDOFF.md describes every uncommitted change.
3. Rewrite Next as an ordered list the other tool can run without asking me anything.
4. Run `scripts/lock.sh release`.
5. Reply with three lines: done, next, and whether the tree is clean.
~~~~

### `prompts/claude-code.md`

~~~~markdown
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
~~~~

### `scripts/lock.sh`

~~~~bash
#!/usr/bin/env bash
# Lock management for the handoff ledger.
# Usage: lock.sh status | validate | acquire <codex|claude-code> <branch> | release
# Exit codes: 0 FREE/STALE/OK, 1 HELD, 2 MALFORMED
# Env: LEDGER (default HANDOFF.md), STALE_HOURS (default 2)
set -euo pipefail
LEDGER="${LEDGER:-HANDOFF.md}"
STALE_HOURS="${STALE_HOURS:-2}"
cmd="${1:-status}"
[ -f "$LEDGER" ] || { echo "MALFORMED: $LEDGER not found"; exit 2; }

status() {
  python3 - "$LEDGER" "$STALE_HOURS" <<'PY'
import re, sys, datetime
path, stale = sys.argv[1], float(sys.argv[2])
line = next((l for l in open(path) if l.startswith('ACTIVE:')), None)
if line is None:
    print("MALFORMED: no ACTIVE line"); sys.exit(2)
if line.startswith('ACTIVE: none'):
    print("FREE"); sys.exit(0)
m = re.search(r'started (\d{4}-\d{2}-\d{2} \d{2}:\d{2})', line)
if not m:
    print("MALFORMED: no start time in ACTIVE line"); sys.exit(2)
started = datetime.datetime.strptime(m.group(1), '%Y-%m-%d %H:%M')
age = (datetime.datetime.now() - started).total_seconds() / 3600
if age > stale:
    print(f"STALE ({age:.1f}h): {line.strip()}"); sys.exit(0)
print(f"HELD ({age:.1f}h): {line.strip()}"); sys.exit(1)
PY
}

set_active() {
  python3 - "$LEDGER" "$1" <<'PY'
import sys
path, new = sys.argv[1], sys.argv[2]
lines = open(path).read().split('\n')
for i, l in enumerate(lines):
    if l.startswith('ACTIVE:'):
        lines[i] = new; break
else:
    sys.exit("no ACTIVE line to replace")
with open(path, 'w') as f:
    f.write('\n'.join(lines))
PY
}

case "$cmd" in
  status)
    status ;;
  validate)
    rc=0; status >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 2 ]; then status; exit 2; fi
    n=$(wc -l < "$LEDGER")
    if [ "$n" -gt 150 ]; then echo "WARN: $LEDGER is $n lines; archive old entries"; fi
    echo "OK: $LEDGER validated" ;;
  acquire)
    tool="${2:?tool required: codex or claude-code}"
    branch="${3:-$(git branch --show-current 2>/dev/null || echo unknown)}"
    rc=0; s=$(status 2>&1) || rc=$?
    if [ "$rc" -eq 1 ]; then echo "$s"; echo "Refusing: lock held."; exit 1; fi
    if [ "$rc" -eq 2 ]; then echo "$s"; exit 2; fi
    set_active "ACTIVE: $tool | started $(date '+%Y-%m-%d %H:%M') | branch $branch"
    echo "Lock acquired by $tool on $branch" ;;
  release)
    set_active "ACTIVE: none"
    echo "Lock released" ;;
  *)
    echo "usage: lock.sh status|validate|acquire <tool> <branch>|release"; exit 2 ;;
esac
~~~~

### `scripts/install.sh`

~~~~bash
#!/usr/bin/env bash
# Deploys the collaboration setup into a target git repo.
# Usage: install.sh /path/to/target-repo
# Never overwrites existing files; reports differences instead.
set -euo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
T="${1:?usage: install.sh <target-repo>}"
[ -d "$T/.git" ] || { echo "Not a git repo: $T"; exit 1; }

copy_safe() { # src dst
  if [ -e "$2" ]; then
    if diff -q "$1" "$2" >/dev/null; then echo "unchanged: ${2#$T/}";
    else echo "EXISTS, differs (not overwritten): ${2#$T/}"; fi
  else
    mkdir -p "$(dirname "$2")"; cp "$1" "$2"; echo "installed: ${2#$T/}"
  fi
}

copy_safe "$SRC/template/AGENTS.md"  "$T/AGENTS.md"
copy_safe "$SRC/template/CLAUDE.md"  "$T/CLAUDE.md"
copy_safe "$SRC/template/HANDOFF.md" "$T/HANDOFF.md"
copy_safe "$SRC/scripts/lock.sh"     "$T/scripts/lock.sh"
chmod +x "$T/scripts/lock.sh"
copy_safe "$SRC/prompts/codex.md"       "$T/.collab/prompts/codex.md"
copy_safe "$SRC/prompts/claude-code.md" "$T/.collab/prompts/claude-code.md"

HOOK="$T/.git/hooks/pre-commit"
if [ -e "$HOOK" ] && ! grep -q "codex-claude-collab" "$HOOK"; then
  echo "EXISTING pre-commit hook found; add this manually: $SRC/hooks/pre-commit"
else
  cp "$SRC/hooks/pre-commit" "$HOOK"; chmod +x "$HOOK"; echo "installed: .git/hooks/pre-commit"
fi

# Keep local-only collab prompts out of git status noise
EX="$T/.git/info/exclude"; touch "$EX"
grep -qxF ".collab/" "$EX" || echo ".collab/" >> "$EX"

echo "Done. Next: review HANDOFF.md, fill in AGENTS.md commands, then commit."
~~~~

### `hooks/pre-commit`

~~~~bash
#!/usr/bin/env bash
# managed-by: codex-claude-collab
# Blocks commits only when HANDOFF.md has a malformed Lock line.
[ -f HANDOFF.md ] && [ -x scripts/lock.sh ] || exit 0
out=$(mktemp)
trap 'rm -f "$out"' EXIT
if ! scripts/lock.sh validate >"$out" 2>&1; then
  cat "$out"
  echo "pre-commit: fix the Lock line in HANDOFF.md before committing (or use --no-verify)."
  exit 1
fi
grep WARN "$out" || true
exit 0
~~~~
