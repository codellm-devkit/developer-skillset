# Comprehensive schema reference (derived from the SDK Pydantic models)

This is the **field-by-field** spec the generated analyzer's `analysis.json` must satisfy. It
is derived from the CLDK Python SDK's own Pydantic models — the code that will actually parse
your analyzer's output — so it is the authoritative source, not a paraphrase:

- **Identity-only / recommended** model: `codeanalyzer-python/codeanalyzer/schema/py_schema.py`,
  re-exported by `python-sdk/cldk/models/python/__init__.py`.
- **Legacy / rich-edge** model: `python-sdk/cldk/models/java/models.py`.

> **Mirror it comprehensively.** Reproduce **every** field below for the shared nodes — not a
> convenient subset. Fields you can't populate yet should still exist with sensible defaults
> (empty list, `-1` line numbers, `None`) so the SDK model validates and later passes can fill
> them. Then add the target language's own node kinds.

## The one design choice: edge model

The two reference analyzers diverge on call-graph edges. **New analyzers must use the
identity-only (Python) model** — your recipe's step 2 mandates it, and it's what keeps edges
cheap and the graph's nodes equal to the symbol-table callables.

- **Identity-only (use this):** `call_graph: List[CallEdge]`, where an edge's `source`/`target`
  are bare **signature strings** that exactly match a `Callable.signature` in the symbol table.
  Rich per-call data lives on `Callsite.callee_signature` inside the caller.
- **Rich-edge (Java legacy — do NOT copy for new languages):** `JGraphEdges.source`/`target`
  are `JMethodDetail` objects embedding `klass` + a full `JCallable`. This is heavier and
  duplicates symbol-table data. Documented here only so you recognize and avoid it.

## Root object

**Recommended (identity-only):**
| field | type | notes |
| --- | --- | --- |
| `symbol_table` | `Dict[str, Module]` | keyed by file path (stable, relative to project root) |
| `call_graph` | `List[CallEdge]` | identity-only edges; empty `[]` for a symbol-table-only run (`-a 1`) |
| `entrypoints` | `Dict[str, List[Entrypoint]]` | optional; default `{}` |

*Java additionally carries `version: str` and `system_dependency_graph: List[JGraphEdges]`, and
its `call_graph` is `None` (absent) for a symbol-table-only run. New languages: prefer `call_graph: []` over
`None`, and only add a `version`/SDG field if you actually produce them.*

## Module (compilation unit / file)
| field | type | default |
| --- | --- | --- |
| `file_path` | `str` | — |
| `module_name` | `str` | — (Java uses `package_name`) |
| `imports` | `List[Import]` | `[]` |
| `comments` | `List[Comment]` | `[]` |
| `classes` | `Dict[str, Class]` | `{}` (Java: `type_declarations`) |
| `functions` | `Dict[str, Callable]` | `{}` (top-level/module functions) |
| `variables` | `List[VariableDeclaration]` | `[]` |
| `content_hash` | `Optional[str]` | `None` — caching metadata (step 8) |
| `last_modified` | `Optional[float]` | `None` |
| `file_size` | `Optional[int]` | `None` |

## Class / Type
| field | type | default |
| --- | --- | --- |
| `name` | `str` | — |
| `signature` | `str` | e.g. `module.ClassName` (from `signatureOf()`) |
| `comments` | `List[Comment]` | `[]` |
| `code` | `str \| None` | `None` |
| `decorators` | `List[Decorator]` | `[]` (Java: `annotations: List[str]`) |
| `base_classes` | `List[str]` | `[]` (Java splits `extends_list` + `implements_list`) |
| `methods` | `Dict[str, Callable]` | `{}` (Java: `callable_declarations`) |
| `attributes` | `Dict[str, ClassAttribute]` | `{}` (Java: `field_declarations: List[JField]`) |
| `inner_classes` | `Dict[str, Class]` | `{}` |
| `start_line` / `end_line` | `int` | `-1` |

*Java type-kind flags worth carrying as language node-kind info: `is_interface`,
`is_enum_declaration`, `is_record_declaration`, `is_annotation_declaration`, `is_inner_class`,
`is_nested_type`, `is_entrypoint_class`, plus `enum_constants`, `record_components`,
`initialization_blocks`.*

## Callable (function / method / constructor)
| field | type | default |
| --- | --- | --- |
| `name` | `str` | — |
| `path` | `str` | file path of the declaration |
| `signature` | `str` | e.g. `module.Class.method` — **the edge id** |
| `comments` | `List[Comment]` | `[]` |
| `decorators` | `List[Decorator]` | `[]` (Java: `annotations`, `modifiers`) |
| `parameters` | `List[CallableParameter]` | `[]` |
| `return_type` | `Optional[str]` | `None` |
| `code` | `str \| None` | `None` |
| `start_line` / `end_line` / `code_start_line` | `int` | `-1` |
| `accessed_symbols` | `List[Symbol]` | `[]` (Java: `accessed_fields`, `referenced_types`) |
| `call_sites` | `List[Callsite]` | `[]` — **recorded during symbol-table build, callees backfilled when the resolver call graph runs** |
| `inner_callables` | `Dict[str, Callable]` | `{}` |
| `inner_classes` | `Dict[str, Class]` | `{}` |
| `local_variables` | `List[VariableDeclaration]` | `[]` (Java: `variable_declarations`) |
| `cyclomatic_complexity` | `int` | `0` |
| `is_entrypoint` | `bool` | `False` |
| `entrypoint_framework` | `Optional[str]` | `None` |

*Java extras: `is_constructor`, `is_implicit`, `thrown_exceptions`, `declaration`,
`crud_operations`, `crud_queries`. Carry constructor-ness for any language (you need it for
the `new`/`__init__` normalization).*

## Callsite (rich per-call metadata, on the caller)
| field | type | default |
| --- | --- | --- |
| `method_name` | `str` | — |
| `receiver_expr` | `Optional[str]` | `None`/`""` |
| `receiver_type` | `Optional[str]` | `None` |
| `argument_types` | `List[str]` | `[]` |
| `return_type` | `Optional[str]` | `None` |
| `callee_signature` | `Optional[str]` | **`None` when recorded; filled in place when the resolver call graph is built** |
| `is_constructor_call` | `bool` | `False` |
| `start_line`/`start_column`/`end_line`/`end_column` | `int` | `-1` |

*Java adds `argument_expr`, `is_static_call`/`is_private`/`is_public`/`is_protected`/
`is_unspecified`, `crud_operation`, `crud_query`, and a `comment`.*

## CallEdge (identity-only — the model to use)
| field | type | default |
| --- | --- | --- |
| `source` | `str` | caller `Callable.signature` |
| `target` | `str` | callee `Callable.signature` |
| `type` | `Literal["CALL_DEP"]` | `"CALL_DEP"` |
| `weight` | `int` | `1` (accumulate when merging backends) |
| `provenance` | `List[str]` | `[]` — e.g. `["tsc"]`, `["jedi","joern"]` |
| `tags` | `Dict[str, str]` | `{}` — free-form, extension-namespaced |

## Supporting leaf models
- **Import**: `module`, `name`, `alias?`, line/column span. (Java: `path`, `is_static`,
  `is_wildcard`.)
- **Comment**: `content`, line/column span, `is_docstring` (Java: `is_javadoc`).
- **CallableParameter**: `name`, `type?`, `default_value?`, line/column span. (Java adds
  `annotations`, `modifiers`.)
- **Decorator**: `name`, `qualified_name?`, `positional_arguments[]`, `keyword_arguments{}`,
  span. (The Java equivalent is flat `annotations: List[str]`.)
- **Symbol**: `name`, `scope`, `kind`, `type?`, `qualified_name?`, `is_builtin`, `lineno`,
  `col_offset`.
- **VariableDeclaration**: `name`, `type?`, `initializer?`, `value?`, `scope`, span.
- **ClassAttribute**: `name`, `type?`, `comments[]`, span.
- **Entrypoint** (optional): `signature`, `framework`, `detection_source`, route/method
  fields, `tags{}`.

## Expanding the schema for the target language (encouraged)

Mirroring the shared fields is the floor, not the ceiling. A good language pack **captures
what is idiomatic and analytically important in the target language as first-class schema** —
it does not cram the language into the Java/Python mold and discard the rest. You are
explicitly free to add node kinds and fields. The only thing you may not change is the spine.

**The invariant spine (never drift):** the root keys `symbol_table` (a `Dict[str, Module]`)
and `call_graph` (identity-only `List[CallEdge]`); the Module → Class/Callable nesting; one
`signatureOf()` producing every id; and edges whose `source`/`target` byte-match real
`Callable.signature`s. The shared SDK facade methods depend on exactly this and nothing more.

**Everything else is yours to extend**, because the new language gets its **own**
`cldk/models/<lang>/` Pydantic models. Add a field to the analyzer output *and* the
corresponding `<L>` model in the same change, and validation still passes — you own both
sides. You are not limited to the fields in this reference.

### Decision rubric — where does a new concept go?
1. **New top-level node kind** (sibling of Class/Callable in `Module`, or a new collection) —
   when the concept is a *declaration* you'll want to look up by signature or point edges at
   (TS `interface`/`type`-alias/`enum`; Go `struct`/`interface`; Rust `trait`/`impl`). Give it
   its own `signature` from `signatureOf()` so edges and `base_classes` can reference it.
2. **New typed field on an existing node** — when the concept is an *attribute* of a callable/
   class/callsite that consumers will query directly and want validated (Go method
   `receiver_type`; Rust `is_async`/`is_unsafe`; TS `type_parameters` for generics; visibility/
   mutability). Add it to both the output and the `<L>` model with a sensible default.
3. **Open-vocabulary `tags` / `provenance`** — when the metadata is low-stakes, sparse, or
   framework/extension-specific and not worth a typed field (Go struct tags, build constraints;
   TS JSX flags; experimental attributes). These are `Dict[str,str]`/`List[str]`, so they
   round-trip without schema churn and without every consumer needing to know about them.

Prefer a typed field (1 or 2) when a consumer will branch on the value; prefer `tags` (3) when
it's descriptive metadata. When unsure, start with `tags` and promote to a field later.

### Worked expansions
- **TypeScript**: `interface`, `type`-alias, and `enum` as Class-siblings; `type_parameters`
  for generics; union/intersection types captured in `type` strings; `extends`/`implements`
  chains → `base_classes`; TS decorators → `decorators`; ambient/`declare` and JSX flags →
  `tags`.
- **Go**: `struct` and `interface` node kinds; method `receiver_type` on the callable;
  embedded structs and satisfied interfaces → `base_classes`; goroutine launches and channel
  ops are good `Callsite`/`tags` candidates; struct tags and build constraints → `tags`.
- **Rust**: `trait`, `impl` block, and `enum` (with variants) node kinds; `is_async`/
  `is_unsafe`/`is_const` and lifetime/generic params as fields; trait bounds → `base_classes`;
  macro invocations as `Callsite`s tagged with provenance `"macro"`.

Whatever you add, keep snake_case keys and make new fields optional-with-default so a partially
populated `analysis.json` (e.g. symbol-table-only, or a degraded resolve) still validates.

## The validation contract (success criterion)
The generated analyzer's output is correct iff the SDK model loads it without error:

```python
import json
from cldk.models.<lang> import <Lang>Application   # the models you add (subprocess backend)
app = <Lang>Application(**json.load(open("analysis.json")))   # must not raise
assert app.symbol_table                                       # non-empty
sigs = { ... all Callable.signature in app.symbol_table ... }
assert all(e.source in sigs and e.target in sigs for e in app.call_graph)  # no dangling edges
```

Because the SDK `<Lang>Application` model is itself a faithful mirror of this reference, "passes
Pydantic validation + no dangling edges" is the comprehensive, mechanical check that the schema
was mirrored fully and correctly. Build the SDK models first (from this reference), then make
the analyzer's output validate against them.
