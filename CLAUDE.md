# DoubleNaught (DN) — Project Context for Claude Code

## Associative Arrays: Authoritative Specification

This project implements **Associative Arrays (AA)** exactly as formally defined
in the MIT / MIT Lincoln Laboratory specification:

> Kepner, J., Chaidez, J., Gadepally, V., Jansen, H. *"Associative Arrays: Unified
> Mathematics for Spreadsheets, Databases, Matrices, and Graphs."* MIT Mathematics
> Department / MIT CSAIL / MIT Lincoln Laboratory / MIT BeaverWorks Center.

**The full paper is at `aa-spec.pdf` in the project root.** It is the single
source of truth for AA semantics in this codebase — in the Python backend, the
Flutter (`double_vision`) frontend, the D4M/Julia layer, and the node catalog
registry (`aa_binary_normalizer.py` and related nodes).

> **Rule for Claude Code:** When implementing, reviewing, or modifying any code
> that touches associative arrays, D4M operations, or AA-based node types, read
> `aa-spec.pdf` first if there is any ambiguity. Do **not** infer AA semantics
> from generic sparse-matrix, pandas, or dictionary-of-dictionaries intuition —
> AA has specific algebraic guarantees that generic sparse structures do not.

---

## Core AA Definition (do not violate these invariants)

An associative array `A` is a two-dimensional structure where every element is
addressable as a triple `(row, column, value)`, with two defining properties:

1. **Unique keys** — every row label (row key) and every column label (column
   key) in `A` is unique.
2. **No fully-empty rows or columns** — `A` never contains a row or column that
   is entirely empty. Insertion, selection, and deletion are performed via AA
   addition, multiplication, and products, which preserve this property
   automatically.

Any implementation (registry entry, node, lift/drop function, etc.) that
produces a row or column of all-empty values, or that allows duplicate row/col
keys to silently collide, is **not** a valid associative array per spec —
flag this rather than "fixing" it by dropping the property quietly.

---

## The Three Core Operations

Use `⊕` and `⊗` in comments/docs/discussion to distinguish these from ordinary
arithmetic `+` and `*` — they are **not** the same operation, even when the
underlying values are numbers.

| Operation | Notation | Meaning |
|---|---|---|
| **Addition** | `C = A ⊕ B` | Equivalent to database table **insertion**: `T = T ⊕ B`. Union-like combination of two AAs. |
| **Element-wise multiplication** | `C = A ⊗ B` | Equivalent to database table **selection**: `C = T ⊗ B` returns the elements of `T` at the non-zero/non-empty entries of `B`. |
| **Matrix product** | `C = A B` = `A ⊕.⊗ B` | Combines both: `C(i,j) = ⊕_k A(i,k) ⊗ B(k,j)`. Used for correlation, renaming row/col labels, and aggregation into groups. |

**Row/column selection as a product**, using a permutation array (see below):
- `T(a,:) = A T` — row selection, where `a` are the columns of permutation array `A`.
- `T(:,b) = T B` — column selection, where `b` are the rows of permutation array `B`.

Sub-array extraction (via ranges or key sets) must carry along only the row/col
keys of the **non-empty** rows and columns selected — this is a required
consequence of invariant #2 above, and both element-wise and matrix-product
forms of selection must agree (duality between selection and product).

---

## Algebraic Guarantees (these must hold — treat violations as bugs)

AA addition, element-wise multiplication, and matrix product are all
**associative**:

```
(A ⊕ B) ⊕ C = A ⊕ (B ⊕ C)
(A ⊗ B) ⊗ C = A ⊗ (B ⊗ C)
(A B) C   = A (B C)
```

This is what permits reordering/interchanging processing steps with full
confidence the result is unchanged — it's the whole point of using AA instead
of ad hoc tabular code. If a proposed change (e.g., a new lift/drop function,
a new registry node) would break associativity for the operation it implements,
that is a spec violation, not a stylistic choice.

Also note: the abstract-algebra extension of `+`/`×` in this spec applies to
**numbers and words/strings alike** — AA operations are not restricted to
numeric semirings. Don't assume string-valued cells need special-casing outside
the normal `⊕`/`⊗` definitions unless the spec section you're working from says so.

---

## Special Array Patterns (recognize these, don't reinvent them)

- **Permutation** — each row corresponds to exactly one column (graph: each
  vertex on one side connects to exactly one vertex on the other). Used for
  row/column selection and relabeling (see product-based selection above).
- **Clique** — every row has a relationship with every column (graph: fully
  connected bipartite). Recognizing this pattern can simplify or eliminate a
  processing step.
- **Null space** — conditions under which an AA product yields an all-empty
  result; useful for recognizing when a step can be eliminated.
- **Stretching / eigenvectors** — conditions under which a product scales an
  array by a fixed amount along certain directions; useful for decomposing a
  complex step into simpler repeated operations.

If you notice one of these patterns emerging in registry data or node
relationships, call it out by name — it often means a processing step can be
simplified.

---

## Dependency & Architecture Rules (MANDATORY)

**D4M.jl and GraphBLAS are the required implementations for all D4M/AA algebra.**
This project depends on `D4M.jl` and `GraphBLAS` specifically so that AA
addition (`⊕`), element-wise multiplication (`⊗`), matrix product (`⊕.⊗`),
lift/drop transforms, and graph-pattern operations (permutation, clique, etc.)
are implemented once, correctly, and consistently — not reinvented per call site.

- **Always use `D4M.jl`** for any AA algebraic operation on the backend:
  addition, element-wise multiplication, matrix product, row/column selection,
  correlation, lift/drop (`val2Col`/`col2Type`-style transforms), and any
  operation with a direct analog in `aa-spec.pdf`.
- **Always use `GraphBLAS`** for graph-algorithm primitives that operate on the
  sparse/adjacency-matrix view of an AA (e.g., traversal, pattern detection
  such as permutation/clique, or other graph-native operations) rather than
  hand-rolling graph logic on top of raw arrays.
- **Never silently implement new D4M/AA/graph logic from scratch.** If a task
  seems to require an operation that isn't available in `D4M.jl` or
  `GraphBLAS`, **stop and ask the user before writing a new implementation.**
  Explain specifically what's missing and why existing dependencies don't
  cover it — don't assume a gap and fill it unprompted. A hand-written
  reimplementation of AA algebra is very likely to violate the invariants and
  associativity guarantees above, even if it looks correct for a test case.
- **All D4M/AA manipulation happens on the backend (BE), never in the Dart
  frontend.** The Flutter (`double_vision`) frontend must not perform AA
  algebra (`⊕`, `⊗`, matrix product, lift/drop, correlation, etc.) itself.
- **Dart's `AA` class is allowed, but only as a data-carrying type.** It's fine
  for the frontend to hold, display, serialize/deserialize, and pass around
  associative-array-shaped data using the Dart `AA` class — but any actual
  algebraic computation on that data must be delegated to the backend
  (D4M.jl/GraphBLAS) and the result returned to the frontend, not computed
  client-side.

If you're ever unsure whether something belongs in `D4M.jl`/`GraphBLAS` on the
backend versus the Dart `AA` class on the frontend, default to backend and ask
before proceeding.

---

## Practical Guidance for This Codebase

- **`val2Col` / `col2Type`** (and similar lift/drop functions): these implement
  representation conversions between a "typed" AA (values of mixed type per
  column) and a "binary" AA (one column per distinct field|value pair, entries
  restricted to presence/absence). Any change to these must preserve the
  unique-key and no-empty-row/column invariants on both sides of the transform,
  and must be reversible for round-tripping (`col2Type(val2Col(E)) == E`).
- **Node catalog registry** (Python backend + Flutter `double_vision` frontend):
  when cleaning up, deprecating, or adding builder entries, verify any AA-typed
  node still respects the two core invariants and doesn't silently change
  `⊕`/`⊗` semantics for existing callers.
- When unsure whether a change is spec-correct, **say so explicitly** and quote
  or reference the relevant section of `aa-spec.pdf` rather than guessing from
  general sparse-array conventions.