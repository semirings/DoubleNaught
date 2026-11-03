"""Ontology Guardrail validation backed by OntologyAnvil.jl, via the same
shared juliacall bridge d4m_ops.py uses for D4M.jl.

OntologyAnvil.jl is not Pkg-registered. Like D4M.jl itself (see
d4m_juliacall_bridge.bridge's own ``_D4M_JL_PATH``), it is loaded by pushing
its package directory onto Julia's ``LOAD_PATH`` and calling
``using OntologyAnvil`` -- this module adds exactly that one LOAD_PATH entry
and nothing else about Julia's environment. ``bridge.julia()`` is relied on
to have D4M.jl already loaded (every other route into this backend that
touches an AA already goes through it at startup); this module only ever
runs after that.

Data source boundary matches OntologyAnvil.jl's own: this module reads the
ontology's compiled ``*.parquet`` (never the LinkML ``*.yaml`` source) and
hands the triples straight to D4M.jl's real ``Assoc`` constructor, the same
way ``d4m_ops._to_julia_assoc`` does for every other AA this backend builds.
"""

from __future__ import annotations

import os
import threading
from typing import Any

import d4m_juliacall_bridge as bridge

_ONTOLOGY_ANVIL_JL_PATH = os.environ.get(
    "ONTOLOGY_ANVIL_JL_PATH",
    os.path.expanduser("~/populi.Wk/OntologyAnvil.jl"),
)

_ONTOLOGY_PARQUET_PATH = os.environ.get(
    "ONTOLOGY_PARQUET_PATH",
    os.path.expanduser(
        "~/populi.Wk/DoubleNaught/storage/ontologies/prompt_governance_ontology.parquet"
    ),
)

_init_lock = threading.Lock()
_ontology_anvil_ready = False

# One compiled engine per ontology parquet path, so a validate call doesn't
# re-walk the triples and rebuild the sparse matrices on every request. The
# ontology changes by deliberate re-authoring (see the LinkML source), not at
# runtime, so there is no invalidation path here -- a backend restart is how
# a schema change takes effect, same as it is for D4M.jl itself.
_ENGINE_CACHE: dict[str, Any] = {}


def _ensure_loaded() -> Any:
    """Return the juliacall Main module with OntologyAnvil available.

    Thread-safe like bridge._julia(); callers must still hold ``bridge.LOCK``
    around any Julia call they make with the returned handle.
    """
    global _ontology_anvil_ready
    jl = bridge.julia()  # ensures D4M.jl itself is already loaded
    if _ontology_anvil_ready:
        return jl
    with _init_lock:
        if _ontology_anvil_ready:
            return jl
        with bridge.LOCK:
            jl.seval(
                f'if !in("{_ONTOLOGY_ANVIL_JL_PATH}", LOAD_PATH)\n'
                f'    pushfirst!(LOAD_PATH, "{_ONTOLOGY_ANVIL_JL_PATH}")\n'
                f'end'
            )
            jl.seval("using OntologyAnvil")
        _ontology_anvil_ready = True
    return jl


def _load_engine(parquet_path: str) -> Any:
    """Build (and cache) an OntologyAnvilEngine from the ontology parquet at
    *parquet_path*."""
    cached = _ENGINE_CACHE.get(parquet_path)
    if cached is not None:
        return cached

    import pyarrow.parquet as pq  # local import: only this function needs it

    table = pq.read_table(parquet_path)
    data = table.to_pydict()
    rows, cols, vals = data["rowKey"], data["colKey"], data["val"]

    jl = _ensure_loaded()
    with bridge.LOCK:
        ontology = bridge.to_julia_assoc(rows, cols, vals)
        engine = jl.OntologyAnvil.build_engine(ontology)
    _ENGINE_CACHE[parquet_path] = engine
    return engine


def validate_entity(
    asserted_classes: list[str],
    asserted_slots: list[str],
    parquet_path: str | None = None,
) -> tuple[bool, list[str]]:
    """Run ``OntologyAnvil.validate_entity`` for one candidate entity.

    Returns ``(is_valid, violations)`` -- violations is always a list, empty
    on success.

    Raises:
        RuntimeError: Julia/OntologyAnvil could not be loaded, or the call
                      itself raised. Stringified immediately inside the same
                      ``with bridge.LOCK`` block, before anything else
                      touches Julia -- see d4m_ops.eval_expression's matching
                      ``except`` clause for why a stale JuliaError can hang
                      if rendered after an intervening Julia call.
    """
    path = parquet_path or _ONTOLOGY_PARQUET_PATH
    jl = _ensure_loaded()
    engine = _load_engine(path)
    with bridge.LOCK:
        try:
            is_valid, violations = jl.OntologyAnvil.validate_entity(
                engine, asserted_classes, asserted_slots
            )
        except Exception as e:
            raise RuntimeError(str(e)) from None
    return bool(is_valid), [str(v) for v in violations]
