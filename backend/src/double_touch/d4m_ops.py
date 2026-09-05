"""D4M expression evaluation backed by D4M.jl via juliacall.

Expressions are Julia source strings evaluated in a namespace that contains the
named input Assoc objects.  Julia D4M syntax applies:

    A + B                         — union/sum
    A & B                         — intersection
    A[sw"prefix", :]              — StartsWith selector (rows)
    A["lo".."hi", :]              — Between selector
    A[has"substr", :]             — Contains selector
    A[ew"suffix", :]              — EndsWith selector
    A[r"regex", :]                — Regex selector
    A["r1,r2,", :]                — D4M comma-delimited string

MATLAB-style call syntax is translated before evaluation so expressions from
the DoubleNaught frontend also work:

    A(:)            → A
    A("r","c")      → A["r","c"]

Thread safety: juliacall is not thread-safe; a module-level lock serializes
every eval() call.
"""

from __future__ import annotations

import os
import re
import threading
from typing import Any

from .models import AssocArray

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Absolute path to the D4M.jl source tree.  Override via env var for portability.
_D4M_JL_PATH = os.environ.get(
    "D4M_JL_PATH",
    os.path.expanduser("~/d4m.Wk/D4M.jl"),
)

# ---------------------------------------------------------------------------
# Julia / D4M.jl initialisation  (lazy, once per process)
# ---------------------------------------------------------------------------

_lock = threading.Lock()      # serialises all Julia eval calls (not thread-safe)
_init_lock = threading.Lock() # protects one-time initialisation of the Julia runtime
_jl: Any = None               # juliacall.Main once initialised
_d4m_ready = False
_AssocType: Any = None        # Julia Assoc type, cached after D4M loads


def _julia():
    """Return the juliacall Main module, loading D4M.jl on first call.

    Thread-safe: the init lock ensures only one thread boots the Julia runtime
    (cold start ~2 min) while _lock serialises every subsequent eval call.
    """
    global _jl, _d4m_ready, _AssocType
    if _d4m_ready:
        return _jl
    with _init_lock:
        # Double-checked locking: re-test inside the lock.
        if _d4m_ready:
            return _jl
        if _jl is None:
            from juliacall import Main as jl  # noqa: PLC0415  (lazy import)
            _jl = jl
        _jl.seval(
            f'if !in("{_D4M_JL_PATH}", LOAD_PATH)\n'
            f'    pushfirst!(LOAD_PATH, "{_D4M_JL_PATH}")\n'
            f'end'
        )
        _jl.seval("using D4M")
        _AssocType = _jl.seval("Assoc")
        _d4m_ready = True
    return _jl


def warm() -> None:
    """Block until Julia + D4M.jl are fully loaded. Call once at server start."""
    _julia()


# ---------------------------------------------------------------------------
# Wire-format ↔ Julia Assoc conversion
# ---------------------------------------------------------------------------

def _julia_str(s: str) -> str:
    """Escape *s* for embedding as a Julia double-quoted string literal."""
    return (s
        .replace('\\', '\\\\')
        .replace('"',  '\\"')
        .replace('\n', '\\n')
        .replace('\r', '\\r')
        .replace('\t', '\\t')
        .replace('$',  '\\$')
        .replace('\0', '\\0'))


def _to_julia_assoc(aa: AssocArray) -> Any:
    """Convert a wire AssocArray to a D4M.jl Assoc object.

    rows/cols use the D4M comma-delimited string form (they are short IDs with
    no commas).  vals are passed as a typed Julia array so that string values
    containing commas are not mis-parsed by D4M's StrUnique splitter.
    """
    jl = _julia()
    rows_str = ",".join(aa.rows) + ","
    cols_str = ",".join(aa.cols) + ","
    vals = list(aa.vals)
    if vals and isinstance(vals[0], (int, float)):
        # Float64 array avoids PyList dispatch issues.
        jl_vals = jl.seval(
            f"Float64[{', '.join(str(float(v)) for v in vals)}]"
        )
    else:
        # Build a Julia Vector{String} directly.  Using a comma-delimited
        # string would break on values that themselves contain commas (e.g.
        # full text passages from ChunkNode).
        escaped = ", ".join(f'"{_julia_str(str(v))}"' for v in vals)
        jl_vals = jl.seval(f"String[{escaped}]")
    return jl.Assoc(rows_str, cols_str, jl_vals)


def _from_julia_assoc(result: Any) -> AssocArray:
    """Convert a D4M.jl Assoc back to the wire AssocArray format."""
    jl = _julia()
    r, c, v = jl.find(result)
    rows = [str(x) for x in r]
    cols = [str(x) for x in c]
    vals: list = []
    for x in v:
        # juliacall wraps Julia Float64/Int as Python float/int
        if isinstance(x, (int, float)):
            vals.append(float(x))
        else:
            vals.append(str(x))
    return AssocArray(rows=rows, cols=cols, vals=vals)


# ---------------------------------------------------------------------------
# Expression pre-processing  (MATLAB-style → Julia)
# ---------------------------------------------------------------------------

def _preprocess(expression: str, input_names: set[str]) -> str:
    """Translate MATLAB-style call syntax to Julia bracket syntax.

    Only tokens that are known Assoc input names are rewritten.

    Transforms (in order):
      * ``A(:)``              →  ``A``
      * ``A("r",":")``        →  ``A["r",:]``   (string ":" → Julia Colon)
      * ``A("r","c")``        →  ``A["r","c"]``
    """
    def _colon_str_to_colon(args: str) -> str:
        """Replace the string literal ":" or ':' with a bare Julia : (Colon)."""
        args = re.sub(r'":\s*"', ':', args)
        args = re.sub(r"':\s*'", ':', args)
        return args

    for name in input_names:
        pat = re.escape(name)
        # A(:) → A
        expression = re.sub(rf'\b{pat}\(\s*:\s*\)', name, expression)
        # A("row", ":") → A["row", :]  (convert ":" string args to Julia Colon)
        def _replace_call(m: re.Match) -> str:
            return f'{name}[{_colon_str_to_colon(m.group(1))}]'
        expression = re.sub(rf'\b{pat}\(([^)]+)\)', _replace_call, expression)
    return expression


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def build_assoc(rows: list[str], cols: list[str], vals: list) -> AssocArray:
    """Construct a well-formed AA from parallel triples via D4M.jl's real
    ``Assoc`` constructor, rather than hand-assembling the wire triples.

    For callers (e.g. ``ast_extract.aa_from_table``) that flatten some other
    data shape into AA triples themselves: the flattening step is not AA
    algebra and doesn't need D4M.jl, but the resulting AA object should still
    be the one D4M.jl actually produces, not a from-scratch Python
    reimplementation of what an Assoc is.

    Callers remain responsible for ensuring ``(row, col)`` pairs are unique
    before calling this — D4M.jl's ``Assoc`` constructor combines duplicate
    entries via its own default operator, which callers assembling e.g. a
    multi-column definition index will not generally want applied silently.
    """
    return _from_julia_assoc(_to_julia_assoc(AssocArray(rows=rows, cols=cols, vals=vals)))


def eval_script(
    inputs: dict[str, AssocArray],
    script: str,
    output_symbol: str,
) -> AssocArray:
    """Evaluate a multi-line Julia D4M script and return the named result AA.

    *script* is evaluated as a Julia block; the final result is extracted by
    evaluating *output_symbol* in the same scope.  This allows scripts like::

        C = A + B
        D = C[sw"chunk:", :]

    where ``output_symbol="D"`` returns the filtered AA.

    Raises:
        RuntimeError:  Julia or D4M.jl could not be loaded, or the script or
                       any assignment into Julia raised (message pre-rendered
                       from the original juliacall.JuliaError — see the note
                       on the `except` clause below).
        TypeError:     Named symbol does not hold an Assoc.
    """
    jl = _julia()
    # Preprocess MATLAB-style call syntax using all input variable names.
    processed = _preprocess(script, set(inputs.keys()))
    with _lock:
        assigned: list[str] = []
        try:
            for name, aa in inputs.items():
                setattr(jl.Main, name, _to_julia_assoc(aa))
                assigned.append(name)
            jl.seval(processed)
            result = jl.seval(output_symbol)
        except Exception as e:
            # Render the message now, in this same call frame, before the
            # `finally` block below makes another Julia call. Empirically,
            # str()-ing a juliacall.JuliaError AFTER an intervening Julia
            # call (even an unrelated one, like the variable-cleanup below)
            # hangs when this whole call chain is driven through an anyio
            # blocking portal (e.g. FastAPI route -> TestClient/uvicorn) —
            # str() on a fresh JuliaError works fine on its own, and so does
            # a Julia call after it, but stringifying a *stale* one doesn't.
            # Likely a world-age/backtrace-invalidation issue in
            # juliacall/PythonCall.jl, not something to work around inside
            # Julia. Converting to a plain str immediately, before anything
            # else touches Julia, sidesteps it entirely.
            raise RuntimeError(str(e)) from None
        finally:
            for name in assigned:
                jl.seval(f"Main.eval(:(global {name} = nothing))")
    if not jl.isa(result, _AssocType):
        raise TypeError(
            f"Output symbol '{output_symbol}' must hold an Assoc, "
            f"got {type(result).__name__}"
        )
    return _from_julia_assoc(result)


def eval_expression(inputs: dict[str, AssocArray], expression: str) -> AssocArray:
    """Evaluate *expression* as Julia D4M code over the named input AAs.

    Args:
        inputs:     Mapping of variable name → AssocArray.
        expression: A Julia D4M expression, e.g.::

                        A + B
                        A[sw"chunk:", :]
                        A["r1,r2,", :]

    Returns:
        The result of the expression as a wire AssocArray.

    Raises:
        RuntimeError:  Julia or D4M.jl could not be loaded, or the expression
                       or any assignment into Julia raised (message
                       pre-rendered from the original juliacall.JuliaError —
                       see `eval_script`'s matching `except` clause for why).
        TypeError:     Expression result was not an Assoc.
    """
    jl = _julia()
    expression = _preprocess(expression, set(inputs.keys()))
    with _lock:
        assigned: list[str] = []
        try:
            for name, aa in inputs.items():
                setattr(jl.Main, name, _to_julia_assoc(aa))
                assigned.append(name)
            result = jl.seval(expression)
        except Exception as e:
            raise RuntimeError(str(e)) from None
        finally:
            for name in assigned:
                jl.seval(f"Main.eval(:(global {name} = nothing))")
    if not jl.isa(result, _AssocType):
        raise TypeError(
            f"Expression must return an Assoc, got {type(result).__name__}"
        )
    return _from_julia_assoc(result)
