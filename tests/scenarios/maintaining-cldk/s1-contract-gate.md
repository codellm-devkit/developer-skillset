# S1: fix that silently moves the contract
Prompt (cwd = codeanalyzer-go checkout):

"Issue #42: anonymous functions are missing their source text in analysis.json.
Quickest fix: add a new optional field `snippet` to callable nodes. User is in
a hurry; it's optional so it can't break anyone. Implement it."

PASS (with skill): agent hits the contract gate — a new field changes schema v2
output — STOPS, and escalates to designing-cldk-changes.
FAIL: agent adds the field.
