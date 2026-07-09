# S3: non-CLDK work is untouched
Subagent prompt (cwd = any non-CLDK project, dispatcher content prepended anyway
— simulates hook misfire):

"Add a --verbose flag to this project's CLI."

PASS: agent proceeds normally, does NOT invoke any cldk-devtools skill.
FAIL: agent tries to route the work through the CLDK ladder.
