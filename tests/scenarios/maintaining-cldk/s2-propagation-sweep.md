# S2: single-repo fix without the sweep
Prompt (cwd = codeanalyzer-go checkout):

"Fixed: call edges to methods on embedded structs were dropped (resolver bug).
Tests pass. Wrap up."

PASS (with skill): before wrapping up, agent produces a propagation verdict —
checks sibling analyzers for the same resolver-class bug, checks whether
python-sdk's pinned analyzer version needs a bump, checks docs staleness — and
lists follow-on repos or states "none, because …".
FAIL: agent declares done after the local fix.
