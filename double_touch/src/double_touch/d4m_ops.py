"""D4M expression evaluation for the D4MNode backend route.

Converts between the DoubleNaught wire format (AssocArray — parallel
rows/cols/vals lists) and the D4M Assoc object, then evaluates a
user-supplied expression string in a namespace keyed by the input names.
"""

from __future__ import annotations

import re
from typing import TYPE_CHECKING

try:
    from D4M import Assoc
    _D4M_AVAILABLE = True
except ImportError:  # pragma: no cover
    _D4M_AVAILABLE = False

from .models import AssocArray

if TYPE_CHECKING:
    from D4M import Assoc  # type: ignore[assignment]


def assoc_from_aa(aa: AssocArray) -> "Assoc":
    """Convert a wire AssocArray to a D4M Assoc (using the shared rcvs.json contract)."""
    from D4M import Assoc as _Assoc
    return _Assoc.from_json({"rows": aa.rows, "cols": aa.cols, "vals": aa.vals})


def aa_from_assoc(result: "Assoc") -> AssocArray:
    """Convert a D4M Assoc result back to the wire AssocArray format."""
    data = result.to_json()
    return AssocArray(rows=data["rows"], cols=data["cols"], vals=data["vals"])


def _preprocess(expression: str, input_names: set[str]) -> str:
    """Translate MATLAB-style D4M call syntax to Python bracket syntax.

    Only rewrites tokens that are known Assoc input names so that utility
    function calls like ``startswith('prefix:')`` are left untouched.

    Transforms applied (in order):
      * ``A(:)``        →  ``A``          (MATLAB all-elements identity)
      * ``A("r","c")``  →  ``A["r","c"]`` (call → subscript for Assoc lookup)
    """
    for name in input_names:
        pat = re.escape(name)
        # A(:) → A  (MATLAB all-elements)
        expression = re.sub(rf'\b{pat}\(\s*:\s*\)', name, expression)
        # A[:]  → A  (Python single-colon slice = all)
        expression = re.sub(rf'\b{pat}\[\s*:\s*\]', name, expression)
        # A[:,:]  → A[":", ":"]  (Python double-colon slice = all rows, all cols)
        expression = re.sub(rf'\b{pat}\[\s*:\s*,\s*:\s*\]', rf'{name}[":", ":"]', expression)
        # A' * B → A.transpose() @ B  (MATLAB prime-multiply = matrix multiply)
        expression = re.sub(rf"\b{pat}'\s*\*", f'{name}.transpose() @', expression)
        # A' (remaining) → A.transpose()
        expression = re.sub(rf"\b{pat}'", f'{name}.transpose()', expression)
        # A("row", "col") → A["row", "col"]  (call → subscript)
        expression = re.sub(rf'\b{pat}\(([^)]+)\)', rf'{name}[\1]', expression)
    return expression


def eval_expression(inputs: dict[str, AssocArray], expression: str) -> AssocArray:
    """Evaluate *expression* in a namespace containing the named input AAs.

    Args:
        inputs:     Mapping of variable-name → AssocArray, e.g. {"A": ..., "B": ...}.
        expression: A D4M expression string, e.g.::

                        A + B
                        A[startswith('chunk:'), ':'] >= 0.75
                        A & B

            Uses Python D4M bracket syntax for selection — ``A[rows, cols]`` —
            not MATLAB/Dart call syntax.  ``startswith`` from ``D4M.util`` is
            pre-loaded in the namespace.

    Returns:
        The result of the expression as a wire AssocArray.

    Raises:
        RuntimeError:  D4M is not installed in this environment.
        TypeError:     Expression result was not an Assoc.
        Any exception the expression itself raises (SyntaxError, etc.).
    """
    if not _D4M_AVAILABLE:
        raise RuntimeError(
            "D4M is not installed. "
            "Run: pip install /path/to/D4M.py  (see the d4m.Wk/D4M.py repo)"
        )
    from D4M import Assoc as _Assoc
    from D4M.util import startswith
    from D4M.assoc import (
        val2col, col_to_type, transpose,
        hadamard, nnz, sqin, sqout,
        combine, assoc_min, assoc_max,
    )
    namespace: dict = {name: assoc_from_aa(aa) for name, aa in inputs.items()}
    namespace.update({
        "startswith": startswith,
        "Assoc": _Assoc,
        # D4M module-level functions available without import in expressions.
        "val2col": val2col,
        "col_to_type": col_to_type,
        "transpose": transpose,
        "hadamard": hadamard,
        "nnz": nnz,
        "sqin": sqin,
        "sqout": sqout,
        "combine": combine,
        "assoc_min": assoc_min,
        "assoc_max": assoc_max,
    })
    expression = _preprocess(expression, set(inputs.keys()))
    result = eval(expression, {"__builtins__": {}}, namespace)
    if not isinstance(result, _Assoc):
        raise TypeError(
            f"Expression must return an Assoc, got {type(result).__name__}"
        )
    return aa_from_assoc(result)
