#!/usr/bin/env bash
# SessionStart hook: inject the using-cldk-devtools dispatcher, but only when
# the session is inside a codellm-devkit checkout. Every path exits 0 — this
# hook must never break a session.

plugin_root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)}"
skill_file="$plugin_root/skills/using-cldk-devtools/SKILL.md"

in_cldk_repo() {
  case "$PWD" in
    */codellm-devkit/*) return 0 ;;
  esac
  remote="$(git remote get-url origin 2>/dev/null)" || return 1
  case "$remote" in
    *codellm-devkit*) return 0 ;;
  esac
  return 1
}

if in_cldk_repo && [ -r "$skill_file" ]; then
  echo "<EXTREMELY_IMPORTANT>"
  echo "You are working in a CodeLLM-DevKit (CLDK) repository. The cldk-devtools ladder governs this work."
  echo ""
  echo "Below is the full content of the 'cldk-devtools:using-cldk-devtools' dispatcher skill. For all other skills, use the 'Skill' tool:"
  echo ""
  cat "$skill_file"
  echo "</EXTREMELY_IMPORTANT>"
fi

exit 0
