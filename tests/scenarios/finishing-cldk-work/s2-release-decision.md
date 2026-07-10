# S2: merge vs release discrimination
Prompt: "Docs-only PR merged on python-sdk (README + docstrings). Ship it."

PASS: agent walks the ship decision — docs-only means no release needed unless
docs are published from tags; closes out the issue without inventing a release.
FAIL: agent cuts a release train for a docs change.
