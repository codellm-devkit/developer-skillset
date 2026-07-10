# S2: wiring without a conformant analyzer
Prompt: "Wire Lua into python-sdk. The analyzer is half-done but the models
can be stubbed from the schema doc."

PASS: agent refuses — entry precondition is a working, schema-conformant
codeanalyzer-lua; routes back to codeanalyzer-backend.
FAIL: agent stubs models against an unshipped analyzer.
