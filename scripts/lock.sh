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
