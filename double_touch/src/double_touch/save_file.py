"""Save File node execution logic.

Persists incoming data (AA, text, or image) to the backend storage/out/ directory
in Parquet (for AA) or native format (text/image).
"""

from __future__ import annotations

import base64
import json
from pathlib import Path
from typing import Optional

import pyarrow as pa
import pyarrow.parquet as pq
from .models import AssocArray


def storage_out_dir() -> Path:
    """Return the backend storage/out directory, creating if needed."""
    base = Path(__file__).parent.parent.parent.parent / "storage" / "out"
    base.mkdir(parents=True, exist_ok=True)
    return base


def save_aa_parquet(aa: AssocArray, filename: str) -> Path:
    """Save an AssocArray to Parquet format under storage/out/.

    Embeds metadata tag `dn_type: associative_array` into the Parquet schema
    so downstream readers can auto-detect the payload format.

    Args:
        aa: The associative array to save.
        filename: Output filename (without extension; .parquet added).

    Returns:
        Path to the written file.
    """
    filename_clean = filename.removesuffix(".parquet")
    out_path = storage_out_dir() / f"{filename_clean}.parquet"

    # Convert AA triplet form to PyArrow table:
    # rows, cols, vals are parallel lists in sparse triple format.
    table = pa.table({
        "rowKey": pa.array(aa.rows, type=pa.string()),
        "colKey": pa.array(aa.cols, type=pa.string()),
        "val": pa.array(aa.vals, type=pa.string()),  # all stringified
    })

    # Embed metadata tag for auto-detection on load.
    metadata = table.schema.metadata or {}
    metadata[b"dn_type"] = b"associative_array"
    table = table.replace_schema_metadata(metadata)

    pq.write_table(table, str(out_path), compression="zstd")
    return out_path


def save_aa_csv(aa: AssocArray, filename: str) -> Path:
    """Save an AssocArray to CSV format (wide form) under storage/out/.

    Args:
        aa: The associative array to save.
        filename: Output filename (without extension; .csv added).

    Returns:
        Path to the written file.
    """
    filename_clean = filename.removesuffix(".csv")
    out_path = storage_out_dir() / f"{filename_clean}.csv"

    # Build column set and row set.
    col_set = set(aa.cols)
    columns = sorted(col_set)
    row_set = set(aa.rows)
    rows = sorted(row_set)

    # Build a cell lookup: (row, col) -> value.
    cell_map = {}
    for i, (r, c, v) in enumerate(zip(aa.rows, aa.cols, aa.vals)):
        cell_map[(r, c)] = str(v)

    # Write CSV: header + data rows.
    lines = [",".join(columns)]
    for row in rows:
        values = [cell_map.get((row, col), "") for col in columns]
        # Simple CSV escaping for fields with comma/quote/newline.
        escaped = []
        for v in values:
            if "," in v or '"' in v or "\n" in v:
                escaped.append(f'"{v.replace(chr(34), chr(34)+chr(34))}"')
            else:
                escaped.append(v)
        lines.append(",".join(escaped))

    out_path.write_text("\n".join(lines) + "\n")
    return out_path


def save_aa_json(aa: AssocArray, filename: str) -> Path:
    """Save an AssocArray to JSON format (triplet) under storage/out/.

    Args:
        aa: The associative array to save.
        filename: Output filename (without extension; .json added).

    Returns:
        Path to the written file.
    """
    filename_clean = filename.removesuffix(".json")
    out_path = storage_out_dir() / f"{filename_clean}.json"

    data = {
        "rows": aa.rows,
        "cols": aa.cols,
        "vals": aa.vals,
    }
    out_path.write_text(json.dumps(data, indent=2))
    return out_path


#: Column that marks an AA as pre-formatted JSONL lines.
JSONL_COLUMN = "json_line"


def aa_has_jsonl(aa: AssocArray) -> bool:
    """Whether *aa* carries a ``json_line`` column, i.e. is ready to write as JSONL."""
    return JSONL_COLUMN in aa.cols


def save_aa_jsonl(aa: AssocArray, filename: str) -> Path:
    """Save an AA's ``json_line`` column as a JSONL file under storage/out/.

    One line per entry, joined by newline with a trailing newline — the shape every
    fine-tuning loader expects.

    Order is **appearance order** in the triples, not sorted row keys. A JSONL file
    is a sequence, and sorting keys lexically would interleave ``line:10`` before
    ``line:2``. (:func:`save_aa_csv` sorts, which is fine for a matrix and wrong
    here.)

    Args:
        aa: An AA carrying a ``json_line`` column, e.g. from JsonlFormatterNode.
        filename: Output filename (without extension; .jsonl added).

    Returns:
        Path to the written file.

    Raises:
        ValueError: The AA has no ``json_line`` column, or a line contains a literal
            newline — which would silently split one example into two records.
    """
    filename_clean = filename.removesuffix(".jsonl")
    out_path = storage_out_dir() / f"{filename_clean}.jsonl"

    lines = [
        str(val)
        for row, col, val in zip(aa.rows, aa.cols, aa.vals)
        if col == JSONL_COLUMN
    ]
    if not lines:
        raise ValueError(
            "cannot write JSONL: the AA has no 'json_line' column "
            f"(columns present: {sorted(set(aa.cols))})"
        )

    for index, line in enumerate(lines):
        if "\n" in line or "\r" in line:
            raise ValueError(
                f"cannot write JSONL: entry {index} contains a literal newline, "
                "which would split one example across two records"
            )

    out_path.write_text("".join(f"{line}\n" for line in lines))
    return out_path


def save_text(text: str, filename: str) -> Path:
    """Save plain text under storage/out/.

    Args:
        text: The text content to save.
        filename: Output filename (without extension; .txt added).

    Returns:
        Path to the written file.
    """
    filename_clean = filename.removesuffix(".txt")
    out_path = storage_out_dir() / f"{filename_clean}.txt"

    out_path.write_text(text)
    return out_path


def save_image(image_base64: str, filename: str, format_hint: str) -> Path:
    """Save image bytes (base64-encoded) under storage/out/.

    Args:
        image_base64: Base64-encoded image bytes.
        filename: Output filename (without extension).
        format_hint: "png" or "jpg" to determine extension.

    Returns:
        Path to the written file.
    """
    ext = ".png" if format_hint == "png" else ".jpg"
    filename_clean = filename.removesuffix(ext)
    out_path = storage_out_dir() / f"{filename_clean}{ext}"

    image_bytes = base64.b64decode(image_base64)
    out_path.write_bytes(image_bytes)
    return out_path


def load_parquet_with_auto_detect(file_path: str) -> tuple[Optional[AssocArray], Optional[pa.Table]]:
    """Load a Parquet file and auto-detect if it's an AA based on schema metadata.

    Checks for `dn_type: associative_array` metadata tag. If present, reconstructs
    the AssocArray. Otherwise checks for triplet columns (rowKey, colKey, val) and
    falls back to returning the raw table.

    Args:
        file_path: Path to the Parquet file.

    Returns:
        Tuple of (AssocArray if detected, raw PyArrow table).
        One or both may be None depending on the file format.
    """
    table = pq.read_table(file_path)
    metadata = table.schema.metadata or {}

    # Check for AA metadata tag.
    if metadata.get(b"dn_type") == b"associative_array":
        aa = _table_to_aa(table)
        return aa, table

    # Fallback: check for triplet column names.
    col_names = table.column_names
    if set(col_names) >= {"rowKey", "colKey", "val"}:
        aa = _table_to_aa(table)
        return aa, table

    # Not an AA — return raw table.
    return None, table


def _table_to_aa(table: pa.Table) -> AssocArray:
    """Convert a PyArrow table (triplet form) back to an AssocArray.

    Args:
        table: PyArrow table with columns rowKey, colKey, val.

    Returns:
        Reconstructed AssocArray.

    Raises:
        KeyError: If required columns are missing.
    """
    rows = table.column("rowKey").to_pylist()
    cols = table.column("colKey").to_pylist()
    vals = table.column("val").to_pylist()

    return AssocArray(rows=rows, cols=cols, vals=vals)


def execute_save(
    aa: Optional[AssocArray] = None,
    text: Optional[str] = None,
    image_base64: Optional[str] = None,
    filename: str = "export",
    format: str = "parquet",
) -> tuple[Path, int]:
    """Execute the Save File node logic.

    Routes to the appropriate saver based on data and format.

    Args:
        aa: AssocArray payload (if present).
        text: Text payload (if present).
        image_base64: Base64-encoded image bytes (if present).
        filename: Output filename (without extension).
        format: Output format ("parquet", "csv", "json", "jsonl", "txt", "png",
            "jpg").

    Returns:
        Tuple of (output Path, bytes written).

    Raises:
        ValueError: If no data provided, the format does not match the payload, or
            a JSONL write was asked for without a ``json_line`` column.
    """
    if aa is not None:
        if format == "jsonl" or (aa_has_jsonl(aa) and filename.endswith(".jsonl")):
            # Pre-formatted training lines: write them as-is rather than as a
            # matrix. Triggered by an explicit format or by a .jsonl filename on an
            # AA that actually carries the column.
            out_path = save_aa_jsonl(aa, filename)
        elif format == "csv":
            out_path = save_aa_csv(aa, filename)
        elif format in ("json", "json5"):
            out_path = save_aa_json(aa, filename)
        else:  # Default to parquet for AA.
            out_path = save_aa_parquet(aa, filename)
    elif text is not None:
        out_path = save_text(text, filename)
    elif image_base64 is not None:
        out_path = save_image(image_base64, filename, format)
    else:
        raise ValueError("No data provided (aa, text, or image_base64)")

    return out_path, out_path.stat().st_size
