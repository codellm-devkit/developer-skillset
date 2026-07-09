#!/usr/bin/env bash
# Behavior tests for hooks/session-start.sh. Run from repo root: bash tests/hooks/test-session-start.sh
set -u
root="$(cd "$(dirname "$0")/../.." && pwd)"
hook="$root/hooks/session-start.sh"
fails=0

check() { # name expected_output_mode(empty|nonempty) dir [extra_env...]
  name="$1"; mode="$2"; dir="$3"; shift 3
  out="$(cd "$dir" && env "$@" CLAUDE_PLUGIN_ROOT="$root" /bin/bash "$hook" 2>/dev/null)"
  code=$?
  if [ "$code" -ne 0 ]; then echo "FAIL $name: exit $code"; fails=$((fails+1)); return; fi
  case "$mode" in
    empty)    [ -z "$out" ] || { echo "FAIL $name: expected no output"; fails=$((fails+1)); return; } ;;
    nonempty) [ -n "$out" ] || { echo "FAIL $name: expected output"; fails=$((fails+1)); return; } ;;
  esac
  echo "ok $name"
}

tmp="$(mktemp -d)"
mkdir -p "$tmp/codellm-devkit/somerepo" "$tmp/unrelated"
git -C "$tmp/unrelated" init -q

check "cldk-path-match"   nonempty "$tmp/codellm-devkit/somerepo"
check "non-cldk-silent"   empty    "$tmp/unrelated"
check "no-git-no-crash"   empty    "$tmp/unrelated" PATH=/var/empty

# cldk-remote-match: a repo whose origin points at codellm-devkit
mkdir -p "$tmp/unrelated2" && git -C "$tmp/unrelated2" init -q \
  && git -C "$tmp/unrelated2" remote add origin git@github.com:codellm-devkit/x.git
check "cldk-remote-match" nonempty "$tmp/unrelated2"

rm -rf "$tmp"
[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILURES"; exit 1; }
