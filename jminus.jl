#! /usr/bin/env julia

using D4M
using SparseArrays  # nnz(A::Assoc) is a method D4M.jl adds to SparseArrays.nnz,
                     # but D4M.jl doesn't re-export the name `nnz` itself

# Create sample associative arrays matching the structure
row = ["r1", "r2", "r1"]
col = ["docstring", "file_path", "kind"]
val = [1.0, 1.0, 1.0]

A = Assoc(row, col, val)

# Test 1: Mathematical subtraction
rem = A[:, ["file_path"]]
diff_result = A - rem
println("Julia Subtraction Non-zeros: ", nnz(diff_result))

# Test 2: Structural column removal (True filtering)
keep_cols = setdiff(A.col, ["file_path"])
filtered_result = A[:, keep_cols]
println("Julia Filtered Columns: ", filtered_result.col)