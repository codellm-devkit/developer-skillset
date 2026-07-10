# The two-layer model: keep the public API while the schema moves

The analyzer (built by **codeanalyzer-backend**) emits the canonical schema — one
additive node-tree with typed edge overlays (a CPG). The authoritative model is the
keystone `skills/designing-cldk-changes/references/canonical-schema.md`; **design mode
owns it**. This file states how the **SDK** encodes models over that shape **while
keeping the public API identical**. You do not redesign the schema here; you mirror it
and preserve the facade surface.

> Always build and validate against a **real sample** `analysis.json` from the analyzer
> (at each `max_level`), not against this summary or the keystone prose. The complete,
> authoritative field list is whatever the sample actually contains.

## Why this rung needs two layers

The schema is **one additive node-tree + typed edge lists, identical across languages**
(the parity clause: one `Node`, one `Edge`, one `Application`). The public API — the
`CLDK.<lang>(...)` factory, the `<Lang>Analysis` facade, the `<Lang>AnalysisBackend`
ABC, and every accessor's **name, signature, and return type** — must not move. You
hold both at once with a **two-layer model**: model the tree **once**, and re-express
the old per-language return types as **thin views** over it.

Migrating an existing language from an older schema is therefore a **major SDK release**
(see the bottom section) — but a major *version*, not a *breaking API*: importers and
callers are unchanged.

## The schema shape the models load

- **Root is an envelope, not `Application`.** `{ schema_version, language, max_level,
  k_limit?, analyzer{name,version}, application }`. `max_level` is authoritative — read it;
  never sniff for keys.
- **`application`** = `{ id: can://<lang>/<app>, kind, symbol_table{path→module},
  call_graph[], param_in[], param_out[] }`. `symbol_table` and `call_graph` live
  **inside** `application`.
- **Named-map containment**: `module → types{name→type} / functions{sig→callable}`;
  `type → callables{sig→callable} / fields{name→field}`; `callable → body{local-id→node}`.
- **One `Node` shape** with a `kind` string discriminator (`module|class|struct|
  interface|enum|function|method|statement|call|entry|formal_in|…`) plus `id`, `span`
  (with **byte offsets**). Language flavor is a `kind` *value*; language extras are
  **additive optional fields** (+ open-vocab `tags{}`). Absent = no fact (no `null`).
- **`module.source`** holds the whole file's text once; every node's text is a
  **byte-slice** of it (`module.source[node.span.bytes]`) — there is **no per-callable
  `code` field**.
- **Call sites are `call` nodes in `body{}`** with a `callee` id that refines `null →
  id` at L2 — **not** a `call_sites[]` array of `Callsite` objects (`get_call_sites`
  is an L1 accessor).
- **Edges are `{ src, dst, …attrs }` referencing node ids**, in lists keyed by the list
  name (the list name *is* the type — no `type`/`CALL_DEP` field, no `CallEdge` model).
  Intra-callable overlays (`cfg`/`cdg`/`ddg`/`summary`) hang on the callable;
  cross-callable (`call_graph`/`param_in`/`param_out`) on the application. `prov` on a
  `ddg` edge is `["ssa"]`=syntactic (L3) vs `["points-to"]`=semantic (L4).
- **The join key is the `id`** (a `can://` URI), not `signature`. `signature` survives
  as the callable's human-readable field (== the id's last path segment); the facade
  maps signature→id at the boundary.

### The `can://` id grammar (the keystone defers here for it)

Durable ids (≥ callable) are a containment path with an application segment so multiple
apps in one language don't collide:

```
can://<lang>/<app>/<file>/<type>/<callable-signature>
can://go/myapp/src/util.go/Hasher/Hash(string)uint64
```

Ordinal ids (< callable) address statements/synthetic vertices within a callable:

```
<callable-id>@<line>:<col>     e.g. …/Hash(string)uint64@15:2      (a statement)
<callable-id>@<tag>            e.g. …/Hash(string)uint64@entry     (synthetic vertex)
                                    …@formal_in:0, …@16:2/actual_in:0
```

The `/ @ :` delimiters are chosen not to collide with the durable-symbol grammar. Keep
this grammar in lockstep with the keystone's § Identity and the upstream `cldk://` RFC.

## Layer 1 — the canonical models, modeled ONCE

New shared package `cldk/models/cpg/`, validating the schema for *every* language:

```python
class Span(_NullSafeBase):
    start: Tuple[int, int]; end: Tuple[int, int]; bytes: Tuple[int, int]   # [from,to] → O(1) slice

class Node(_NullSafeBase):
    id: str; kind: str; span: Optional[Span] = None; parent: Optional[str] = None
    # type-node:     base_types[], interfaces[], modifiers[], decorators[], callables{}, fields{}
    # callable-node: signature, parameters[], return_type, error_channel[], metrics{}, refs{},
    #                body{local-id→Node}, cfg[], cdg[], ddg[], summary[]
    # body-node:     callee (null→id refinement), arguments[], of
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

class Analyzer(_NullSafeBase):
    name: str; version: str

class AnalysisPayload(_NullSafeBase):   # the envelope / manifest — .application is the tree
    schema_version: str; language: str; max_level: int; k_limit: Optional[int]=None
    analyzer: Optional[Analyzer]=None; application: Application
```

Prefer a single `Node` with a **string** `kind` over per-language subclasses or a rigid
`Literal` union: an open-vocab `kind` loads kinds added later; a rigid hierarchy can't.
Keep **`_NullSafeBase`** on every shared model — Go/Rust/C still serialize empty
collections as `null` (mechanics in `python-sdk-wiring.md § Common pitfalls`). Note this
`cpg/` package is the schema-v2 target; the SDK on disk may still carry per-language v1
trees until the first language migrates and builds it — **verify per SDK**.

## Layer 2 — compat views, per-language names preserved

The old return types become thin `(node, module)` wrappers exposing the **old field
names** as `@property`/`@computed_field`, exported under the old names so every import
path and attribute surface is unchanged:

```python
class CallableView:
    def __init__(self, node, module): self._n, self._m = node, module
    @property
    def signature(self): return self._n.signature
    @property
    def code(self):                                    # was a stored field; now a slice
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

### Remap table — old return type → view over the CPG

| Old per-language name | New backing | What it becomes |
| --- | --- | --- |
| `<L>Callable` | `CallableView(node, module)` | same `.signature`/`.parameters`/`.code`/`.call_sites` — `.code` is a source slice, `.call_sites` are `body` `call` nodes |
| `<L>Class` / `<L>Type` | `TypeView(node, module)` | `.methods`/`.attributes` = kind-filters over one `callables{}`/`fields{}` |
| `<L>Module` | `ModuleView(node, module)` | `.classes`/`.interfaces`/`.enums` = kind-filters over one `types{}` |
| `<L>Callsite` | `CallsiteView(node, module)` | `{callee, arguments, span}` off a `call` node — no `CallEdge`/rich-edge model |
| `<L>Application` | `Application` | the envelope's `.application` tree directly |

Per-language `__init__.py` shrinks to aliases + language-kind/field registration:

```python
# cldk/models/<lang>/__init__.py — no per-language schema tree anymore
from cldk.models.cpg.views import CallableView, TypeView, ModuleView, CallsiteView
from cldk.models.cpg.models import Application
<L>Callable, <L>Class, <L>Module, <L>Callsite, <L>Application = \
    CallableView, TypeView, ModuleView, CallsiteView, Application
```

All "keep the same public shape" work concentrates in this small, shared view layer.

## Compat shims — the legacy entry path

The current entry API is a per-language factory (`CLDK.<lang>(project_path=...,
backend=...)`); the older `CLDK(language="<lang>").analysis(project_path=...)` stays
wired as a **compat shim** that forwards to the factory. Keep it working — it is part of
the frozen surface — but the factory methods are canonical (`python-sdk-wiring.md § 4`).

## What genuinely cannot stay identical (be honest in the release notes)

The API surface is preserved, but these semantics *do* shift — document each:

1. **`nx.DiGraph` node keys: signature → `can://` id.** `get_call_graph()` /
   `get_class_hierarchy()` nodes were signature strings; now they key by durable id
   (signatures aren't globally unique). Attach `signature` as a node attribute and offer
   a signature→id resolver, but the **node key type changes**.
2. **`.code` / `get_method_body()` is a computed slice**, identical *when
   `module.source` is present* — so the **Neo4j backend is lossy for body text** if
   `source` wasn't projected (`neo4j-backend.md`). Parity is "same model modulo
   documented lossiness."
3. **Call-site payload thins.** The `call` node carries `{callee, arguments, span}`;
   richer fields (`receiver_type`, `argument_types`) exist only if the analyzer added
   them additively. `get_call_sites()` keeps its return *type*; some fields may be `None`.
4. **Rich call edges retire.** Edges are identity-only `{src,dst,prov,weight}`; the
   old detail-on-the-edge is gone. `get_callers`/`get_callees` still return detail, but
   it is **reconstructed by id-join**; call-site-level linking lives in L4 `param_*`.
5. **`external_symbols` / phantom nodes change.** "No dangling endpoints" + "edge only
   when resolved" means externals are materialized as stub nodes or the edge is omitted,
   not parked in a separate map. Re-express reachability that relied on phantom nodes.
6. **`get_call_graph_json()` / `model_dump_json()` content changes** (envelope keys) —
   return type `str` is stable; consumers parsing the string by old keys break.
7. **`AnalysisLevel` gains L1–L4** (`body` begins at L1 with call sites, completes at
   L3); the level→flag mapping must be re-derived from `max_level`.

## What a "major SDK release" means here

Migrating a language's model layer to a new schema major is a **major SDK version bump**
because: (a) the analyzer dependency is major-bumped and the pin moves in lockstep
across every SDK; (b) the seven documented semantic shifts above can break consumers who
reached *past* the public API into node-key types or JSON string internals. It is **not**
a breaking change to the public API itself — the Iron Rule holds: names, signatures, and
return types are frozen behind the view layer. Cut the SDK release only after the
analyzer release is cut (`skills/designing-cldk-changes/references/schema-migration.md`).

Mechanics of encoding all this: `python-sdk-wiring.md` (Python), `typescript-sdk-wiring.md`
(TS), `neo4j-backend.md` (the graph backend), `sdk-testing.md` (fixtures + gates).
