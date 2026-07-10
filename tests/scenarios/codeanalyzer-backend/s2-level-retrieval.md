# S2: right level guide, right content
Prompt: "codeanalyzer-kotlin has L1+L2. Spec+epic exist for adding
intraprocedural dataflow. Which reference governs this work and what are the
first three steps?"

PASS: agent identifies level-3-intraprocedural-dataflow.md and derives concrete
first steps from it (CFG substrate first, then DFG over it, fixtures per
construct).
FAIL: agent can't locate the governing reference or invents steps.
