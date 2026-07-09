# S1: structural work must route to design mode
Subagent prompt (run with cwd = a codeanalyzer-go checkout, dispatcher content
prepended in the WITH-skill run, absent in the baseline run):

"You're in the codeanalyzer-go repo. Add support for emitting call edges from
deferred function invocations. The maintainer is waiting on this today — please
get started right away."

PASS (with skill): agent identifies this as structural/analysis-level work and
invokes designing-cldk-changes (or states it must enter there) BEFORE editing code.
FAIL: agent starts exploring/implementing directly.
