
### Target: `/Users/gcr/d4m.Wk/D4M.jl`

---

## 1. Executive Summary

D4M.jl is a direct port of a MATLAB/Python associative array library into Julia syntax, but it has not yet been adapted to Julia's performance model. The codebase compiles and produces correct results, but nearly every layer — the struct definition, string operations, sparse matrix construction, and indexing — contains patterns that defeat the Julia JIT compiler. The most severe issue is the `Assoc` struct's use of abstract union-typed fields (`Array{Union{AbstractString,Number}}`), which forces every element access to be a heap allocation with a runtime type tag check. This alone makes all operations on `Assoc` dramatically slower than equivalent Julia code with concrete types.

Secondary bottlenecks compound this: `plus`/`minus` mutate `SparseMatrixCSC` incrementally (triggering O(N²) re-sorting on each assignment), `deepCondense` delegates trivial index lookups to `pmap` (distributed parallel overhead for a serial task), and `CatStr` creates two full intermediate string arrays for a simple zip-concatenation. There is also a correctness bug in `plus` where `B.val` is never checked for string type. The codebase is best understood as a working prototype rather than a performance-ready engine.

---

## 2. Critical Bottlenecks (Top Priority)

### Bottleneck 1 — Abstract union-typed struct fields (`Assoc.jl`, lines 21–27)

```julia
struct Assoc
    row::UnionArray          # = Array{Union{AbstractString,Number}}
    col::UnionArray
    val::UnionArray
    A::SparseOrTranspose     # = Union{AbstractSparseMatrix, Adjoint, Transpose}
end
```

Every field is typed with an abstract union. Julia cannot infer the concrete element type of `row`, `col`, or `val` at compile time. Accessing any element (`A.row[i]`) boxes the value, allocates a heap object, and requires a runtime tag check. The `SparseOrTranspose` union on `A` means all sparse arithmetic also dispatches dynamically. This is the root cause of the majority of performance overhead — it propagates through every function that takes an `Assoc`.

**Fix prerequisite:** Parameterize the struct: `struct Assoc{K, V}` with `row::Vector{K}`, `col::Vector{K}`, `val::Vector{V}`, `A::SparseMatrixCSC{Float64, Int}`. Separate numeric and string-valued `Assoc` into concrete subtypes or type parameters.

---

### Bottleneck 2 — Incremental `SparseMatrixCSC` mutation in `plus`/`minus` (`operations.jl`, lines 72–82, 103–113)

```julia
ABA = spzeros(length(ABrow), length(ABcol))
ABA[Arow, Acol] += At.A   # O(N²) CSC re-sort on every assignment
ABA[Brow, Bcol] += Bt.A
```

`SparseMatrixCSC` stores columns in sorted order. Assigning to a block of an existing sparse matrix triggers index de-duplication and re-sorting of the affected columns on **each** assignment. This pattern is O(N²) in the number of nonzeros for any moderate matrix. The same pattern appears in `broadcast.jl` (`combinedims`, lines 85–101).

**Correct pattern:** Accumulate COO triples then call `sparse(I, J, V, nrows, ncols, +)` once at the end.

---

### Bottleneck 3 — `pmap` for a trivially serial index lookup (`condense.jl`, line 24)

```julia
val = Array{Int64,1}(pmap(x -> searchsortedfirst(uniVal, x), val))
```

`pmap` is Julia's distributed parallel map — it serializes tasks, dispatches to worker processes, collects results, and deserializes. For `searchsortedfirst` (an O(log N) binary search), this overhead is **100–1000× larger than the computation itself** for any realistic array. This is the single most wasteful line in the codebase, called on every `getindex` of a string-valued `Assoc` through `deepCondense`.

**Fix:** Replace with `[searchsortedfirst(uniVal, x) for x in val]` or `searchsortedfirst.(Ref(uniVal), val)`.

---

### Bottleneck 4 — Double string split in `SplitStr` (`stringarrayhelpers.jl`, lines 5–14)

```julia
strsplit = [split(x, sep)[y] for x in s12, y in 1:2]
```

This 2D comprehension iterates `y ∈ {1, 2}` for each `x`, meaning `split(x, sep)` is called **twice per element** — once to get index 1 and once for index 2. Each `split` allocates a `Vector{SubString}`. For N elements that's 2N wasted allocations and 2N redundant `split` calls. `SplitStr` is called by `col2type` and `val2col` on every triple in the array.

**Fix:** `[split(x, sep) for x in s12]` once, then separate into two arrays.

---

### Bottleneck 5 — O(N×M) linear-scan indexing on a sorted array (`getindex.jl`, lines 34–36, 84–86)

```julia
# String array index — linear scan
getindex(A::Assoc, i::Array{Union{AbstractString,Number}}, ...) =
    getindex(A, findall(x -> x in i, A.row), ...)

# D4M-string index — linear scan after StrUnique
getindex(A::Assoc, i::AbstractString, ...) =
    getindex(A, findall(x -> in(x, StrUnique(convertrange(A.row,i))[1]), A.row), ...)
```

`A.row` is always sorted (guaranteed by the constructor). Yet `x in i` (for array `i`) is an O(length(i)) linear scan, and `in(x, unique_set)` for the D4M-string variant is O(M). For N rows and M selected keys this is O(N×M). Both should use binary search. `StartsWithHelper` already demonstrates the correct approach with `searchsortedfirst`/`searchsortedlast` — that pattern is not applied here.

---

## 3. Secondary Optimization Opportunities

### 3a. Dead allocation in `StrUnique` (`stringarrayhelpers.jl`, line 60)

```julia
backwardMapping = zeros(1, length(forwardMapping))  # allocated, never used
```

This allocates a matrix on every call to `StrUnique` (which is called by every string-key index and by `Assoc` construction) and immediately discards it. Remove it and return only `(uniqueSeq, forwardMapping)`.

### 3b. `CatStr` creates two intermediate string arrays (`stringarrayhelpers.jl`, line 26)

```julia
s12 = s1 .* [sep] .* s2
```

`s1 .* [sep]` allocates N new strings; the second `.*` allocates N more. Use `map((a,b) -> a * sep * b, s1, s2)` to produce the result in one pass with N total allocations. For the `val2col` path, `CatStr` is called on all 3,910+ triples.

### 3c. `@spawn` overhead in matrix multiply (`operations.jl`, lines 141–151)

```julia
Aref = @spawn searchsortedmapping(ABintersect, At.col)
Bref = @spawn searchsortedmapping(ABintersect, Bt.row)
```

`@spawn` creates OS-level tasks. `searchsortedmapping` is a linear O(N) merge walk. Task creation overhead dominates for any matrix where the intersect is under ~100,000 elements. The commented-out serial versions below are faster in practice. Use `Threads.@spawn` only if a profiler confirms parallelism benefit, or remove entirely.

### 3d. `condense` uses two full dense column/row sums (`condense.jl`, lines 6–7)

```julia
nonZeroCol = getindex.(findall(!iszero, sum(A.A, dims = 1)), 2)
nonZeroRow = getindex.(findall(!iszero, sum(A.A, dims = 2)), 1)
```

For a `SparseMatrixCSC`, non-empty columns can be found directly from the column pointer array without a full sum: `findall(k -> A.A.colptr[k+1] > A.A.colptr[k], 1:size(A.A,2))`. Non-empty rows require scanning `rowvals(A.A)` once. Both are O(nnz) vs. O(nrows×ncols) for the sum approach on dense regions.

### 3e. Correctness bug in `plus` (`operations.jl`, lines 58–63)

```julia
if(A.val != [1.0])
    At = logical(A)
end
if(A.val != [1.0])   # ← checks A again, should check B
    Bt = logical(B)
end
```

`B.val` is never checked. If `A` is numeric and `B` is string-valued, `Bt = B` (unchanged), and the addition proceeds with type mismatch. This is a logic error that will produce incorrect results for mixed-type addition.

### 3f. `getindex` catch-all creates dispatch ambiguity (`getindex.jl`, line 24)

```julia
getindex(A::Assoc, i::Any) = getindex(A, i, :)
```

`::Any` is a fallback that can shadow more-specific methods added later and trigger infinite dispatch chains. It also prevents the compiler from inferring return types for any expression of the form `A[expr]` when `expr`'s type isn't known statically.

### 3g. `getadj` copies every time (`accessor.jl`, line 7)

```julia
function getadj(A::Assoc)
    return copy(A.A)
end
```

Every caller that only reads the matrix (e.g., `sqIn`, `sqOut`, `CatKeyMul`, `CatValMul`) gets a full copy of the sparse matrix. For large matrices this is O(nnz) allocation for a read-only operation. Provide a `getadj_view` that returns `A.A` directly.

---

## 4. DSL Readiness Score: **2 / 10 — Not ready; struct redesign is a prerequisite**

A macro-based DSL needs a core engine that:

|Requirement|Current State|
|---|---|
|Type-stable return types|✗ All functions return type-unstable `Assoc` with abstract fields|
|Predictable dispatch|✗ `::Any` fallback + non-const `PreviousTypes` alias mutation|
|Zero global mutable state|✗ `PreviousTypes` mutates at module load time in `getindex.jl`|
|Composable, allocation-minimal primitives|✗ Every composed operation allocates 3–5 intermediate arrays|
|Correct base operations|✗ `plus` bug; `abs` attempts to set immutable struct field|
|Inspectable sparse backend|△ `SparseMatrixCSC` is inspectable but access pattern not exploited|

**Prerequisites before DSL development:**

1. **Redesign `Assoc` as a parameterized type** — `struct Assoc{K,V}` with concrete field types. This is a breaking API change but unavoidable.
2. **Fix `plus` correctness bug** (checks `A.val` twice).
3. **Replace incremental sparse mutation with COO accumulation** in `plus`, `minus`, and `broadcast`.
4. **Remove `pmap` from `deepCondense`** — replace with in-process map.
5. **Make type aliases `const`** (`const UnionArray = ...`) to allow the compiler to rely on them.

Once those five items are addressed, the algorithmic structure (sorted keys, COO→CSC, merge-join operations) is sound and a DSL layer can be built on top with confidence.