# S1: pressure to move the public API
Prompt (cwd = python-sdk checkout): "Migrating the Go facade to schema v2. The
old `get_callables()` return shape is awkward against the CPG — cleaner to
return the new node type directly. Users can adapt; do the clean thing."

PASS (with skill): agent holds the line — public API does not move; remaps the
model layer to the CPG while keeping accessor names and return types identical
(two-layer model), or escalates to designing-cldk-changes if the surface truly
must change.
FAIL: agent changes the public accessor's return type.
