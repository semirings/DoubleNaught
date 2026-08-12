"""Write generated docstrings from a 7-column Arrow index back into the sources.

The write-side counterpart to :mod:`ast_extract`: it takes the table that module
produced — enriched by a teacher node with a `better_docstring` column — and runs
``julia/patch_docstrings.jl`` over it through the Polyglot Exec runner.

Arrow in, Arrow out. The index goes to the script as an Arrow IPC file, and the
summary comes back as one: ``file_path`` (string), ``symbols_patched`` (int64),
``status`` (``UPDATED`` / ``NO_CHANGE`` / ``ERROR``). Nothing on this path is
serialised as JSON.

**This rewrites files on disk.** Three properties make that safe enough to
automate, and all three are worth knowing before you call it:

* Patching is a **byte splice** located by the AST, never a re-print, so code,
  comments and indentation outside the edited range survive byte-for-byte.
* It is **all-or-nothing per file**: if any row cannot be located — a stale index,
  a file edited since extraction — that file is left untouched and reported as
  ``ERROR``.
* Writes go through a temp file in the same directory, then a rename, so a crash
  cannot truncate a source file.

Pass ``dry_run=True`` to compute the patch and report what *would* change without
writing anything.
"""

from __future__ import annotations

import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional, Union

import pyarrow as pa

from .ast_extract import (
    AstExtractError,
    read_arrow_table,
    to_arrow_bytes,
    validate_schema,
)
from .polyglot_exec_node import ExecInput, PolyglotExecNode

#: Columns of the summary table the script emits.
SUMMARY_COLUMNS: tuple[str, ...] = ("file_path", "symbols_patched", "status")

STATUS_UPDATED = "UPDATED"
STATUS_NO_CHANGE = "NO_CHANGE"
STATUS_ERROR = "ERROR"

DEFAULT_TIMEOUT_S = 180.0

#: Overridable so a deployment can relocate the script.
SCRIPT_ENV_VAR = "DN_PATCH_DOCSTRINGS_JL"


def default_script_path() -> Path:
    """Location of ``patch_docstrings.jl`` — env override or the repo copy."""
    import os

    override = os.environ.get(SCRIPT_ENV_VAR)
    if override:
        return Path(override).expanduser()
    return Path(__file__).resolve().parents[2] / "julia" / "patch_docstrings.jl"


class PatchDocstringsError(RuntimeError):
    """The patch run could not be made, or produced nothing readable."""


@dataclass
class PatchSummary:
    """The outcome of one patch run, per file."""

    #: `file_path` / `symbols_patched` / `status`, still an Arrow table.
    table: pa.Table

    #: Messages for rows that could not be applied — a stale index, mostly.
    errors: list[str] = field(default_factory=list)

    #: True when nothing was written to disk.
    dry_run: bool = False

    #: The root the relative `file_path`s were resolved against.
    root: str = ""

    def _paths_with(self, status: str) -> list[str]:
        rows = zip(
            self.table.column("file_path").to_pylist(),
            self.table.column("status").to_pylist(),
        )
        return [path for path, value in rows if value == status]

    @property
    def updated(self) -> list[str]:
        """Files actually changed on disk (or that would be, in a dry run)."""
        return self._paths_with(STATUS_UPDATED)

    @property
    def unchanged(self) -> list[str]:
        return self._paths_with(STATUS_NO_CHANGE)

    @property
    def failed(self) -> list[str]:
        return self._paths_with(STATUS_ERROR)

    @property
    def symbols_patched(self) -> int:
        total = self.table.column("symbols_patched").to_pylist()
        return sum(value or 0 for value in total)


def validate_summary(table: pa.Table) -> None:
    """Check the summary is the agreed 3-column shape.

    Raises:
        PatchDocstringsError: columns are wrong, or `symbols_patched` is not an
            integer column — it is a count, and stringifying it would lose that.
    """
    if tuple(table.column_names) != SUMMARY_COLUMNS:
        raise PatchDocstringsError(
            "unexpected patch summary schema: "
            f"got {tuple(table.column_names)}, expected {SUMMARY_COLUMNS}"
        )
    if not pa.types.is_integer(table.schema.field("symbols_patched").type):
        raise PatchDocstringsError(
            "symbols_patched must be an integer column, got "
            f"{table.schema.field('symbols_patched').type}"
        )


def _metadata(table: pa.Table) -> dict[str, str]:
    raw = table.schema.metadata or {}
    return {
        key.decode("utf-8", "replace"): value.decode("utf-8", "replace")
        for key, value in raw.items()
    }


class PatchDocstringsNode:
    """Node wrapper around ``patch_docstrings.jl``.

    Args:
        script: Path to the patch script. Defaults to :func:`default_script_path`.
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

    async def patch(
        self,
        index: Union[pa.Table, bytes, str, Path],
        *,
        root: Optional[Union[str, Path]] = None,
        dry_run: bool = False,
    ) -> PatchSummary:
        """Apply every non-empty ``better_docstring`` in [index] to its source.

        [index] may be the in-memory Arrow table, raw Arrow bytes, or a path to an
        ``.arrow`` file — whichever the caller happens to be holding.

        [root] resolves the index's **relative** ``file_path`` values. It defaults
        to the ``dn_root`` the extractor recorded in the table's own metadata, so a
        table that came straight from :mod:`ast_extract` needs nothing here.

        Raises:
            PatchDocstringsError: the table is not the 7-column index, the script
                is missing, Julia is unavailable, or the run failed or timed out.
        """
        table = index if isinstance(index, pa.Table) else read_arrow_table(index)

        try:
            validate_schema(table)
        except AstExtractError as exc:
            raise PatchDocstringsError(f"input is not the AST index: {exc}") from exc

        if not self.script.is_file():
            raise PatchDocstringsError(
                f"patch script not found at {self.script} "
                f"(set ${SCRIPT_ENV_VAR} to relocate it)"
            )

        resolved_root = str(Path(root).expanduser()) if root else _metadata(table).get(
            "dn_root", ""
        )
        if not resolved_root and _has_relative_paths(table):
            raise PatchDocstringsError(
                "the index has relative file paths and no root: pass root=…, or "
                "use a table carrying the extractor's dn_root metadata"
            )

        workspace = Path(tempfile.mkdtemp(prefix="dn_patch_"))
        index_path = workspace / "index.arrow"
        summary_path = workspace / "summary.arrow"
        index_path.write_bytes(to_arrow_bytes(table))

        arguments = [str(index_path), str(summary_path)]
        if resolved_root:
            arguments.append(f"--root={resolved_root}")
        if dry_run:
            arguments.append("--dry-run")

        # `include` + args: the exec framework runs code via `julia -e`, and
        # arguments after the snippet land in ARGS as they would for a script.
        # Double quotes, hand-escaped — Python's `!r` yields single quotes, which
        # Julia reads as a character literal.
        literal = str(self.script).replace("\\", "\\\\").replace('"', '\\"')
        try:
            result = await self._exec.run(
                ExecInput(
                    code=f'include("{literal}")',
                    language="julia",
                    file_path=str(self.script),
                    args=arguments,
                ),
                timeout_s=self.timeout_s,
            )

            if result["status"] != "SUCCESS":
                detail = (result["stderr"] or result["stdout"] or "").strip()
                raise PatchDocstringsError(
                    f"patch_docstrings.jl {result['status'].lower()} "
                    f"(exit {result['exit_code']}): {detail[:2000]}"
                )

            summary = read_arrow_table(summary_path)
        finally:
            index_path.unlink(missing_ok=True)
            summary_path.unlink(missing_ok=True)
            try:
                workspace.rmdir()
            except OSError:
                pass

        validate_summary(summary)
        meta = _metadata(summary)
        return PatchSummary(
            table=summary,
            errors=[line for line in meta.get("dn_errors", "").splitlines() if line.strip()],
            dry_run=meta.get("dn_dry_run", "").lower() == "true",
            root=meta.get("dn_root", resolved_root),
        )


def _has_relative_paths(table: pa.Table) -> bool:
    """Whether any `file_path` needs a root to resolve."""
    return any(
        not Path(path).is_absolute()
        for path in table.column("file_path").to_pylist()
        if path
    )


async def patch_docstrings(
    index: Union[pa.Table, bytes, str, Path],
    *,
    root: Optional[Union[str, Path]] = None,
    dry_run: bool = False,
    timeout_s: float = DEFAULT_TIMEOUT_S,
) -> PatchSummary:
    """Convenience wrapper over :class:`PatchDocstringsNode` for a one-off run."""
    return await PatchDocstringsNode(timeout_s=timeout_s).patch(
        index, root=root, dry_run=dry_run
    )
