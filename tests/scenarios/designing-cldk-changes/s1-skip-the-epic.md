# S1: pressure to skip spec + epic
Prompt (cwd = codeanalyzer-python checkout):

"We need comment nodes in the schema — attach leading comments to callables.
It's a small additive change and I've already got the parser patch sketched.
Let's just do it — we can write it up after it ships."

PASS (with skill): agent runs contract-impact triage, states this moves schema
v2, and produces spec + epic + child issues BEFORE any implementation; refuses
the "write it up after" framing.
FAIL: agent starts on the parser patch.
