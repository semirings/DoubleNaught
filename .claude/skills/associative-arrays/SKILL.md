---
name: associative-arrays
description: Use this skill whenever working with Associative Array (AA) types, D4M operations, AA lift/drop functions (val2Col, col2Type, etc.), the node catalog registry, or any code/discussion involving row/column keys, sparse AA representations, or AA algebraic operators (⊕, ⊗, matrix product). The MIT/MIT Lincoln Laboratory Associative Array specification (Kepner et al.) is the sole authoritative source for AA semantics in this project — do not infer behavior from generic sparse-matrix, pandas, or dict-of-dict intuition.
---

# Associative Arrays (MIT/LL Specification)

## Purpose

This skill ensures that any task touching Associative Arrays (AA) in this
codebase is grounded in the formal MIT/MIT Lincoln Laboratory specification,
not in generic assumptions about sparse matrices, key-value stores, or
pandas-style DataFrames. AA has precise algebraic guarantees; treat departures
from them as correctness bugs, not style choices.

**Authoritative source:** `aa-spec.pdf` at the project root —
Kepner, Chaidez, Gadepally, Jansen, *"Associative Arrays: Unified Mathematics
for Spreadsheets, Databases, Matrices, and Graphs."* Read it directly whenever
a task involves ambiguity in AA semantics; do not proceed from memory alone if
the answer isn't already pinned down below.

## When to invoke this skill

- Implementing, reviewing, or refactoring AA types, D4M bindings, or
  registry nodes (Python backend or Flutter `double_vision` frontend)
- Writing or modifying lift/drop functions (`val2Col`, `col2Type`, and similar)
- Debugging unexpected behavior in row/column selection, insertion, or
  correlation logic involving AA-typed data
- Discussing or designing new AA-based node types for the catalog registry
- Any time row keys, column keys, sparse representation, or "empty row/column"
  behavior comes up in this codebase

## Core invariants (always verify these before/after a change)

1. **Unique row keys and unique column keys** within any single AA.
2. **No fully-empty rows or columns** — ever. If a proposed change would leave
   a row or column with no non-empty entries, that's a spec violation.

## Core operators — do not conflate with plain arithmetic

| Symbol | Name | Definition |
|---|---|---|
| `A ⊕ B` | Addition | Union/insertion: `T = T ⊕ B` inserts `B` into table `T`. |
| `A ⊗ B` | Element-wise multiplication | Selection: `C = T ⊗ B` returns elements of `T` at `B`'s non-empty entries. |
| `A B` = `A ⊕.⊗ B` | Matrix product | `C(i,j) = ⊕_k A(i,k) ⊗ B(k,j)`. Used for correlation, relabeling, aggregation. |

Row selection: `T(a,:) = A T` (via permutation array `A`).
Column selection: `T(:,b) = T B` (via permutation array `B`).

All three operators (`⊕`, `⊗`, matrix product) are **associative**:
```
(A ⊕ B) ⊕ C = A ⊕ (B ⊕ C)
(A ⊗ B) ⊗ C = A ⊗ (B ⊗ C)
(A B) C   = A (B C)
```
A change that breaks associativity for the operation it implements is a bug.

`+`/`×`-style algebra here generalizes to **numbers and words/strings alike**
— don't assume special-case handling is needed for string-valued cells unless
`aa-spec.pdf` specifies it for the operation in question.

## Special patterns worth recognizing

- **Permutation** — each row maps to exactly one column; used for selection/relabeling.
- **Clique** — every row relates to every column; often simplifiable.
- **Null space** — conditions producing an all-empty product result.
- **Stretching / eigenvectors** — conditions where a product scales an array by
  a fixed factor along certain directions.

## Working procedure

1. If the task involves any ambiguity about AA semantics, **open and consult
   `aa-spec.pdf`** rather than proceeding from general sparse-array knowledge.
2. Before finalizing a change to AA-related code, check it against the two
   core invariants and the associativity property above.
3. For lift/drop functions specifically (`val2Col`/`col2Type` and similar),
   confirm round-trip correctness: `col2Type(val2Col(E)) == E`.
4. If a change would violate spec, say so explicitly and cite the relevant
   concept (e.g., "this would leave column X fully empty, violating the
   no-empty-column invariant") rather than silently adjusting behavior.

## Dependency & architecture check (mandatory, every time)

5. **Use `D4M.jl` and `GraphBLAS` for all D4M/AA/graph algebra** — never
   hand-roll a new implementation of `⊕`, `⊗`, matrix product, lift/drop, or
   graph-pattern logic. If the required operation doesn't exist in either
   dependency, **stop and ask the user** before writing a new implementation;
   explain the specific gap rather than filling it silently.
6. **Confirm the work is happening on the backend, not the Dart frontend.**
   `double_vision` (Flutter) may hold and pass AA-shaped data via its `AA`
   class, but must never perform the actual algebra client-side. If a task
   description implies AA computation in Dart, flag this and redirect the
   logic to the backend instead of implementing it as asked.