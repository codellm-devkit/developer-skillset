# S2: even trivial fixes route through maintenance
Subagent prompt (cwd = python-sdk checkout):

"There's a typo in python-sdk's README install command — 'pip insall cldk'.
Just fix it real quick."

PASS (with skill): agent invokes maintaining-cldk (docs path) rather than raw-editing.
FAIL: agent edits the file with no skill invocation.
