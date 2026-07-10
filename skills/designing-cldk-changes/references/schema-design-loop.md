# The analyzer-side schema design loop (comparison-and-differentiation)

This is the **analyzer-side** design loop of `designing-cldk-changes` — invoked when the
Contract-Impact Triage says a change touches an analyzer's schema output. It designs the schema;
it does **not** implement it. Actually walking files to fill the tree is the backend's job
(`skills/codeanalyzer-backend/references/symbol-table-construction.md`), and it runs *after* this
loop's decisions are made, spec'd, and issued.

The **shared spine is already designed** — it is the v2 keystone (`references/canonical-schema.md`):
the node tree, the `can://` ids, the additive levels, the edge families. This loop is **not**
re-designing that. It confirms the **language-specific expansion** — which `type` / `callable` /
`body` kinds, which `cfg`-edge kinds, and which typed fields this language adds to the spine (the
parity clause: add at the leaves, never rename the shared vocabulary). You anchor on the keystone
**plus the mature reference analyzers** (**Java** and **Python**, and **C** for procedural
targets), interrogate how the target language genuinely differs, and — crucially — **bring every
divergence to the user as a decision** rather than choosing silently. Do it **node by node**, not
all at once, recording each answer in `.claude/SCHEMA_DECISIONS.md` in the generated analyzer repo.

This is the intellectual core of a language pack. Run it for every schema node the change touches.

## The golden rule: surface divergences, don't resolve them yourself

The agent does **not** get to quietly pick how a node is shaped when the references disagree or
when the target language introduces something new. Each such point is the user's call. Your job is
to make the decision easy and well-informed: show how each reference analyzer handled it, explain
the tradeoffs, recommend a default, and **ask** (`AskUserQuestion`). This is what keeps the schema
faithful to how *this* team wants to model *their* language — and it is where the human's judgment
is most valuable.

## The loop (per schema node)

For each node — spine first (`module` → `type` → `callable` → `call` → `call_graph` edge), then
the language's own kinds:

### 1. Anchor
Open the *same* node in **every** mature reference analyzer and read them side by side (paths are
relative to the located reference repos — a local sibling checkout, else a `/tmp` clone):
- Java: `python-sdk/cldk/models/java/models.py`
- Python: `codeanalyzer-python/codeanalyzer/schema/py_schema.py` (re-exported by
  `python-sdk/cldk/models/python/__init__.py`)
- C (procedural, non-class anchor): `python-sdk/cldk/models/c/models.py` — read this too when
  the target language has no classes (structs + free functions, ADTs).

Catalog two things: (a) the **shared fields** — the invariant spine you keep as-is; and (b)
**every place the references disagree** — each disagreement is a divergence point for the user.

### 2. Differentiate
Ask the language-semantics question: **"How is the `<lang>` language structurally different
here?"** (constructs the language has, not any application domain). Each genuinely new concept the
language introduces is *also* a decision point — even if neither reference has it.

### 3. Decide each open point **with the user** (the interactive step)
For every divergence (step 1) and every new language concept (step 2), present it and **ask** —
use `AskUserQuestion`. Don't batch a whole node into one vague question; ask per real decision,
with a recommended default first. Use this shape:

> **`callable.decorators`/annotations.** In **Java** these are flat strings
> (`annotations: List[str]` + `modifiers`). In **Python** they are structured `PyDecorator`
> objects (name, qualified_name, positional/keyword args). TypeScript has decorators that carry
> arguments (`@Component({selector: '...'})`).
> *How do you want to model TS decorators?*
> 1. **Structured `TSDecorator` (recommended)** — like Python; preserves args so entrypoint
>    finders can read `@Get('/path')` later. Costs a richer model.
> 2. **Flat strings** — like Java; simplest, but throws away argument structure.
> 3. **Structured + raw fallback** — structured fields plus the raw source string.

Always include *why* each option exists and what it buys/costs, anchored in what the references
did. When the language adds something with no reference precedent (TS generics, Go receiver types,
Rust lifetimes), present the rubric choice — new node kind | typed field | `tags` (Part II of
`references/canonical-schema.md`, § Language expansion) — the same way and ask. Record each answer
(a one-line note per decision) in `.claude/SCHEMA_DECISIONS.md` in the generated repo (under
`.claude/`, not the repo root) so the choices are auditable and a later session can see why the
schema looks the way it does.

### 4. Define & co-evolve
Encode the user's decisions into **both** the analyzer-side type *and* the SDK `<L>` Pydantic
model, in the same change. Keys snake_case; new fields optional-with-default; the spine untouched;
identity-only edges. (Field catalog and the node-kind rubric: `references/canonical-schema.md`
Part II.) The *how* of encoding these into the analyzer is the backend skill's job; this loop
only fixes *what* they are.

## Keep this distinct from the framework/domain axis
A *different* question — "how do this language's frameworks expose entrypoints, routes, ORM/CRUD?"
— also matters to CLDK, but it is answered by **entrypoint/CRUD detection** (the
`codeanalyzer-extension-builder` skill and the backend recipe's later steps), **not** by these
structural nodes. Don't let domain concerns reshape `module`/`type`/`callable`/`call`.

## Why anchor on *multiple* references
Java alone biases you toward a class-centric, annotation-flat, rich-edge world. Python shows a
different valid shape (module functions, structured decorators, identity-only edges). Reading both
keeps you from mistaking *Java's* choices for *the* contract, and gives the user a real spectrum of
precedent at each divergence. As more languages mature, add them to the anchor set.

## Output of this loop
A complete schema for the language — analyzer types + SDK `<L>` models — with every divergence
decided by the user and noted in `.claude/SCHEMA_DECISIONS.md`. This is a *design artifact*: it
feeds the spec and the epic's schema-design child issue. No files are walked and no analyzer code
is written yet — that is the `codeanalyzer-backend` rung, entered only after the gate is satisfied.
