

---

### Section 1 — Pattern & Selector Sugar

#### 1a. String Literal Macros (concise one-liners, LLM-friendly)

Julia non-standard string literals use the `macro <name>_str(s)` convention. These are the densest, most copy-paste-safe form.

```julia
# sw"prefix" → StartsWith("prefix")
macro sw_str(s::String)
    :(StartsWith($s))
end

# ew"suffix" → EndsWith("suffix")   (new struct, see 1b)
macro ew_str(s::String)
    :(EndsWith($s))
end

# has"substr" → Contains("substr")  (maps to Regex internally)
macro has_str(s::String)
    :(Contains($s))
end

# btw"a:z"  → Between("a", "z")     (new struct, see 1b)
macro btw_str(s::String)
    parts = split(s, ":", limit=2)
    length(parts) == 2 || error("btw\"lo:hi\" requires exactly one ':'")
    :(Between($(parts[1]), $(parts[2])))
end
```

**Before / After:**

```julia
# Before
A[StartsWith("sensor_temp"), :]
A[r".*_temp$", :]           # Contains — round-trips through Regex dispatch

# After
A[sw"sensor_temp", :]
A[ew"_temp", :]
A[has"temp", :]
A[btw"sensor_a:sensor_z", :]
```

#### 1b. New Selector Structs (extend `getindex.jl`)

`StartsWith` already exists. Add the missing three with the same binary-search pattern:

```julia
struct EndsWith
    suffix::String
end

struct Contains
    substr::String
end

struct Between
    lo::String
    hi::String
end

# EndsWith: O(n) scan (no ordering shortcut for suffixes)
function _ew_helper(keys::AbstractVector, s::EndsWith)
    findall(k -> endswith(k, s.suffix), keys)
end

# Contains: O(n) scan — or delegate to Regex dispatch
function _has_helper(keys::AbstractVector, s::Contains)
    findall(k -> occursin(s.substr, k), keys)
end

# Between: O(log n) binary search — same guarantee as the existing D4M range string
function _btw_helper(keys::AbstractVector, s::Between)
    lo = searchsortedfirst(keys, s.lo)
    hi = searchsortedlast(keys, s.hi)
    lo:hi
end

# Wire into getindex dispatch (same PreviousTypes rolling-union pattern)
getindex(A::Assoc, i::EndsWith,  j) = getindex(A, _ew_helper(A.row, i),  j)
getindex(A::Assoc, i,  j::EndsWith)  = getindex(A, i, _ew_helper(A.col, j))
getindex(A::Assoc, i::Contains,  j) = getindex(A, _has_helper(A.row, i), j)
getindex(A::Assoc, i,  j::Contains) = getindex(A, i, _has_helper(A.col, j))
getindex(A::Assoc, i::Between,   j) = getindex(A, _btw_helper(A.row, i), j)
getindex(A::Assoc, i,  j::Between)  = getindex(A, i, _btw_helper(A.col, j))
```

#### 1c. Composable Selectors via `|` / `&`

For multi-pattern rows, overload `|` and `&` on a thin `SelectorUnion` / `SelectorIntersect` wrapper:

```julia
struct SelectorUnion;   a; b; end
struct SelectorIntersect; a; b; end

Base.:(|)(a::Union{StartsWith,EndsWith,Contains,Between,Regex},
           b::Union{StartsWith,EndsWith,Contains,Between,Regex}) = SelectorUnion(a, b)
Base.:(&)(a::Union{StartsWith,EndsWith,Contains,Between,Regex},
           b::Union{StartsWith,EndsWith,Contains,Between,Regex}) = SelectorIntersect(a, b)

function _resolve(keys, s::SelectorUnion)
    sort(union(_resolve(keys, s.a), _resolve(keys, s.b)))
end
function _resolve(keys, s::SelectorIntersect)
    intersect(_resolve(keys, s.a), _resolve(keys, s.b))
end
# dispatch for Union/Intersect same pattern as above
```

Usage:

```julia
A[sw"sensor_" | sw"actuator_", :]     # rows starting with either prefix
A[sw"sensor_" & btw"sensor_a:sensor_m", :]
```

---

### Section 2 — Unified Query Macro `@q`

**Macro Name & Signature:**

```julia
@q assoc rows=<selector> cols=<selector> [val=<condition>]
```

**Before / After:**

```julia
# Before — three separate decisions, easy to get arg order wrong
A[StartsWith("sensor_"), "temp,humidity,pressure,"]

# After — named dimensions, order-independent
@q A  rows=sw"sensor_"  cols="temp,humidity,pressure,"

# Multi-condition — before required nesting or intermediate variables
tmp = A[StartsWith("alice"), :]
result = tmp[:, r"^score_"]

# After
@q A  rows=sw"alice"  cols=r"^score_"

# With value filter — new capability, no clean current equivalent
@q A  rows=:  cols=sw"temp_"  val=(>(20.0))
```

**Implementation sketch:**

```julia
macro q(A_expr, kwargs...)
    row_sel = :(:)
    col_sel = :(:)
    val_pred = nothing

    for kw in kwargs
        kw isa Expr && kw.head == :(=) || error("@q: expected keyword=value, got $kw")
        k, v = kw.args
        if     k == :rows; row_sel  = v
        elseif k == :cols; col_sel  = v
        elseif k == :val;  val_pred = v
        else error("@q: unknown keyword $k (valid: rows, cols, val)")
        end
    end

    if isnothing(val_pred)
        :($(esc(A_expr))[$(esc(row_sel)), $(esc(col_sel))])
    else
        # val filter: slice first, then apply predicate
        tmp = gensym(:q_tmp)
        quote
            $tmp = $(esc(A_expr))[$(esc(row_sel)), $(esc(col_sel))]
            $tmp[$(esc(val_pred))($tmp), :]   # e.g. tmp[>(20.0)(tmp), :]
        end
    end
end
```

`macroexpand(@__MODULE__, :(@q A rows=sw"sensor_" cols=:))` yields exactly `A[StartsWith("sensor_"), :]` — no hidden state.

**Batch / pipeline variant `@qmap`:** applies a transform to each matching group.

```julia
@qmap A  group_by=sw"sensor_"  apply=(X -> X * X')
# expands to a comprehension over sorted unique prefixes
```

---

### Section 3 — Semiring & Algebraic Sugar

D4M matrix multiply `*` currently hardwires `(+, *)` (standard semiring). The future GraphBLAS backend parameterizes this, but the frontend needs clean syntax now.

#### 3a. Named semiring blocks

```julia
@semiring (⊕, ⊗) begin
    expr
end
```

```julia
# Before — no current clean way; requires explicit intermediate functions
function minplus_mul(A::Assoc, B::Assoc)
    At = logical(A); Bt = logical(B)
    # manually wire min/+ into sparse multiply...
end

# After
result = @semiring (min, +) A * B      # min-plus (tropical)
result = @semiring (max, min) A * B    # max-min (fuzzy)
result = @semiring (|, &)   A * B      # Boolean
```

**Implementation sketch (dispatch-based, not operator shadowing):**

```julia
struct Semiring{P,T}
    plus::P
    times::T
end

const MinPlus  = Semiring(min, +)
const MaxMin   = Semiring(max, min)
const Boolean  = Semiring(|, &)
const Standard = Semiring(+, *)

# Semiring-aware multiply dispatches on the semiring parameter
function sr_mul(sr::Semiring, A::Assoc, B::Assoc)
    At = !isa(A.val[1], Number) ? logical(A) : A
    Bt = !isa(B.val[1], Number) ? logical(B) : B
    ABintersect = sortedintersect(At.col, Bt.row)
    AA = At.A[:, searchsortedmapping(ABintersect, At.col)]
    BB = Bt.A[searchsortedmapping(ABintersect, Bt.row), :]
    # apply semiring element-wise:  sr.times for products, sr.plus for accumulation
    ABA = _sr_spgemm(sr, AA, BB)
    condense(Assoc(At.row, Bt.col, [1.0], ABA))
end

macro semiring(sr_expr, expr)
    # walk expr, replace every `A * B` with `sr_mul($sr_expr, A, B)`
    transformed = _replace_mul_ast(esc(expr), esc(sr_expr))
    transformed
end

function _replace_mul_ast(ex, sr)
    ex isa Expr || return ex
    if ex.head == :call && ex.args[1] == :*
        return :(sr_mul($sr, $(ex.args[2:end]...)))
    end
    Expr(ex.head, [_replace_mul_ast(a, sr) for a in ex.args]...)
end
```

#### 3b. Convenience aliases

```julia
const @minplus = (expr) -> @semiring MinPlus expr
const @maxmin  = (expr) -> @semiring MaxMin  expr

# Usage
D = @minplus A * B * C    # min-plus chain — shortest-path semiring
```

#### 3c. `@broadcast_sr` — element-wise with semiring plus

```julia
@broadcast_sr (max, +) A .+ B
# replaces Base.broadcast with a custom semiring accumulator
```

---

### Section 4 — AST / LLM-Friendly Design Guidelines

The macros above are designed around four constraints that make LLM code generation reliable:

**1. Keyword-argument style (`rows=`, `cols=`) — no positional ambiguity.**

Positional arguments require the LLM to remember argument order, which hallucinations frequently get wrong. Named keywords eliminate this class of error. `macroexpand` validates that every keyword mapped to the intended slot.

```julia
@q A rows=sw"sensor_" cols=:     # ✓ unambiguous regardless of order
A[StartsWith("sensor_"), :]      # ✗ LLM can swap row/col
```

**2. Single-level nesting — no macro-within-macro expansion chains.**

The selectors (`sw"..."`, `btw"..."`, etc.) are pure constructor expressions — no macro invocation inside another macro call. This means `macroexpand` terminates in one step and returns readable code:

```julia
macroexpand(@__MODULE__, :(@q A rows=sw"sensor_" cols=:))
# → A[StartsWith("sensor_"), :]
# One level. No recursive expansion needed.
```

**3. Explicit failure modes — no silent fallbacks.**

Each macro has a guard clause that `error()`s with a message identifying the call site. An LLM-generated expression that misspells a keyword (`row=` instead of `rows=`) gets an error pointing directly at the macro argument, not a mysterious `MethodError` three frames deep.

**4. Selector types are inspectable values, not compile-time-only constructs.**

`StartsWith("sensor_")`, `Between("a","z")`, `Contains("foo")` are plain structs — they can be stored in variables, printed, compared, and passed as arguments. An LLM can generate a selector, assign it to a variable, and reuse it:

```julia
my_rows = sw"sensor_"        # just a value: StartsWith("sensor_")
@q A rows=my_rows cols=:     # works — macroexpand sees the variable, not the literal
```

This also means a RAG pipeline can cache and compose selectors at the application layer before ever invoking the macro, reducing hallucination surface area to the selector-construction step only.

---

### Recommended Rollout Order

|Phase|What to add|Why first|
|---|---|---|
|1|`EndsWith`, `Contains`, `Between` structs + `getindex` dispatch|Unblocks all string literal macros|
|2|`sw_str`, `ew_str`, `has_str`, `btw_str` macros|Zero breaking changes, pure sugar|
|3|`@q` macro|Depends on selector structs being stable|
|4|`SelectorUnion` / `SelectorIntersect`|Makes composite row selectors possible|
|5|`Semiring` struct + `@semiring`|Needed for GraphBLAS backend wiring|