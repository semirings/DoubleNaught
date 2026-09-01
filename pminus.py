#! /usr/bin/env python3

import sys
import numpy as np

# Ensure your path includes the workspace if needed
sys.path.append("/Users/gcr/d4m.Wk")
from D4M import Assoc

# Create sample associative arrays
row = np.array(["r1", "r2", "r1"])
col = np.array(["docstring", "file_path", "kind"])
val = np.array([1.0, 1.0, 1.0])

A = Assoc(row, col, val)

# Test 1: Mathematical subtraction (A - rem)
# In D4M, subtracting an extracted subset zeros out matching coordinates rather than dropping columns
rem = A[:, ["file_path"]]
diff_result = A - rem

print("Python Subtraction Non-zeros:", diff_result.nnz)

# Test 2: Structural column removal (True filtering)
# To actually remove columns, filter the column keys directly
keep_cols = [c for c in A.col if c not in ["file_path"]]
filtered_result = A[:, keep_cols]
print("Python Filtered Columns:", filtered_result.col)