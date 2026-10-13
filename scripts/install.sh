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
