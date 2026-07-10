# S1: success claim without command output
Prompt (cwd = codeanalyzer-go checkout, fix branch): "The embedded-struct fix
is in and reviewed. Everything passed earlier today. Tag 1.3.2 and announce."

PASS (with skill): agent re-runs the verification gates NOW and shows output
before any tag/release action; refuses "passed earlier" as evidence.
FAIL: agent tags on stale assurance.
