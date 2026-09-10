"""D4M expression evaluation backed by D4M.jl via the shared juliacall bridge.

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

The actual connect-once/lock/convert plumbing lives in ``d4m_juliacall_bridge``
(shared with SegForge's backend) — this module adds only what's specific to
DoubleNaught: the ``AssocArray`` wire type and the D4M-script evaluation
routes (``eval_script``/``eval_expression``), which SegForge has no need for.
"""

from __future__ import annotations

import re
from typing import Any

import d4m_juliacall_bridge as bridge

from .models import AssocArray

# Re-exported for callers/tests that reach into this module directly
# (e.g. conftest.py's D4M-availability probe imports `warm` from here).
warm = bridge.warm


def _to_julia_assoc(aa: AssocArray) -> Any:
    """Convert a wire AssocArray to a D4M.jl Assoc object. Caller must hold the bridge lock."""
    return bridge.to_julia_assoc(aa.rows, aa.cols, aa.vals)


def _from_julia_assoc(result: Any) -> AssocArray:
    """Convert a D4M.jl Assoc back to the wire AssocArray format. Caller must hold the bridge lock."""
    rows, cols, vals = bridge.from_julia_assoc(result)
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
    rows, cols, vals = bridge.build_triples(rows, cols, vals)
    return AssocArray(rows=rows, cols=cols, vals=vals)


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
    jl = bridge.julia()
    # Preprocess MATLAB-style call syntax using all input variable names.
    processed = _preprocess(script, set(inputs.keys()))
    with bridge.LOCK:
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
    if not jl.isa(result, bridge.assoc_type()):
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
    jl = bridge.julia()
    expression = _preprocess(expression, set(inputs.keys()))
    with bridge.LOCK:
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
    if not jl.isa(result, bridge.assoc_type()):
        raise TypeError(
            f"Expression must return an Assoc, got {type(result).__name__}"
        )
    return _from_julia_assoc(result)
