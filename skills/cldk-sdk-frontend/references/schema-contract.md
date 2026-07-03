# The analysis.json contract the SDK models must satisfy (v2)

The analyzer (built by the **codeanalyzer-backend** skill) emits schema **v2** — one additive
node-tree with typed edge overlays (a CPG). The authoritative model is the backend keystone
`codeanalyzer-backend/references/canonical-schema.md` (+ its `schema-reference.md`); this file
states how the **SDK** encodes Pydantic models over that shape **while keeping the public API
identical**. You don't redesign the schema here; you mirror it and preserve the facade surface.

> Always build and validate against a **real v2 sample** `analysis.json` from the analyzer (at each
> `max_level`), not against this summary.

## The v1→v2 shift, in one paragraph

v1 was **N per-language Pydantic trees** — `TSApplication{symbol_table:{path→TSModule}, call_graph:
[TSCallEdge]}`, each with its own `TSClass/TSInterface/TSCallable/TSCallsite`. v2 is **one additive
node-tree + typed edge lists, identical across languages**. The public API — `CLDK.<lang>(...)`, the
`<Lang>Analysis` facade, the `<Lang>AnalysisBackend` ABC, and every accessor's **name and return
type** — must not move. You hold both at once with a **two-layer model** (below): model the tree
**once**, and re-express the old `<L>*` return types as **thin views** over it.

## The v2 shape (what the models load)

- **Root is an envelope, not `Application`.** `{ schema_version, language, max_level, k_limit?,
  application }`. `max_level` is authoritative — read it; never sniff for keys.
- **`application`** = `{ id: can://<lang>/<app>, kind, symbol_table{path→module}, call_graph[],
  param_in[], param_out[] }`. `symbol_table` and `call_graph` live **inside** `application`.
- **Named-map containment**: `module → types{name→type} / functions{sig→callable}`; `type →
  callables{sig→callable} / fields{name→field}`; `callable → body{local-id→node}`.
- **One `Node` shape** with a `kind` discriminator (`module|class|struct|interface|enum|function|
  method|statement|call|entry|formal_in|…`) and `id`, `span` (with **byte offsets**). Language
  flavor is a `kind` *value*; language extras are **additive optional fields** (+ open-vocab
  `tags{}`). Absent = no fact (no `null`).
- **`module.source`** holds the whole file's text once; every node's text is a **byte-slice** of it
  (`module.source[node.span.bytes]`) — there is **no per-callable `code` field**.
- **Call sites are `call` nodes in `body{}`** with a `callee` id that refines `null → id` at L2 —
  **not** a `call_sites[]` array of `Callsite` objects. (`get_call_sites` is an L1 accessor.)
- **Edges are `{ src, dst, …attrs }` referencing node ids**, split into lists keyed by the list
  name (the list name *is* the type — **no `type`/`CALL_DEP` field, no `CallEdge` model**). Intra-
  callable overlays (`cfg`/`cdg`/`ddg`/`summary`) hang on the callable; cross-callable
  (`call_graph`/`param_in`/`param_out`) on the application. `prov` on a `ddg` edge is
  `["ssa"]`=syntactic (L3) vs `["points-to"]`=semantic (L4).
- **The join key is the `id`** (a `can://` URI), not `signature`. `signature` survives as the
  callable's human-readable field (== the id's last path segment); the facade maps
  signature→id at the boundary.

## The two-layer model (how the same API survives)

**Layer 1 — canonical, modeled ONCE** (new shared package `cldk/models/cpg/`), validating v2 for
*every* language (the parity clause: one `Node`, one `Edge`, one `Application`):

```python
class Span(_NullSafeBase):
    start: Tuple[int, int]; end: Tuple[int, int]; bytes: Tuple[int, int]   # [from,to] → O(1) slice

class Node(_NullSafeBase):
    id: str; kind: str; span: Optional[Span] = None; parent: Optional[str] = None
    # type-node: base_types[], interfaces[], modifiers[], decorators[], callables{}, fields{}
    # callable-node: signature, parameters[], return_type, error_channel[], metrics{}, refs{},
    #                body{local-id→Node}, cfg[], cdg[], ddg[], summary[]
    # body-node: callee (null→id refinement), arguments[], of
    # language extras: additive Optional fields + tags: Dict[str,str]

class Edge(_NullSafeBase):
    src: str; dst: str; kind: Optional[str] = None; var: Optional[str] = None
    prov: List[str] = []; weight: int = 1

class Module(_NullSafeBase):
    id: str; kind: Literal["module"]="module"; package: Optional[str]=None; source: str=""
    imports: List[Import]=[]; types: Dict[str,Node]={}; functions: Dict[str,Node]={}; content_hash: Optional[str]=None

class Application(_NullSafeBase):
    id: str; kind: Literal["application"]="application"
    symbol_table: Dict[str, Module]; call_graph: List[Edge]=[]; param_in: List[Edge]=[]; param_out: List[Edge]=[]

class AnalysisPayload(_NullSafeBase):   # the envelope / manifest
    schema_version: str; language: str; max_level: int; k_limit: Optional[int]=None; application: Application
```

Keep **`_NullSafeBase`** on every shared model — Go/Rust/C still serialize empty collections as
`null`. Prefer a single `Node` with a string `kind` over per-language subclasses or a `Literal`
discriminated union: an open-vocab `kind` loads kinds added later; a rigid hierarchy can't.

**Layer 2 — compat views, per-language names preserved.** The old return types become thin
`(node, module)` wrappers with `@property`/`@computed_field`, exported under the old names so import
paths and attribute surfaces are unchanged:

```python
# cldk/models/typescript/__init__.py  (and java/, go/, …) — now just aliases + language kind/field registration
TSCallable = CallableView   # same .signature/.parameters/.is_async …
TSClass    = TypeView       # + computed .code, .methods, .attributes
TSModule   = ModuleView     # + computed .classes/.interfaces/.enums via kind-filter over one types{}
TSCallsite = CallsiteView
TSApplication = Application
```

```python
class CallableView:
    def __init__(self, node, module): self._n, self._m = node, module
    @property
    def signature(self): return self._n.signature
    @property
    def code(self):                                    # was stored; now a slice
        f, t = self._n.span.bytes; return self._m.source[f:t]
    @property
    def call_sites(self):                              # was a field; now body 'call' nodes
        return [CallsiteView(c, self._m) for c in self._n.body.values() if c.kind == "call"]

class ModuleView:
    @property
    def classes(self):    return {k:TypeView(v,self._m) for k,v in self._m.types.items() if v.kind=="class"}
    @property
    def interfaces(self): return {k:TypeView(v,self._m) for k,v in self._m.types.items() if v.kind=="interface"}
```

The v1 per-language container split (`TSModule.classes/.interfaces/.enums`) collapses to one
`types{}` keyed by `kind`; the old attribute names are restored as computed **kind-filters**. All
"keep the same public shape" work concentrates in this small, shared view layer.

## Conventions (unchanged from v1)

- **snake_case keys** — field names match the JSON keys so the models load.
- **`analysis.json` is the facade's only read** (or compact JSON on stdout); the Neo4j graph is the
  co-primary surface the Neo4j backend reads (`neo4j-backend.md`).
- **Open-vocab fields stay strings/string-maps** (`prov`, `tags`) so a persisted payload loads
  without the producing extension.

## What genuinely cannot stay identical (be honest in the migration)

The API surface is preserved, but these semantics *do* shift — document them in the SDK release
notes:

1. **`nx.DiGraph` node keys: signature → `can://` id.** `get_call_graph()` / `get_class_hierarchy()`
   nodes were signature strings; v2 keys by durable id (signatures aren't globally unique — the
   reason v2 uses full-path ids). Attach `signature` as a node attribute and offer a
   signature→id resolver, but the **node key type changes**.
2. **`.code` / `get_method_body()` is a computed slice**, identical *when `module.source` is
   present* — so the **Neo4j backend is lossy for body text** if `source` wasn't projected. Parity
   is "same model modulo documented lossiness."
3. **Call-site payload thins.** The v2 `call` node carries `{callee, arguments, span}`; richer
   fields (`receiver_type`, `argument_types`) exist only if the analyzer added them as additive
   fields. `get_call_sites()` keeps its return *type*; some fields may be `None`.
4. **Rich call edges retire.** Edges are identity-only `{src,dst,prov,weight}`; Java's
   `JMethodDetail`-on-the-edge is gone. `get_callers/get_callees` still return detail, but it's
   **reconstructed by id-join**; call-site-level linking lives in L4 `param_*`.
5. **`external_symbols` / phantom nodes change.** v2's "no dangling endpoints" + "edge only when
   resolved" means externals are materialized as stub nodes or the edge is omitted, not parked in a
   separate map. Re-express any reachability that relied on phantom nodes.
6. **`get_call_graph_json()` / `model_dump_json()` content changes** (v2 envelope keys) — return
   type `str` is stable; consumers parsing the string by old keys break.
7. **`AnalysisLevel` gains L1–L4** (`body` begins at L1 with call sites, completes at L3); the
   `_level_flag()` mapping must be re-derived from `max_level`.

Mechanics of encoding all this: `python-sdk-wiring.md` (Python), `typescript-sdk-wiring.md` (TS),
`neo4j-backend.md` (the graph backend), `sdk-testing.md` (fixtures + gates).
