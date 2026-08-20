"""Read a Julia codebase's function/macro index as an Apache Arrow table.

Runs ``julia/extract_ast.jl`` through the Polyglot Exec framework and hands back a
``pyarrow.Table`` — **not** a dict, not JSON. The table is the payload: it keeps
its schema, it keeps its typing, and it is the thing a downstream teacher node
reads and writes back.

Two shape facts drive the design here, both established by probing rather than
assumed:

* ``Arrow.write`` produces the Arrow IPC **file** format (``ARROW1`` magic).
  ``pyarrow.ipc.open_stream`` therefore *fails* on it, and
  ``pyarrow.feather.read_table`` — while it works — is deprecated as of pyarrow
  24. :func:`read_arrow_table` sniffs the magic and uses the right reader, so
  both the file and stream formats are handled whichever way the script emitted
  them.
* :class:`~.polyglot_exec_node.PolyglotExecNode` decodes a child's stdout as UTF-8
  text (with replacement), which would corrupt binary Arrow. So the script is
  always asked to write to a **file**, via its second argument — the alternative
  the extraction spec itself allows — and stdout carries nothing.

Per-file parse failures do not stop the walk. The Julia side records them and
ships the report inside the artifact's schema metadata, so the diagnostics arrive
structurally instead of being scraped out of stderr.
"""

from __future__ import annotations

import os
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional, Union

import pyarrow as pa
import pyarrow.ipc as ipc

from .polyglot_exec_node import ExecInput, PolyglotExecNode

#: The seven columns, in order. Mirrors ``COLUMNS`` in ``extract_ast.jl``; the two
#: are checked against each other by :func:`validate_schema`, so a drift on either
#: side is a loud failure rather than a silently reshaped table.
SCHEMA_COLUMNS: tuple[str, ...] = (
    "symbol_name",
    "kind",
    "file_path",
    "line_range",
    "docstring",
    "raw_code",
    "better_docstring",
)

#: Magic that marks the Arrow IPC *file* format. Its absence means a raw stream.
ARROW_FILE_MAGIC = b"ARROW1"

#: Default wall-clock budget. Generous next to the exec node's 30 s: a cold Julia
#: plus loading Arrow.jl costs a couple of seconds before any parsing starts.
DEFAULT_TIMEOUT_S = 180.0

#: Overridable so a deployment can relocate the script.
SCRIPT_ENV_VAR = "DN_EXTRACT_AST_JL"


def default_script_path() -> Path:
    """Location of ``extract_ast.jl`` — ``$DN_EXTRACT_AST_JL`` or the repo copy."""
    override = os.environ.get(SCRIPT_ENV_VAR)
    if override:
        return Path(override).expanduser()
    # src/double_touch/ast_extract.py → double_touch/julia/extract_ast.jl
    return Path(__file__).resolve().parents[2] / "julia" / "extract_ast.jl"


@dataclass
class AstIndex:
    """One extraction run: the Arrow table plus what happened while building it."""

    #: The 7-column index. Held as an Arrow table throughout.
    table: pa.Table

    #: Where the Arrow artifact was written, if it was kept.
    artifact: Optional[Path] = None

    #: Files the Julia side skipped, one message each — a broken file is reported,
    #: never fatal.
    errors: list[str] = field(default_factory=list)

    files_scanned: int = 0

    #: The root that was indexed, as the script resolved it.
    root: str = ""

    @property
    def definition_count(self) -> int:
        return self.table.num_rows

    def column(self, name: str) -> pa.ChunkedArray:
        """One column, still as Arrow data."""
        return self.table.column(name)


class AstExtractError(RuntimeError):
    """The extraction could not be run, or produced nothing readable."""


def read_arrow_table(source: Union[str, Path, bytes, memoryview]) -> pa.Table:
    """Read an Arrow IPC payload, in either the file or the stream format.

    Accepts a path or raw bytes. The format is decided by the ``ARROW1`` magic
    rather than by the caller, because which one you get depends on how the
    producer wrote it: ``Arrow.write`` to a path yields the file format, while a
    producer streaming to a pipe may not.

    Raises:
        AstExtractError: the payload is not readable as either format.
    """
    if isinstance(source, (bytes, memoryview)):
        raw = bytes(source)
        buffer = pa.BufferReader(raw)
        try:
            if raw.startswith(ARROW_FILE_MAGIC):
                return ipc.open_file(buffer).read_all()
            return ipc.open_stream(buffer).read_all()
        except pa.ArrowInvalid as exc:
            raise AstExtractError(f"not a readable Arrow payload: {exc}") from exc

    path = Path(source)
    if not path.is_file():
        raise AstExtractError(f"no Arrow artifact at {path}")
    with path.open("rb") as handle:
        head = handle.read(len(ARROW_FILE_MAGIC))
    try:
        if head == ARROW_FILE_MAGIC:
            return ipc.open_file(str(path)).read_all()
        with path.open("rb") as handle:
            return ipc.open_stream(handle).read_all()
    except pa.ArrowInvalid as exc:
        raise AstExtractError(f"{path} is not a readable Arrow payload: {exc}") from exc


def validate_schema(table: pa.Table) -> None:
    """Check the table is the agreed 7-column, all-string index.

    Raises:
        AstExtractError: columns are missing, extra, out of order, or not strings.
    """
    if tuple(table.column_names) != SCHEMA_COLUMNS:
        raise AstExtractError(
            "unexpected AST index schema: "
            f"got {tuple(table.column_names)}, expected {SCHEMA_COLUMNS}"
        )
    wrong = [
        field.name
        for field in table.schema
        if not pa.types.is_string(field.type) and not pa.types.is_large_string(field.type)
    ]
    if wrong:
        raise AstExtractError(f"non-string columns in the AST index: {wrong}")


def _metadata(table: pa.Table) -> dict[str, str]:
    """Schema metadata as ``str -> str`` (Arrow stores it as bytes)."""
    raw = table.schema.metadata or {}
    return {
        key.decode("utf-8", "replace"): value.decode("utf-8", "replace")
        for key, value in raw.items()
    }


def to_arrow_bytes(table: pa.Table) -> bytes:
    """Serialise [table] as an Arrow IPC **file**, preserving schema metadata.

    The wire form for handing the index on: still Arrow, never JSON.
    """
    sink = pa.BufferOutputStream()
    with ipc.new_file(sink, table.schema) as writer:
        writer.write_table(table)
    return sink.getvalue().to_pybytes()


def aa_from_table(table: pa.Table) -> "AssocArray":
    """The 7-column index as a wire AA (dense row-major matrix), for the canvas.

    Row keys are ``<file_path>:<line_range>`` — informative, and unique because the
    walk never descends into a definition's body, so two definitions cannot share a
    file and a line span. A ``#n`` suffix is appended if one ever does, because a
    duplicate row key would silently merge two definitions into one row.

    Dart has no Arrow reader, which is the whole reason this exists; the Arrow route
    stays the canonical one for the backend pipeline.

    Flattening the table into per-cell triples is plain data marshalling, not AA
    algebra, so it happens here in Python. But the resulting AA is built by
    :func:`d4m_ops.build_assoc` — D4M.jl's actual ``Assoc`` constructor — rather
    than assembled by hand, per this project's D4M/AA rule (see CLAUDE.md).
    """
    from .d4m_ops import build_assoc  # local: avoids a cycle at module import
    from .models import AssocArray  # local: avoids a cycle at module import

    records = table.select(list(SCHEMA_COLUMNS)).to_pylist()
    if not records:
        # Trivially a well-formed (empty) AA — no rows/cols exist to violate
        # either invariant, so there is nothing for D4M.jl to canonicalize.
        return AssocArray(rows=[], cols=[], vals=[])

    rows: list[str] = []
    cols: list[str] = []
    vals: list[object] = []
    seen: dict[str, int] = {}

    for record in records:
        key = f"{record.get('file_path') or '?'}:{record.get('line_range') or '?'}"
        count = seen.get(key, 0)
        seen[key] = count + 1
        if count:
            key = f"{key}#{count}"
        for column in SCHEMA_COLUMNS:
            rows.append(key)
            cols.append(column)
            vals.append(record.get(column) or "")

    return build_assoc(rows, cols, vals)


class AstExtractNode:
    """Node wrapper around ``extract_ast.jl``.

    Args:
        script: Path to the extraction script. Defaults to
            :func:`default_script_path`.
        timeout_s: Wall-clock budget for the Julia run.
        exec_node: Execution seam — the Polyglot Exec node by default, injected in
            tests to run without Julia installed.
    """

    def __init__(
        self,
        *,
        script: Optional[Path] = None,
        timeout_s: float = DEFAULT_TIMEOUT_S,
        exec_node: Optional[PolyglotExecNode] = None,
    ) -> None:
        self.script = Path(script) if script else default_script_path()
        self.timeout_s = timeout_s
        self._exec = exec_node or PolyglotExecNode(timeout_s=timeout_s)

    async def extract(
        self,
        root: Union[str, Path],
        *,
        out_path: Optional[Union[str, Path]] = None,
        parsed_payload: Optional[AssocArray] = None,
    ) -> AstIndex:
        """Index every function and macro under [root].

        If [parsed_payload] is provided, walks each Julia (.jl) file path present
        in the multi-row payload and combines all extracted definitions into a
        single merged AstIndex.

        Raises:
            AstExtractError: parsing or extraction failure.
        """
        inputs = {
            "parsedPayload": parsed_payload,
            "codebasePath": parsed_payload,
            "aa": parsed_payload,
        }

        print("================ [AST EXTRACT RUNNING] ================")
        print(f"[AST EXTRACT] Raw inputs: {list(inputs.keys())}")

        # Extract incoming AA dataframe/dictionary
        aa_payload = inputs.get("codebasePath") or inputs.get("parsedPayload")
        raw_code = None

        if hasattr(aa_payload, "to_dict"):
            # Extract text column from AA
            raw_code = aa_payload.to_dict().get("text", [None])[0]
        elif isinstance(aa_payload, dict):
            raw_code = aa_payload.get("text")

        print(f"[DEBUG AST Extract] Extracted raw_code length: {len(raw_code) if raw_code else 'NONE'}")

        print(f"[DEBUG AstExtractNode] Raw root_path: {root}")
        print(f"[DEBUG AstExtractNode] Ingested parsed_payload: {parsed_payload}")

        if not str(root).strip() and not parsed_payload:
            print("[DEBUG AstExtractNode] Execution skipped: No path or upstream AA provided.")
            raise AstExtractError("No path or upstream AA payload provided.")

        if parsed_payload is not None:
            from .aa_utils import aa_rows
            records = aa_rows(parsed_payload)
            jl_files = []
            
            # Create a temporary directory to write in-memory file contents so the
            # Julia parser can read them as standard files.
            temp_sources_dir = tempfile.TemporaryDirectory(prefix="dn_ast_sources_")
            temp_sources_path = Path(temp_sources_dir.name)

            try:
                for row_key, rec in records:
                    ext = rec.get("extension", "").lower()
                    f_path = rec.get("file_path", "") or rec.get("filepath", "") or rec.get("path", "")
                    text = rec.get("text", "") or rec.get("raw_text", "")

                    if not f_path:
                        f_path = f"source_{row_key}.jl"

                    if ext == ".jl" or Path(f_path).suffix.lower() == ".jl" or text.strip():
                        # Write the in-memory text to a temporary local file,
                        # preserving its base name.
                        safe_name = Path(f_path).name or f"source_{row_key}.jl"
                        # Force `.jl` extension so Julia's `julia_files()` walker accepts and parses it
                        if not safe_name.endswith(".jl"):
                            safe_name = Path(safe_name).stem + f"_{row_key}.jl"
                        temp_file = temp_sources_path / safe_name
                        temp_file.write_text(text, encoding="utf-8")
                        jl_files.append((temp_file, f_path))

                if not jl_files:
                    raise AstExtractError("No Julia (.jl) files found in the payload")

                tables = []
                all_errors = []
                scanned = 0

                for temp_file, orig_path in jl_files:
                    try:
                        # Extract the AST from the temporary file buffer
                        index = await self._run_extractor(temp_file, keep=False)
                        
                        # Re-point the "file_path" column back to its original name.
                        # This ensures downstream nodes (such as Patch Docstrings)
                        # can cleanly locate the file.
                        repointed_rows = [orig_path] * index.table.num_rows
                        cols_dict = {}
                        for col_name in index.table.column_names:
                            if col_name == "file_path":
                                cols_dict[col_name] = pa.array(repointed_rows, type=pa.string())
                            else:
                                cols_dict[col_name] = index.table.column(col_name)

                        repointed_table = pa.table(cols_dict, schema=index.table.schema)
                        tables.append(repointed_table)
                        all_errors.extend(index.errors)
                        scanned += index.files_scanned
                    except Exception as exc:
                        all_errors.append(f"{orig_path}: Extraction failed: {exc}")

                if not tables:
                    raise AstExtractError("Could not extract AST from any of the Julia files")

                merged_table = pa.concat_tables(tables)
                return AstIndex(
                    table=merged_table,
                    errors=all_errors,
                    files_scanned=scanned,
                    root=str(root),
                )
            finally:
                temp_sources_dir.cleanup()

        return await self._run_extractor(root, keep=(out_path is not None), out_path=out_path)

    async def _run_extractor(
        self,
        root: Union[str, Path],
        *,
        keep: bool = False,
        out_path: Optional[Union[str, Path]] = None,
    ) -> AstIndex:
        source_root = Path(root).expanduser()
        # A single `.jl` file is a valid root: the canvas extracts the file a
        # `Load File` node opened, not the tree around it.
        if not source_root.is_dir() and not source_root.is_file():
            raise AstExtractError(f"no such file or directory: {source_root}")
        if not self.script.is_file():
            raise AstExtractError(
                f"extraction script not found at {self.script} "
                f"(set ${SCRIPT_ENV_VAR} to relocate it)"
            )

        destination = (
            Path(out_path).expanduser()
            if keep and out_path
            else Path(tempfile.mkdtemp(prefix="dn_ast_")) / "ast_index.arrow"
        )
        destination.parent.mkdir(parents=True, exist_ok=True)

        # `include` + args, rather than `julia script.jl …`: the exec framework
        # runs code via `julia -e`, and arguments after the snippet land in ARGS
        # exactly as they would for a script. `file_path` sets the child's cwd to
        # the script's directory.
        #
        # Double quotes, hand-escaped: Python's `!r` yields single quotes, which
        # Julia reads as a *character* literal, not a string.
        literal = str(self.script).replace("\\", "\\\\").replace('"', '\\"')
        result = await self._exec.run(
            ExecInput(
                code=f'include("{literal}")',
                language="julia",
                file_path=str(self.script),
                args=[str(source_root.resolve()), str(destination)],
            ),
            timeout_s=self.timeout_s,
        )

        if result["status"] != "SUCCESS":
            detail = (result["stderr"] or result["stdout"] or "").strip()
            raise AstExtractError(
                f"extract_ast.jl {result['status'].lower()} "
                f"(exit {result['exit_code']}): {detail[:2000]}"
            )

        try:
            table = read_arrow_table(destination)
        finally:
            if not keep:
                # Clear up the temp artifact but keep the table we just read.
                destination.unlink(missing_ok=True)
                try:
                    destination.parent.rmdir()
                except OSError:
                    pass

        validate_schema(table)
        meta = _metadata(table)
        error_report = meta.get("dn_errors", "")
        return AstIndex(
            table=table,
            artifact=destination if keep else None,
            errors=[line for line in error_report.splitlines() if line.strip()],
            files_scanned=int(meta.get("dn_files_scanned", "0") or 0),
            root=meta.get("dn_root", str(source_root)),
        )


async def extract_ast(
    root: Union[str, Path],
    *,
    out_path: Optional[Union[str, Path]] = None,
    timeout_s: float = DEFAULT_TIMEOUT_S,
) -> AstIndex:
    """Convenience wrapper over :class:`AstExtractNode` for a one-off run."""
    return await AstExtractNode(timeout_s=timeout_s).extract(root, out_path=out_path)
