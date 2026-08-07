"""Load File node execution logic.

Loads files (.parquet, .arrow, .json, .csv, .txt) and auto-detects Associative Arrays
based on schema metadata tags or column patterns.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Optional

import pyarrow as pa
import pyarrow.parquet as pq

from .models import AssocArray
from .save_file import load_parquet_with_auto_detect, _table_to_aa


def load_file(file_path: str, schema_mode: str = "auto") -> tuple[Optional[AssocArray], Optional[dict]]:
    """Load a file and optionally auto-detect Associative Array format.

    Args:
        file_path: Absolute or relative path to the file.
        schema_mode: "auto" (default), "force_aa", or "raw_table".
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

    suffix = path.suffix.lower()

    if suffix == ".parquet":
        return _load_parquet(path, schema_mode)
    elif suffix == ".arrow":
        return _load_arrow(path, schema_mode)
    elif suffix == ".json":
        return _load_json(path, schema_mode)
    elif suffix == ".csv":
        return _load_csv(path, schema_mode)
    elif suffix == ".txt":
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
    """Load a CSV file as a table."""
    import csv

    with open(path, "r") as f:
        reader = csv.DictReader(f)
        rows = list(reader)

    table_dict = {"rows": rows}

    # CSV doesn't naturally fit AA format; force_aa would fail.
    if schema_mode == "force_aa":
        raise ValueError("force_aa mode: CSV files cannot be reconstructed as AA")

    return None, table_dict
