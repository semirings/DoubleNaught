# D4M.jl vs D4M.py: name map (draft inventory)

Sources: D4M.jl `export` list (`src/D4M.jl`) and Accla/D4M.py at commit e1ded1b (`D4M/assoc.py`, `util.py`, `db.py`).
Matched by name and docstring only. **Nothing here was run.** Treat "same op" as a hypothesis until a shared fixture passes in both.
Proposed canonical name = the D4M.jl name (it is what the bridge and OntologyAnvil already use).

## 1. Same operation, different spelling

| Canonical (Jl) | Py | Note |
|---|---|---|
| `getrow` `getcol` `getval` `getadj` | `get_row` `get_col` `get_val` `get_adj` | Py are methods |
| `putRow` `putCol` `putVal` `putAdj` | `set_row` `set_col` `set_val` `set_adj` | Check mutating vs returns-new in each |
| `sqIn` `sqOut` | `sqin` `sqout` | case only |
| `CatKeyMul` `CatValMul` | `catkeymul` `catvalmul` | case only |
| `CatStr` | `catstr` (util) | |
| `col2type` | `col_to_type` | |
| `val2col` | `val2col` | already identical |
| `str2num` | `str_to_num` | |
| `ReadCSV` `WriteCSV` | `readcsv` `writecsv` | |
| `transpose` / `adjoint` | `transpose(copy=True)` | |
| `StartsWith` `Contains` | `startswith` `contains` (util, return index functions) | Different mechanism: Jl selector objects, Py closures |
| `right_overwrite` `left_overwrite` | `last` `first` (util) | Guess from names; verify |
| `OutDegree` `InDegree` | none found | |
| `logical` `norow` `nocol` `diag` `combine` `condense` `find` `sum` | same names | Verify argument order and defaults |

## 2. Same spelling, different meaning (the dangerous ones)

| Expression | Jl | Py |
|---|---|---|
| `A * B` | **matrix multiply** | **element-wise** product |
| matrix multiply | `A * B` | `A @ B` |
| element-wise multiply | `A .* B` (broadcast) | `A * B` or `multiply` |
| `A & B`, `A \| B` | not found | element-wise logical AND / OR |

## 3. Only in D4M.jl

`EndsWith`, `Between`, `..`, `@sw_str @ew_str @has_str`, `@lift @drop`, `SplitStr`, `NumStr`, `convertvals`,
`saveAA` `loadAA`, **`saveParquet` `loadParquet`**, `toTable` `toDataFrame` `toTriplet`, `printTriple`,
`bounded` `strictbounded` `adjbfs`, `OutDegree` `InDegree`, `health`.

## 4. Only in D4M.py

`dropzeros`, `deepcondense`, `nnz`, `size`, `to_dict` `to_dict2`, `triples`, `spy`, `min` `max`, `divide`,
comparison operators (`== != < > <= >=` return Assocs), `assoc_equal`, `is_empty_assoc`, `read_mat` `save_mat`,
`sorted_union` `sorted_intersect`, and the whole `db` module (Accumulo/SQL: `DbServer`, `DbTable`, `put`, ...).

## 5. Gaps that matter to Speakeasy

- **Persistence is the biggest mismatch:** Py has no Parquet/AA load-save; Jl has no `.mat` and no DB layer.
- Selectors differ in kind. Speakeasy should emit a neutral selector spec (`startsWith "x"`, `between a b`) that each backend turns into its own form.
- Jl is 1-based and Py is 0-based; confirm that no index ever crosses the language boundary.

## 6. Suggested order

1. Add the `*` / `@` rule to a shared spec first; it silently produces wrong numbers.
2. Registry file: canonical id, args, meaning, jl name, py name, Speakeasy phrase.
3. Shared fixtures (triples in, op, triples out) run by both libraries.
4. Py alias layer in your own wrapper, not in the Accla source.
5. Decide per operation in sections 3 and 4: implement in the other language, or mark backend-specific.
