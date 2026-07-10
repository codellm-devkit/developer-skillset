#!/usr/bin/env bash
# Consistency check: README.md's "## The Ladder" diagram and "## Routing" table
# must stay byte-identical to skills/using-cldk-devtools/SKILL.md's copies of the
# same two blocks. Run from repo root: bash tests/consistency/check-readme-dispatcher-sync.sh
set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
readme="$root/README.md"
skill="$root/skills/using-cldk-devtools/SKILL.md"
fails=0

for f in "$readme" "$skill"; do
  if [ ! -f "$f" ]; then
    echo "FAIL missing file: $f"
    exit 1
  fi
done

# extract_fenced_after_heading FILE HEADING
# Prints the contents of the first fenced ``` code block that appears after an
# exact-match heading line.
extract_fenced_after_heading() {
  awk -v heading="$2" '
    $0 == heading { found=1; next }
    found && /^```/ { if (in_block) { exit } else { in_block=1; next } }
    found && in_block { print }
  ' "$1"
}

# extract_table_after_heading FILE HEADING
# Prints the contiguous run of `|`-prefixed table rows that appears after an
# exact-match heading line.
extract_table_after_heading() {
  awk -v heading="$2" '
    $0 == heading { found=1; next }
    found && /^\|/ { print; seen=1; next }
    found && seen && $0 !~ /^\|/ { exit }
  ' "$1"
}

check_block() {
  name="$1"; a="$2"; b="$3"
  if diff -u "$a" "$b" >/tmp/check-readme-dispatcher-sync.diff.$$ 2>&1; then
    echo "OK   $name"
  else
    echo "FAIL $name"
    cat /tmp/check-readme-dispatcher-sync.diff.$$
    fails=$((fails+1))
  fi
  rm -f /tmp/check-readme-dispatcher-sync.diff.$$
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

extract_fenced_after_heading "$readme" "## The Ladder" > "$tmp/readme_ladder.txt"
extract_fenced_after_heading "$skill"  "## The Ladder" > "$tmp/skill_ladder.txt"
check_block "ladder diagram" "$tmp/readme_ladder.txt" "$tmp/skill_ladder.txt"

extract_table_after_heading "$readme" "## Routing" > "$tmp/readme_routing.txt"
extract_table_after_heading "$skill"  "## Routing" > "$tmp/skill_routing.txt"
check_block "routing table" "$tmp/readme_routing.txt" "$tmp/skill_routing.txt"

if [ -s "$tmp/readme_ladder.txt" ]; then :; else
  echo "FAIL ladder diagram: extracted empty from README.md — extraction is broken"
  fails=$((fails+1))
fi
if [ -s "$tmp/readme_routing.txt" ]; then :; else
  echo "FAIL routing table: extracted empty from README.md — extraction is broken"
  fails=$((fails+1))
fi

if [ "$fails" -eq 0 ]; then
  echo "All blocks in sync."
  exit 0
else
  echo "$fails block(s) out of sync."
  exit 1
fi
