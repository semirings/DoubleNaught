"""AA serializer — Arrow IPC and Parquet I/O for D4M Associative Arrays.

Schema
------
Row-key triplet layout: each non-zero cell of an Assoc is one record.

    rowKey   : string — the D4M row key  (e.g. ``"chunk:00001"``)
    colKey   : string — the D4M col key  (e.g. ``"text"``, ``"score"``)
    val      : string — cell value; always stored as a string for schema
               stability across numeric, boolean, and text columns
    metadata : string — optional per-triple annotation (empty string = absent)

This is the canonical format for general-purpose AA persistence.  For the
ML-pipeline binary-cache schema (chunkId, text, scores, …) see
:mod:`aa_binary_normalizer`.

Usage::

    from double_touch.aa_serializer import save_aa_arrow, load_aa_arrow
    from double_touch.aa_serializer import save_aa_parquet, load_aa_parquet

    aa = AssocArray(rows=["r1","r1"], cols=["text","score"], vals=["hello",0.9])
    path = save_aa_arrow(aa, "/tmp/corpus.aa.arrow")
    tbl  = load_aa_arrow(path)

    path2 = save_aa_parquet(aa, "/tmp/corpus.aa.parquet")
    tbl2  = load_aa_parquet(path2)
"""

from __future__ import annotations

from pathlib import Path
from typing import Union

import pyarrow as pa
import pyarrow.ipc as ipc
import pyarrow.parquet as pq

from .models import AssocArray

# ── Canonical AA triplet schema ──────────────────────────────────────────────
#
# Matches the Julia D4M.jl saveAA / saveParquet triplet form so files round-trip
# between the Python pipeline and the Julia D4M workers without schema translation.

AA_TRIPLET_SCHEMA = pa.schema([
    pa.field("rowKey",   pa.string()),
    pa.field("colKey",   pa.string()),
    pa.field("val",      pa.string()),
    pa.field("metadata", pa.string()),
])

# Type accepted by the public save functions.
AaSource = Union[AssocArray, pa.Table, list[dict]]


# ── Internal coercion ─────────────────────────────────────────────────────────


def _to_table(source: AaSource) -> pa.Table:
    """Coerce *source* to a :data:`AA_TRIPLET_SCHEMA`-compliant ``pa.Table``."""
    if isinstance(source, pa.Table):
        return _cast_to_schema(source)
    if isinstance(source, AssocArray):
        return _assoc_array_to_table(source)
    return _records_to_table(source)


def _assoc_array_to_table(aa: AssocArray) -> pa.Table:
    n = len(aa.rows)
    return pa.table(
        {
            "rowKey":   pa.array(aa.rows,                      type=pa.string()),
            "colKey":   pa.array(aa.cols,                      type=pa.string()),
            "val":      pa.array([str(v) for v in aa.vals],    type=pa.string()),
            "metadata": pa.array([""] * n,                     type=pa.string()),
        },
        schema=AA_TRIPLET_SCHEMA,
    )


def _records_to_table(records: list[dict]) -> pa.Table:
    """Accept dicts with ``rowKey``/``colKey``/``val``/``metadata`` keys.

    Also handles legacy ``row``/``col`` key names for backward compatibility.
    """
    row_keys = [str(r.get("rowKey",   r.get("row",      ""))) for r in records]
    col_keys = [str(r.get("colKey",   r.get("col",      ""))) for r in records]
    vals     = [str(r.get("val",                        "")) for r in records]
    metadata = [str(r.get("metadata",                   "")) for r in records]
    return pa.table(
        {"rowKey": row_keys, "colKey": col_keys, "val": vals, "metadata": metadata},
        schema=AA_TRIPLET_SCHEMA,
    )


def _cast_to_schema(table: pa.Table) -> pa.Table:
    """Cast an incoming Arrow table to :data:`AA_TRIPLET_SCHEMA`.

    Adds an empty ``metadata`` column when absent (e.g. files from Julia's
    triplet writer which omits the metadata field).
    """
    cols: dict[str, pa.Array] = {}
    for field in AA_TRIPLET_SCHEMA:
        if field.name in table.schema.names:
            cols[field.name] = table.column(field.name).cast(field.type)
        elif field.name == "metadata":
            cols["metadata"] = pa.array([""] * len(table), type=pa.string())
        else:
            raise ValueError(
                f"Required AA triplet column '{field.name}' missing from Arrow table. "
                f"Present columns: {table.schema.names}"
            )
    return pa.table(cols, schema=AA_TRIPLET_SCHEMA)


# ── Public API ────────────────────────────────────────────────────────────────


def save_aa_arrow(
    source: AaSource,
    path: Union[str, Path],
) -> Path:
    """Write *source* to an Arrow IPC (Feather v2) file at *path*.

    Uses :data:`AA_TRIPLET_SCHEMA` — ``rowKey``, ``colKey``, ``val``,
    ``metadata``.  Parent directories are created if absent.

    Parameters
    ----------
    source:
        An :class:`~models.AssocArray`, a ``pa.Table``, or a ``list[dict]``
        with ``rowKey``/``colKey``/``val`` keys.
    path:
        Destination file path.  Conventionally ``*.aa.arrow`` for intermediate
        pipeline data, ``*.arrow`` for persisted stores.

    Returns
    -------
    Path
        The resolved output path.
    """
    out = Path(path)
    out.parent.mkdir(parents=True, exist_ok=True)
    table = _to_table(source)
    with ipc.new_file(str(out), table.schema) as writer:
        writer.write_table(table)
    return out


def load_aa_arrow(
    path: Union[str, Path],
    *,
    memory_map: bool = True,
) -> pa.Table:
    """Load an Arrow IPC file, returning a ``pa.Table``.

    Parameters
    ----------
    path:
        Path to the ``.arrow`` file.
    memory_map:
        When ``True`` (default), the file is memory-mapped — zero Python-heap
        copy, suitable for large tables.  Set to ``False`` to read fully into
        RAM.

    Returns
    -------
    pa.Table
        A table with :data:`AA_TRIPLET_SCHEMA` columns (when the file was
        written by :func:`save_aa_arrow`).
    """
    src = str(Path(path))
    if memory_map:
        mmap   = pa.memory_map(src, "r")
        reader = ipc.open_file(mmap)
        return reader.read_all()
    with ipc.open_file(src) as reader:
        return reader.read_all()


def save_aa_parquet(
    source: AaSource,
    path: Union[str, Path],
    *,
    compression: str = "zstd",
) -> Path:
    """Write *source* to a Parquet file at *path*.

    Uses :data:`AA_TRIPLET_SCHEMA` and ZSTD compression by default.  Parent
    directories are created if absent.

    Parameters
    ----------
    source:
        An :class:`~models.AssocArray`, a ``pa.Table``, or a ``list[dict]``.
    path:
        Destination file path.  Conventionally ``*.aa.parquet`` for archive
        pipeline outputs.
    compression:
        Parquet compression codec (``"zstd"``, ``"snappy"``, ``"gzip"``,
        or ``"none"``).

    Returns
    -------
    Path
        The resolved output path.
    """
    out = Path(path)
    out.parent.mkdir(parents=True, exist_ok=True)
    table = _to_table(source)
    pq.write_table(table, str(out), compression=compression)
    return out


def load_aa_parquet(path: Union[str, Path]) -> pa.Table:
    """Load a Parquet file, returning a ``pa.Table``.

    Parameters
    ----------
    path:
        Path to the ``.parquet`` file.

    Returns
    -------
    pa.Table
        A table with :data:`AA_TRIPLET_SCHEMA` columns (when the file was
        written by :func:`save_aa_parquet`).
    """
    return pq.read_table(str(Path(path)))


def table_to_assoc(table: pa.Table) -> AssocArray:
    """Convert a ``pa.Table`` (from :func:`load_aa_arrow` / :func:`load_aa_parquet`)
    back to an :class:`~models.AssocArray`.

    The ``metadata`` column is discarded; ``val`` strings are returned as-is
    (callers must re-cast numeric columns if needed).
    """
    return AssocArray(
        rows=table.column("rowKey").to_pylist(),
        cols=table.column("colKey").to_pylist(),
        vals=table.column("val").to_pylist(),
    )
