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
from .io_support import IOSupport
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


#: The unified column name for pre-formatted JSONL lines.
JSONL_COLUMN = "json_line"

#: The deprecated AA2JSONL node's column. Read, never written — an AA saved from an
#: older workflow still saves correctly.
JSONL_COLUMN_LEGACY = "jsonl_line"

#: Both spellings, unified first.
JSONL_COLUMNS = (JSONL_COLUMN, JSONL_COLUMN_LEGACY)


def jsonl_column_of(aa: AssocArray) -> Optional[str]:
    """Which JSONL column *aa* carries, preferring the unified name, else None."""
    for candidate in JSONL_COLUMNS:
        if candidate in aa.cols:
            return candidate
    return None


def aa_has_jsonl(aa: AssocArray) -> bool:
    """Whether *aa* is ready to write as JSONL (either column spelling)."""
    return jsonl_column_of(aa) is not None


def save_aa_jsonl(aa: AssocArray, filename: str) -> Path:
    """Save an AA's ``json_line`` column as a JSONL file under storage/out/.

    One line per entry, joined by newline with a trailing newline — the shape every
    fine-tuning loader expects.

    Order is **appearance order** in the triples, not sorted row keys. A JSONL file
    is a sequence, and sorting keys lexically would interleave ``line:10`` before
    ``line:2``. (:func:`save_aa_csv` sorts, which is fine for a matrix and wrong
    here.)

    Accepts the deprecated AA2JSONL node's ``jsonl_line`` spelling as a fallback, so
    an AA produced by an older workflow still saves.

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

    column = jsonl_column_of(aa)
    if column is None:
        raise ValueError(
            "cannot write JSONL: the AA has no 'json_line' column "
            f"(columns present: {sorted(set(aa.cols))})"
        )

    lines = [
        str(val)
        for row, col, val in zip(aa.rows, aa.cols, aa.vals)
        if col == column and str(val) != ""
    ]
    if not lines:
        raise ValueError(
            f"cannot write JSONL: every '{column}' entry is empty"
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


#: Extensions any of the savers below might append — stripped up front from a
#: URL-derived base name so a real extension already present (e.g. a save
#: dialog's own pick, or a URL typed with one) never doubles up with the one
#: the selected Format appends. Each saver also still strips its own specific
#: suffix internally (unchanged, for the legacy bare-``filename`` callers),
#: which is a harmless no-op once this has already run.
_KNOWN_EXTENSIONS = (
    ".parquet", ".jsonl", ".json", ".csv", ".txt", ".jpeg", ".jpg", ".png",
)


def _strip_known_extension(name: str) -> str:
    lower = name.lower()
    for ext in _KNOWN_EXTENSIONS:
        if lower.endswith(ext):
            return name[: -len(ext)]
    return name


def _resolve_base(url: Optional[str], filename: str) -> str:
    """The base name (no extension) the savers below receive as ``filename``.

    Resolved from *url* when given (stripping the ``file://`` scheme down to
    a filesystem path — an absolute one overrides ``storage_out_dir()``
    entirely per ``pathlib``'s own join behavior, so this transparently
    supports both a relative name under ``storage/out/`` and an absolute
    destination picked via a save dialog); otherwise the legacy bare
    *filename*. Shared with :func:`resolve_output_path` so the real write and
    the Cancel-cleanup delete can never disagree about where a request lands.

    Raises:
        ValueError: *url* is not a ``file://`` (or schemeless-local) URL —
            saving to ``http``/``https`` is not yet implemented.
    """
    if url is not None:
        parsed = IOSupport.parse_url(url)
        if parsed.scheme in ("http", "https"):
            raise ValueError(
                f"Saving to a remote {parsed.scheme}:// URL is not yet "
                "implemented — only a local file:// URL (or bare path) is "
                "supported."
            )
        base = IOSupport.local_path(url)
    else:
        base = filename
    return _strip_known_extension(base)


def resolve_output_path(
    url: Optional[str] = None,
    filename: str = "export",
    format: str = "parquet",
    payload_kind: str = "aa",
    has_jsonl_column: bool = False,
) -> Path:
    """The exact ``Path`` :func:`execute_save` would write to for these
    inputs, without writing anything.

    Exists for the Cancel-cleanup route (:func:`delete_output`): the backend
    write itself can't be interrupted mid-flight (a client giving up on the
    HTTP request doesn't stop the already-dispatched threadpool call), so
    "cancelling leaves no partial file behind" can only be made true by
    deleting after the fact — which requires recomputing where a since-
    abandoned request would have landed.

    Args:
        payload_kind: ``"aa"``, ``"text"``, or ``"image"`` — which of
            :func:`execute_save`'s three payload arguments the request
            carried; the extension a bare ``format`` alone doesn't
            disambiguate (e.g. text is always ``.txt`` regardless of
            ``format``).
        has_jsonl_column: Whether the AA carried a ``json_line`` column —
            only meaningful for ``payload_kind="aa"``.
    """
    base = _resolve_base(url, filename)
    raw = url if url is not None else filename

    if payload_kind == "text":
        ext = ".txt"
    elif payload_kind == "image":
        ext = ".png" if format == "png" else ".jpg"
    elif format == "jsonl" or (has_jsonl_column and raw.endswith(".jsonl")):
        ext = ".jsonl"
    elif format == "csv":
        ext = ".csv"
    elif format in ("json", "json5"):
        ext = ".json"
    else:
        ext = ".parquet"

    return storage_out_dir() / f"{base}{ext}"


def delete_output(
    url: Optional[str] = None,
    filename: str = "export",
    format: str = "parquet",
    payload_kind: str = "aa",
    has_jsonl_column: bool = False,
) -> bool:
    """Best-effort Cancel cleanup: remove whatever a since-abandoned
    :func:`execute_save` call would have written, if it landed on disk after
    all (see :func:`resolve_output_path`).

    Returns:
        Whether a file was actually removed (``False`` — not an error — when
        nothing was there, e.g. the write genuinely hadn't finished yet).
    """
    path = resolve_output_path(
        url=url,
        filename=filename,
        format=format,
        payload_kind=payload_kind,
        has_jsonl_column=has_jsonl_column,
    )
    try:
        path.unlink()
        return True
    except FileNotFoundError:
        return False


def execute_save(
    aa: Optional[AssocArray] = None,
    text: Optional[str] = None,
    image_base64: Optional[str] = None,
    filename: str = "export",
    format: str = "parquet",
    url: Optional[str] = None,
) -> tuple[Path, int]:
    """Execute the Save File node logic.

    Routes to the appropriate saver based on data and format.

    Args:
        aa: AssocArray payload (if present).
        text: Text payload (if present).
        image_base64: Base64-encoded image bytes (if present).
        filename: Legacy bare output filename (without extension), resolved
            under ``storage_out_dir()``. Superseded by *url* when given.
        format: Output format ("parquet", "csv", "json", "jsonl", "txt", "png",
            "jpg").
        url: A ``file://`` URL (or bare local path) naming the destination —
            the "URL" field's value (``GLOBAL_UX_CONTRACT.md`` §6). Takes
            precedence over *filename* when given. ``http``/``https`` are
            valid URL schemes generally but not yet implemented as a save
            destination — see :func:`_resolve_base`.

    Returns:
        Tuple of (output Path, bytes written).

    Raises:
        ValueError: If no data provided, *url* names an unimplemented remote
            scheme, the format does not match the payload, or a JSONL write
            was asked for without a ``json_line`` column.
    """
    base = _resolve_base(url, filename)
    raw = url if url is not None else filename

    if aa is not None:
        if format == "jsonl" or (aa_has_jsonl(aa) and raw.endswith(".jsonl")):
            # Pre-formatted training lines: write them as-is rather than as a
            # matrix. Triggered by an explicit format or by a .jsonl name on an
            # AA that actually carries the column.
            out_path = save_aa_jsonl(aa, base)
        elif format == "csv":
            out_path = save_aa_csv(aa, base)
        elif format in ("json", "json5"):
            out_path = save_aa_json(aa, base)
        else:  # Default to parquet for AA.
            out_path = save_aa_parquet(aa, base)
    elif text is not None:
        out_path = save_text(text, base)
    elif image_base64 is not None:
        out_path = save_image(image_base64, base, format)
    else:
        raise ValueError("No data provided (aa, text, or image_base64)")

    return out_path, out_path.stat().st_size
