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
import glob
import zipfile
import tempfile
import urllib.parse
import urllib.request

import pyarrow as pa
import pyarrow.parquet as pq

from .io_support import IOSupport
from .models import AssocArray
from .save_file import load_parquet_with_auto_detect, _table_to_aa

# Directory names skipped outright, on top of every dotted directory (.git, etc.)
SKIP_DIRS = {"deps", "node_modules", "target", ".git"}

# The Flutter node names its schema modes with a Dart enum, so it sends the
# camelCase spelling on the wire. Accept both rather than silently falling
# through to "auto" for every explicit mode the user picks.
_SCHEMA_MODE_ALIASES = {"forceAa": "force_aa", "rawTable": "raw_table"}

# Extensions read as plain text. Kept in step with `allowedExtensions` in
# `frontend/lib/widgets/nodes/implementations/load_file_node.dart`: the
# picker and the loader agreeing is what keeps a selectable file loadable.
TEXT_SUFFIXES = (".txt", ".jl", ".md")


def load_file(file_path: str, schema_mode: str = "auto") -> tuple[Optional[AssocArray], Optional[dict]]:
    """Load a file, remote URL, directory, or glob pattern, and parse into an AssocArray.

    Handles 'file://' and 'http://' / 'https://' URLs (unpacking .zip files to temp directories).
    Performs directory walking or glob pattern expansion.
    Returns (AssocArray, raw_representation).
    """
    # 1. Parse URL/File Path
    parsed = IOSupport.parse_url(file_path)
    temp_dir = None

    if parsed.scheme in ("file", ""):
        # standard local file or unquoted file:// path
        path_str = urllib.parse.unquote(parsed.path)
        resolved_path = Path(path_str)
    elif parsed.scheme in ("http", "https"):
        # Remote download / unzip
        temp_dir_obj = tempfile.TemporaryDirectory(prefix="dn_dl_")
        temp_dir = temp_dir_obj
        temp_path = Path(temp_dir_obj.name)
        filename = Path(parsed.path).name or "download.zip"
        download_target = temp_path / filename

        try:
            urllib.request.urlretrieve(file_path, str(download_target))
        except Exception as exc:
            temp_dir_obj.cleanup()
            raise ValueError(f"Failed to download remote file: {exc}")

        if download_target.suffix.lower() == ".zip":
            unpack_dir = temp_path / "unpacked"
            unpack_dir.mkdir(parents=True, exist_ok=True)
            try:
                with zipfile.ZipFile(download_target, "r") as zip_ref:
                    zip_ref.extractall(unpack_dir)
                resolved_path = unpack_dir
            except Exception as exc:
                temp_dir_obj.cleanup()
                raise ValueError(f"Failed to unpack zip: {exc}")
        else:
            resolved_path = download_target

    # 2. Check for Directory or Glob Expansion
    files = []
    # If the user passed a glob string pattern (or if resolved_path is a directory)
    if resolved_path.is_dir():
        for p in resolved_path.rglob("*"):
            if p.is_file():
                # Filter out hidden or skipped directories
                relative = p.relative_to(resolved_path)
                if any(part.startswith(".") or part in SKIP_DIRS for part in relative.parts):
                    continue
                files.append(p)
        files = sorted(files)
    elif "*" in file_path or "?" in file_path or "[" in file_path:
        # Local glob pattern
        glob_matches = glob.glob(file_path, recursive=True)
        files = [Path(f) for f in glob_matches if Path(f).is_file()]
        files = sorted(files)
    else:
        # Single file
        if not resolved_path.exists():
            if temp_dir:
                temp_dir.cleanup()
            raise FileNotFoundError(f"File not found: {file_path}")
        files = [resolved_path]

    # 3. Handle Multi-File AA Construction
    # If there is more than 1 file, or if the single target was expanded from a directory
    if len(files) > 1 or resolved_path.is_dir():
        rows: list[str] = []
        cols: list[str] = []
        vals: list[Union[str, int, float]] = []
        records = []
        
        for i, file_p in enumerate(files):
            row_key = f"file:{i:05d}"
            # Relative path to directory if directory loaded, else absolute path string
            if resolved_path.is_dir():
                file_path_str = str(file_p.relative_to(resolved_path))
            else:
                file_path_str = str(file_p)
                
            try:
                text = file_p.read_text(encoding="utf-8", errors="replace")
            except Exception:
                text = ""
                
            ext = file_p.suffix.lower()
            try:
                size = file_p.stat().st_size
            except Exception:
                size = 0
                
            cols_list = ["row", "file_path", "text", "extension", "file_size"]
            vals_list = [row_key, file_path_str, text, ext, size]
            
            for c, v in zip(cols_list, vals_list):
                rows.append(row_key)
                cols.append(c)
                vals.append(v)
                
            records.append({
                "row": row_key,
                "file_path": file_path_str,
                "text": text,
                "extension": ext,
                "file_size": size,
            })
            
        # Clean up temporary directory if we are done with it
        if temp_dir:
            temp_dir.cleanup()
            
        aa = AssocArray(rows=rows, cols=cols, vals=vals)
        return aa, {"rows": records}

    if not files:
        if temp_dir:
            temp_dir.cleanup()
        raise FileNotFoundError(f"No files matched glob or directory walk: {file_path}")

    # 4. Handle Single File Loading
    single_file = files[0]
    schema_mode = _SCHEMA_MODE_ALIASES.get(schema_mode, schema_mode)
    suffix = single_file.suffix.lower()

    try:
        if suffix == ".parquet":
            aa, data = _load_parquet(single_file, schema_mode)
        elif suffix == ".arrow":
            aa, data = _load_arrow(single_file, schema_mode)
        elif suffix == ".json":
            aa, data = _load_json(single_file, schema_mode)
        elif suffix == ".csv":
            aa, data = _load_csv(single_file, schema_mode)
        elif suffix in TEXT_SUFFIXES:
            aa, data = _load_text(single_file, schema_mode)
        else:
            raise ValueError(f"Unsupported file format: {suffix}")
    finally:
        if temp_dir:
            temp_dir.cleanup()

    return aa, data


def _load_text(path: Path, schema_mode: str) -> tuple[Optional[AssocArray], Optional[dict]]:
    """Load a source or prose file as a single-cell AA plus its raw string.

    A ``.jl`` file has no rows and columns of its own, so the AA is one cell:
    ``rows=["0"]``, ``cols=["text"]``, the whole file as the value. That is
    deliberately the same shape the Flutter side used to build client-side, so the
    nodes that read it — Polyglot Exec, Prompt Node — need no change; they already
    look for a ``text`` column.

    Under ``raw_table`` the AA is withheld and only the raw string comes back, for a
    caller that wants the bytes and nothing inferred.
    """
    text = path.read_text()
    raw = {"text": text}
    if schema_mode == "raw_table":
        return None, raw
    # `file_path` travels with the text: a downstream node needs it to know what it
    # is looking at — AST Extract to know which file to parse, Polyglot Exec to
    # infer the language from the extension. Only for text; adding it to a real
    # table's schema would pollute it.
    return (
        AssocArray(
            rows=["0", "0"],
            cols=["text", "file_path"],
            vals=[text, str(path)],
        ),
        raw,
    )


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
