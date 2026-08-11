"""Load File node execution logic.

Loads files and auto-detects Associative Arrays based on schema metadata tags or
column patterns.

Two families of input:

* **Structured** — .parquet, .arrow, .json, .csv — reconstructed as an AA where
  the shape allows (see ``_load_csv`` for the CSV conventions).
* **Plain text** — .txt, .jl, .md — returned verbatim as ``{"text": ...}`` with no
  AA, for a downstream node (a prompt, an LLM dispatch) to read. The set matches
  the Load File node's own ``allowedExtensions``, so anything the picker accepts
  is something this loader can answer.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Optional

import pyarrow as pa
import pyarrow.parquet as pq

from .models import AssocArray
from .save_file import load_parquet_with_auto_detect, _table_to_aa

# The Flutter node names its schema modes with a Dart enum, so it sends the
# camelCase spelling on the wire. Accept both rather than silently falling
# through to "auto" for every explicit mode the user picks.
_SCHEMA_MODE_ALIASES = {"forceAa": "force_aa", "rawTable": "raw_table"}

# Extensions read as plain text. Kept in step with `allowedExtensions` in
# `double_vision/lib/widgets/nodes/implementations/load_file_node.dart`: the
# picker and the loader agreeing is what keeps a selectable file loadable.
TEXT_SUFFIXES = (".txt", ".jl", ".md")


def load_file(file_path: str, schema_mode: str = "auto") -> tuple[Optional[AssocArray], Optional[dict]]:
    """Load a file and optionally auto-detect Associative Array format.

    Args:
        file_path: Absolute or relative path to the file.
        schema_mode: "auto" (default), "force_aa", or "raw_table". Ignored for
                     plain-text inputs, which have no AA to detect.
                     - "auto": detect based on metadata or column names
                     - "force_aa": force reconstruction as AA even if not tagged
                     - "raw_table": return raw table/dict representation

    Returns:
        Tuple of (AssocArray if applicable, raw_representation).
        - raw_representation is a dict for JSON, a PyArrow table dict for Parquet/Arrow, etc.

    Raises:
        FileNotFoundError: If the file doesn't exist.
        ValueError: If the file format is unsupported or reconstruction fails.
    """
    path = Path(file_path)
    if not path.exists():
        raise FileNotFoundError(f"File not found: {file_path}")

    schema_mode = _SCHEMA_MODE_ALIASES.get(schema_mode, schema_mode)
    suffix = path.suffix.lower()

    if suffix == ".parquet":
        return _load_parquet(path, schema_mode)
    elif suffix == ".arrow":
        return _load_arrow(path, schema_mode)
    elif suffix == ".json":
        return _load_json(path, schema_mode)
    elif suffix == ".csv":
        return _load_csv(path, schema_mode)
    elif suffix in TEXT_SUFFIXES:
        # Source and prose files are content, not tables: hand back the text and
        # let the graph decide what to do with it. No AA — a Julia file has no
        # rows and columns, and inventing some would only obscure it.
        return None, {"text": path.read_text()}
    else:
        raise ValueError(f"Unsupported file format: {suffix}")


def _load_parquet(path: Path, schema_mode: str) -> tuple[Optional[AssocArray], Optional[dict]]:
    """Load a Parquet file."""
    aa, table = load_parquet_with_auto_detect(str(path))

    if schema_mode == "force_aa" and aa is None:
        try:
            aa = _table_to_aa(table)
        except (KeyError, ValueError):
            raise ValueError(
                "force_aa mode: table does not have rowKey/colKey/val columns"
            )

    if schema_mode == "raw_table" or aa is None:
        # Return table as dict for JSON serialization.
        return aa, table.to_pydict()

    return aa, table.to_pydict()


def _load_arrow(path: Path, schema_mode: str) -> tuple[Optional[AssocArray], Optional[dict]]:
    """Load an Arrow IPC file."""
    table = pa.ipc.open_file(str(path)).read_all()

    # Check for AA metadata.
    metadata = table.schema.metadata or {}
    aa = None
    if metadata.get(b"dn_type") == b"associative_array" or schema_mode == "force_aa":
        try:
            aa = _table_to_aa(table)
        except (KeyError, ValueError):
            if schema_mode == "force_aa":
                raise ValueError(
                    "force_aa mode: table does not have rowKey/colKey/val columns"
                )

    if schema_mode == "raw_table" or aa is None:
        return aa, table.to_pydict()

    return aa, table.to_pydict()


def _load_json(path: Path, schema_mode: str) -> tuple[Optional[AssocArray], Optional[dict]]:
    """Load a JSON file."""
    data = json.loads(path.read_text())

    # Check if it's AA triplet form: {rows, cols, vals}.
    aa = None
    if isinstance(data, dict) and set(data.keys()) >= {"rows", "cols", "vals"}:
        try:
            aa = AssocArray(
                rows=data["rows"],
                cols=data["cols"],
                vals=data["vals"],
            )
        except (TypeError, ValueError):
            if schema_mode == "force_aa":
                raise ValueError("force_aa mode: JSON does not have valid AA structure")

    if schema_mode == "raw_table" or aa is None:
        return aa, data

    return aa, data


def _load_csv(path: Path, schema_mode: str) -> tuple[Optional[AssocArray], Optional[dict]]:
    """Load a CSV file, reconstructing an AA unless "raw_table" is requested.

    Two layouts are recognised, matching D4M.jl's ``ReadCSV``:

    * **triple form** — headers include ``rowKey,colKey,val`` (what the Save File
      node writes for Parquet/JSON): each line is one ``(row, col, val)`` triple.
    * **table form** — the first column holds the row keys (its header is a
      label and is discarded), the remaining headers are the column keys, and
      each non-empty cell becomes one triple.

    Empty cells produce no triple, so a sparse sheet stays sparse. Values stay
    strings — D4M keeps CSV values textual (convert downstream with ``str2num``)
    so a ZIP of ``"00000"`` does not become ``0``.

    The raw ``{"rows": [{col: val}, …]}`` view is always returned alongside, so
    the node's ``contents`` port carries the file as it was written.
    """
    import csv

    with open(path, "r", newline="") as f:
        reader = csv.DictReader(f)
        fieldnames = list(reader.fieldnames or [])
        records = [dict(r) for r in reader]

    table_dict = {"rows": records}

    if schema_mode == "raw_table":
        return None, table_dict

    rows: list[str] = []
    cols: list[str] = []
    vals: list[str] = []

    if set(fieldnames) >= {"rowKey", "colKey", "val"}:
        for rec in records:
            row, col, val = rec.get("rowKey"), rec.get("colKey"), rec.get("val")
            if not row or not col or val in (None, ""):
                continue
            rows.append(str(row))
            cols.append(str(col))
            vals.append(str(val))
    elif len(fieldnames) >= 2:
        key_field = fieldnames[0]
        for i, rec in enumerate(records):
            # A blank key cell would collapse every such line onto one row key,
            # so fall back to the line number.
            row = rec.get(key_field) or str(i)
            for col in fieldnames[1:]:
                val = rec.get(col)
                if val in (None, ""):
                    continue
                rows.append(str(row))
                cols.append(col)
                vals.append(str(val))

    if not cols:
        if schema_mode == "force_aa":
            raise ValueError(
                "force_aa mode: CSV has no row-key column and value columns to "
                "reconstruct as AA"
            )
        return None, table_dict

    return AssocArray(rows=rows, cols=cols, vals=vals), table_dict
