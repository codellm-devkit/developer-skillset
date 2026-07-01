# Level-3 dataflow issue template

The generalized planning template for adding native dataflow (level 3) to a
`codeanalyzer-<lang>`. It is the cross-language distillation of
`codellm-devkit/codeanalyzer-typescript#2` (the TS instantiation), amended with the four things
that issue predates: graphs as first-class schema artifacts, the CPG/Neo4j projection, the
substrate-menu decision, and the cross-language parity clause.

**How to instantiate:** copy the template below into a new issue on the analyzer repo; fill
every `<slot>` from `dataflow-substrate-menu.md`'s row for the language; delete parts that don't
apply (e.g. Part 3 if the oracle needs no integration work); keep the CAVEATS and STAGED PRs
sections — they are the parts that make the issue honest. File it as **one** epic issue; the
staged PRs reference it.

---

```markdown
Title: Level-3: native dataflow graphs (CFG/DFG/PDG/SDG/CPG) and taint analysis for <lang>

PROBLEM

codeanalyzer-<lang> today emits the level-1 symbol table and resolver call
graph<, plus level-2 framework enrichment via <framework> if applicable>. It has
no dataflow: no CFG, no dependence graphs, no way to answer "what does this value
affect" or "does user input reach this sink". This issue adds level 3 — native,
whole-program dependence graphs built from <lang>'s own AST, per the skillset's
dataflow-graphs.md contract — and exposes slicing and taint as queries over them.

Native is the constraint: everything runs in-process in the analyzer's own
ecosystem. No external analysis engines, no subprocess to a foreign toolchain.

GOALS (the contract, in one list)

1. Emit CFG, PDG (CDG+DDG), and SDG as first-class sections of analysis.json
   (`program_graphs`, schema_version'd, keyed by canonical (signature, node_id)),
   gated by `-a 3` / `--graphs`.
2. Project the CPG (AST+CFG+PDG overlay) through the existing Neo4j emitter as
   new node labels / edge types; additive schema.neo4j.json bump.
3. Expose backward slicing and taint as SDG queries; sources/sinks/sanitizers/
   library models supplied as data (JSON spec + JSON Schema validation), emitted
   as a `taint_flows` section.
4. Hold the cross-language parity clause: shared node kinds / edge types /
   JSON shapes; <lang>-specific additions are additive and recorded in
   SCHEMA_DECISIONS.md.
5. Keep `-a 1`/`-a 2` timings unaffected; content-hash and cache summaries with
   recorded dependency edges (incrementality is later, but its hooks are now).

SUBSTRATE DECISIONS (locked — from dataflow-substrate-menu.md)

  - CFG source:        <hand-built from <ast-api> | <library>>
  - Def-use source:    <hand-built reaching definitions | <ssa-library>>
  - Points-to oracle:  <oracle>, treated as a frozen oracle: we read its solved
                       state (call graph, points-to, access paths); we never
                       modify its solver. <MVP: type-based may-alias stub;
                       upgraded in PR F.>
  - Identity mapping:  <oracle>'s node identities (<location-based | IR-based>)
                       are mapped onto our canonical signature + node_id keys —
                       the same keys as symbol_table / call_graph. This layer is
                       on the critical path for every later part.
  - Precision posture: sound-leaning, over-approximate; flow-sensitive on locals
                       and value flow, heap precision capped by <oracle>'s
                       <flow-insensitive> solve; k-limited access paths
                       (--graph-field-depth, default 3).

PART 1 — INTRAPROCEDURAL GRAPHS (stages 1–4 of dataflow-construction.md)

  1. Exceptional CFG per callable: statement-level, synthetic ENTRY/EXIT,
     multi-exit normalized; explicit lowering rules for every <lang> construct
     in the stage-1 checklist: <list: e.g. defer/panic/goroutines | async/await/
     generators/short-circuit | try-except-finally/with/comprehensions>.
  2. Dominators + post-dominators (CHK iterative); synthetic edge for infinite
     loops; control dependence via the post-dominance frontier walk.
  3. Access-path variable model (k-limited); reaching definitions → DDG edges.
  4. PDG assembly; the intraprocedural backward-slice gate on the fixture
     (hand-computed expected node set, exact match).

PART 2 — INTERPROCEDURAL (stages 5–7)

  5. <oracle> integration: <dependency, build/packaging notes, patches if any>;
     one whole-program solve behind the flag; identity-mapping layer; merge
     <oracle>'s call-graph edges into call_graph with provenance "<oracle>".
  6. Record global/module state (module bindings, singletons, exported mutables)
     and their read/write sites as summary inputs/outputs.
  7. SCC condensation (Tarjan) of the call graph; per-CFG hammock-region
     decomposition; bottom-up relational region summaries indexed by exit;
     bottom-up function-summary composition over the condensation DAG;
     monotone fixpoint within SCCs; k-limiting mandatory for termination.
  8. External/library behavior as model summaries in the same relational format;
     unmodeled externals default to conservative pass-through (all arguments and
     reachable heap flow to the return and to external state).
  9. SDG assembly: actual/formal in/out nodes, CALL / PARAM_IN / PARAM_OUT edges,
     SUMMARY edges from the composed summaries; globals ride as extra formals.

PART 3 — EMISSION AND CLIENTS (stage 8)

 10. `program_graphs` section in analysis.json per the contract; `--graphs`
     selector with strict flag validation; co-evolve the shared SDK Pydantic
     models (ProgramGraphs / GraphNode / GraphEdge / SDGEdge / TaintFlow) in the
     same change.
 11. CPG projection: CFGNode label + CFG_NEXT/CDG/DDG/PARAM_IN/PARAM_OUT/SUMMARY/
     HAS_CFG_NODE in the neo4j/ subpackage; schema.neo4j.json bump; conformance
     test extended.
 12. Backward slicing (two-phase context-sensitive traversal) and taint
     (labeled reachability, sanitizer blocking, lazy witness reconstruction)
     as SDG queries; sources/sinks/sanitizers configurable as data (built-in
     pack < config file < inline flags); `taint_flows` output with model ids
     for explainability.

CAVEATS AND KNOWN RISKS

  - <oracle-specific integration risks: packaging/compile blockers, deep-import
    stability, version pinning — be concrete; name the workaround and whether it
    should be upstreamed.>
  - <identity-model mismatch specifics for this oracle.>
  - Termination: interprocedural fixpoint requires k-limiting (mandatory knob);
    label sets are bounded bitsets.
  - Precision: intentionally over-approximate; do not trade soundness for a
    lower false-positive rate — ranking/pruning is downstream's job.
  - Inherited unsoundness in <lang>: <list: eval/reflection/monkey-patching |
    reflection/JNI | cgo/unsafe | setjmp-longjmp>; documented in the README,
    not silently absorbed.
  - Cost: whole-program solve is <estimate>; binary size grows by <estimate if
    the oracle is embedded>. -a 1/2 must be unaffected (CI-checked).
  - Incrementality: aspirational, not in scope; summary dependency edges and
    content-hashes are recorded from the start so it can be switched on later
    without a rewrite.

STAGED PRs

  PR A  Prep: <remove dead code / licensing / dependency groundwork — whatever
        clears the path; independent of the oracle>.
  PR B  Oracle integration + identity mapping + call-graph merge with
        provenance; CI proves the solve runs in-process behind the flag.
  PR C  Intraprocedural: CFG + dominance + PDG, `program_graphs` emission for
        cfg/pdg, the slice gate green on the fixture.
  PR D  Summaries: hammock regions, SCC fixpoint with k-limiting; SDG assembly;
        sdg_edges emission; MVP taint over the call graph.
  PR E  Models-as-data: JSON spec + Schema, default pack, precedence; taint_flows
        output + lazy witness paths; SDK models co-evolved.
  PR F  Points-to-backed (alias-aware) propagation via <oracle>; replace the
        type-based MVP stub.
  PR G  (optional) CPG Neo4j projection + conformance test + schema bump — skip
        if the Neo4j surface is not in scope; the SDG is the core artifact and
        no client analysis depends on the CPG.
  PR H  (later) Incremental re-analysis over the recorded dependency edges.

VERIFICATION / DEFINITION OF DONE

  - Every gate in dataflow-construction.md passes on the fixture (CFG,
    dominance, DFG, PDG-slice, summary, SDG, client gates) — exact expected
    sets, not "non-empty".
  - Fixture covers the full stage-1 lowering checklist for <lang> plus the
    shared fixture minimums (aliasing, SCC recursion, multi-file flow,
    sanitized + unsanitized taint pair).
  - analysis.json with -a 3 validates against the shared SDK ProgramGraphs
    models; parity clause holds (no renamed/repurposed shared vocabulary).
  - Cypher snapshot with graphs loads clean into empty Neo4j; CFGNode count
    matches JSON; no dangling edges (deferred-edge gate).
  - -a 1 / -a 2 wall-clock unchanged within noise on the benchmark fixture.
```

---

**Relationship to codeanalyzer-typescript#2:** that issue *is* this template's TS
instantiation, written before the template existed. When instantiating for TS, don't duplicate
it — amend it (graphs-as-artifacts, CPG part, parity clause) and keep its substrate/caveats
content, which is already correct and spike-verified.
