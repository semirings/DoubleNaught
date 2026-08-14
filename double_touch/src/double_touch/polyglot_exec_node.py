"""Run source code carried on an AA payload in an isolated subprocess.

The Polyglot Exec node is the execution half of the "load a source file, then do
something with it" chain: ``Load File`` puts a file's text on the graph, this node
runs it under the right interpreter, and the result — stdout, stderr, exit code,
timing — goes back onto the graph as an AA for a downstream Gemini / Trainer /
Preview node to read.

**This executes arbitrary code by design.** It is a local developer tool: the
backend binds to 127.0.0.1 and the code comes from a file the user picked. There
is no sandbox, no syscall filter and no resource cap beyond the timeout, so do
not expose this route to a network you do not control. Nothing is passed through
a shell by *us* — :func:`asyncio.create_subprocess_exec` takes an argv list, so
the snippet is one argument and cannot be word-split or re-interpreted — but
``bash -c`` and ``python3 -c`` are interpreters, and interpreting the code is the
whole point.

Language resolution is layered, most-explicit first: a caller's override, then
the payload's ``language``, then the file extension, then a shebang. See
:meth:`PolyglotExecNode.resolve_language`.
"""

from __future__ import annotations

import asyncio
import os
import shutil
import signal
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Optional, Sequence
from uuid import uuid4

from .aa_utils import aa_rows
from .models import AssocArray

# ---------------------------------------------------------------------------
# Language table
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Language:
    """One interpreter this node knows how to drive.

    ``argv`` ends with the flag that takes code on the command line; the snippet
    is appended as a single argument, then any user ``args``.

    ``argv0`` exists for ``bash``: ``bash -c CODE a b`` binds ``a`` to ``$0``,
    not ``$1``, so a placeholder is inserted to make ``$1`` the first user
    argument, matching every other language here.
    """

    name: str
    argv: tuple[str, ...]
    suffixes: tuple[str, ...] = ()
    aliases: tuple[str, ...] = ()
    argv0: Optional[str] = None


LANGUAGES: tuple[Language, ...] = (
    Language(
        name="julia",
        argv=("julia", "--startup-file=no", "-e"),
        suffixes=(".jl",),
    ),
    Language(
        name="python",
        argv=("python3", "-c"),
        suffixes=(".py",),
        aliases=("python3", "py"),
    ),
    Language(
        name="javascript",
        argv=("node", "-e"),
        suffixes=(".js", ".mjs", ".cjs"),
        aliases=("node", "js"),
    ),
    Language(
        name="bash",
        argv=("bash", "-c"),
        suffixes=(".sh", ".bash"),
        aliases=("sh", "shell"),
        argv0="bash",
    ),
)

_BY_NAME: dict[str, Language] = {}
for _lang in LANGUAGES:
    _BY_NAME[_lang.name] = _lang
    for _alias in _lang.aliases:
        _BY_NAME[_alias] = _lang

_BY_SUFFIX: dict[str, Language] = {
    suffix: lang for lang in LANGUAGES for suffix in lang.suffixes
}

#: Every language name and alias a caller may send, for error messages and the
#: frontend's override dropdown.
KNOWN_LANGUAGES: tuple[str, ...] = tuple(lang.name for lang in LANGUAGES)

# ---------------------------------------------------------------------------
# Payload contracts
# ---------------------------------------------------------------------------

#: Columns an incoming AA may carry the source under, best first. ``text`` is
#: what ``Load File`` actually emits for a ``.jl``/``.py`` file, so it has to be
#: in here — the node is useless in the chain it exists for otherwise.
CODE_COLUMNS: tuple[str, ...] = ("code", "text", "content", "source", "val")

#: Columns an incoming AA may carry the file path under.
PATH_COLUMNS: tuple[str, ...] = ("file_path", "filepath", "path", "file", "file_name")

#: Columns an incoming AA may carry the language under.
LANG_COLUMNS: tuple[str, ...] = ("language", "lang")

STATUS_SUCCESS = "SUCCESS"
STATUS_FAILED = "FAILED"
STATUS_TIMEOUT = "TIMEOUT"

#: Where a script's stdout goes in the merged output.
#:
#: ``column``  — into :data:`DEFAULT_STDOUT_COLUMN`, leaving the input untouched.
#:               The default: a script that rewrites its input publishes the new
#:               text without destroying what it was given.
#: ``replace`` — over the column the code was read from, so a downstream node that
#:               reads ``text`` sees the transformed text. The original is still
#:               reachable as the ``code`` metadata column.
#: ``none``    — nowhere; stdout remains only in the ``stdout`` metadata column.
STDOUT_MODE_COLUMN = "column"
STDOUT_MODE_REPLACE = "replace"
STDOUT_MODE_NONE = "none"
STDOUT_MODES: tuple[str, ...] = (
    STDOUT_MODE_COLUMN,
    STDOUT_MODE_REPLACE,
    STDOUT_MODE_NONE,
)

#: Column ``column`` mode writes stdout to.
DEFAULT_STDOUT_COLUMN = "transformed_text"

#: Output AA columns, in emission order.
RESULT_COLUMNS: tuple[str, ...] = (
    "status",
    "language",
    "stdout",
    "stderr",
    "exit_code",
    "execution_time_ms",
    "code",
    "file_path",
)


@dataclass
class ExecInput:
    """The node's input contract, however it arrived.

    Built either from a flat dict (the shape the spec describes) or from an
    incoming AA via :meth:`PolyglotExecNode.from_aa`.
    """

    code: str = ""
    file_path: str = ""
    language: str = ""
    shebang: Optional[str] = None

    #: Row key the code was read from, when it came from an AA. The merged output
    #: hangs its metadata on this row so downstream nodes keep the original
    #: context alongside the results.
    row_key: str = ""

    #: Column the code was read from (``text``, ``code``, …). ``replace`` mode
    #: writes stdout back to this column.
    source_column: str = ""
    args: list[str] = field(default_factory=list)

    @property
    def effective_shebang(self) -> Optional[str]:
        """The declared shebang, or the code's own first line if it has one.

        ``Load File`` does not send a ``shebang`` field, but the file it read
        usually carries one — so read it off the source rather than requiring
        the upstream node to have parsed it.
        """
        if self.shebang:
            return self.shebang
        first = self.code.lstrip().splitlines()[0] if self.code.strip() else ""
        return first if first.startswith("#!") else None


# ---------------------------------------------------------------------------
# The node
# ---------------------------------------------------------------------------


class PolyglotExecNode:
    """Execute a code payload under a local interpreter.

    Args:
        timeout_s: Wall-clock budget per run. The node's only real resource
            guard, so it is deliberately not unbounded.
        max_output_bytes: Cap on the ``stdout``/``stderr`` *returned*. A process
            that floods a pipe is still bounded only by ``timeout_s``, so this
            caps what enters the AA and the response, not what the child may
            buffer.
        which: Binary resolver seam (``shutil.which``); overridden in tests to
            simulate a missing interpreter.
        env: Environment for the child. Defaults to the server's own.
    """

    #: Exit code reported when the interpreter binary is not installed, matching
    #: the shell's "command not found".
    EXIT_NOT_FOUND = 127

    #: Exit code reported when the binary exists but could not be executed.
    EXIT_NOT_EXECUTABLE = 126

    def __init__(
        self,
        *,
        timeout_s: float = 30.0,
        max_output_bytes: int = 256 * 1024,
        which: Callable[[str], Optional[str]] = shutil.which,
        env: Optional[dict[str, str]] = None,
    ) -> None:
        self.timeout_s = timeout_s
        self.max_output_bytes = max_output_bytes
        self._which = which
        self._env = env

    # ── Input adaptation ────────────────────────────────────────────────────

    @staticmethod
    def from_aa(aa: AssocArray) -> ExecInput:
        """Read the input contract out of an incoming AA.

        Takes the **first row** that carries anything usable: an AA emitted by
        ``Load File`` for a text file is a single row, and a multi-row AA (a
        table of scripts, say) executes its first entry rather than refusing.

        Column names are matched case-insensitively and in both snake_case and
        camelCase, because the Dart side speaks camelCase on the wire.
        """

        def norm(col: str) -> str:
            return col.replace("-", "_").lower()

        def pick(record: dict[str, object], names: Sequence[str]) -> str:
            lowered = {norm(k): v for k, v in record.items()}
            for name in names:
                val = lowered.get(name)
                if isinstance(val, str) and val.strip():
                    return val
            return ""

        def pick_named(record, names):
            """`(value, column)` for the first of `names` the record fills."""
            lowered = {norm(k): (k, v) for k, v in record.items()}
            for name in names:
                entry = lowered.get(name)
                if entry and isinstance(entry[1], str) and entry[1].strip():
                    return entry[1], entry[0]
            return "", ""

        for row, record in aa_rows(aa):
            code, code_column = pick_named(record, CODE_COLUMNS)
            path = pick(record, PATH_COLUMNS)
            lang = pick(record, LANG_COLUMNS)
            shebang = pick(record, ("shebang",))
            raw_args = {norm(k): v for k, v in record.items()}.get("args")
            if not (code or path or lang):
                continue
            return ExecInput(
                code=code,
                file_path=path,
                language=lang,
                shebang=shebang or None,
                args=_split_args(raw_args),
                row_key=row,
                source_column=code_column,
            )
        return ExecInput()

    # ── Language resolution ─────────────────────────────────────────────────

    def resolve_language(
        self,
        payload: ExecInput,
        override: str = "",
    ) -> Language:
        """Pick the interpreter for [payload], most explicit source winning.

        Order: an explicit [override] from the node's dropdown, the payload's own
        ``language``, the ``file_path`` extension, then the shebang.

        Raises:
            ValueError: nothing named a language this node can run. The message
                lists what it does know, since the fix is either a dropdown
                choice or a file extension.
        """
        for candidate in (override, payload.language):
            if candidate and candidate.strip().lower() not in ("", "auto"):
                lang = _BY_NAME.get(candidate.strip().lower())
                if lang is None:
                    raise ValueError(
                        f"unsupported language {candidate!r}; "
                        f"known: {', '.join(KNOWN_LANGUAGES)}"
                    )
                return lang

        if payload.file_path:
            suffix = Path(payload.file_path).suffix.lower()
            lang = _BY_SUFFIX.get(suffix)
            if lang is not None:
                return lang

        shebang = payload.effective_shebang
        if shebang:
            # "#!/usr/bin/env julia" / "#!/bin/bash -e" → the last word that
            # names something we know, so both forms resolve.
            for word in reversed(shebang.replace("#!", "").split()):
                lang = _BY_NAME.get(Path(word).name.lower())
                if lang is not None:
                    return lang

        raise ValueError(
            "could not determine the language: no override, no 'language' "
            "column, no known file extension, no shebang"
        )

    # ── Execution ───────────────────────────────────────────────────────────

    async def run(
        self,
        payload: ExecInput | dict[str, Any],
        *,
        override_language: str = "",
        timeout_s: Optional[float] = None,
    ) -> dict[str, Any]:
        """Execute [payload] and return the output contract as a flat dict.

        Never raises for a *code* failure — a snippet that throws, times out or
        names a missing interpreter all come back as a result with a ``status``,
        because a downstream node should be able to read the failure rather than
        infer it from an exception. Only an unresolvable language raises
        :class:`ValueError`, since that is a configuration error with no run to
        report on.
        """
        if isinstance(payload, dict):
            payload = ExecInput(
                code=payload.get("code") or "",
                file_path=payload.get("file_path") or payload.get("filePath") or "",
                language=payload.get("language") or "",
                shebang=payload.get("shebang"),
                args=_split_args(payload.get("args")),
            )

        language = self.resolve_language(payload, override_language)
        budget = self.timeout_s if timeout_s is None else timeout_s

        if not payload.code.strip():
            return self._result(
                status=STATUS_FAILED,
                language=language.name,
                stdout="",
                stderr="no code in the payload",
                exit_code=self.EXIT_NOT_EXECUTABLE,
                elapsed_ms=0.0,
                payload=payload,
            )

        binary = self._which(language.argv[0])
        if binary is None:
            return self._result(
                status=STATUS_FAILED,
                language=language.name,
                stdout="",
                stderr=(
                    f"{language.argv[0]}: not found on PATH — install it to run "
                    f"{language.name} snippets"
                ),
                exit_code=self.EXIT_NOT_FOUND,
                elapsed_ms=0.0,
                payload=payload,
            )

        argv = [
            binary,
            *language.argv[1:],
            payload.code,
            *([language.argv0] if language.argv0 else []),
            *payload.args,
        ]

        # Run beside the source file when we know where it is, so a relative path
        # inside the snippet means what the author meant.
        cwd = None
        if payload.file_path:
            parent = Path(payload.file_path).expanduser().parent
            if parent.is_dir():
                cwd = str(parent)

        started = time.perf_counter()
        try:
            proc = await asyncio.create_subprocess_exec(
                *argv,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=cwd,
                env=self._env,
                # Own session: a timeout can then kill the interpreter *and*
                # anything it spawned, instead of orphaning grandchildren.
                start_new_session=True,
            )
        except OSError as exc:
            return self._result(
                status=STATUS_FAILED,
                language=language.name,
                stdout="",
                stderr=f"could not start {language.argv[0]}: {exc.strerror or exc}",
                exit_code=self.EXIT_NOT_EXECUTABLE,
                elapsed_ms=(time.perf_counter() - started) * 1000,
                payload=payload,
            )

        # Shielded so a timeout does not cancel the read: after killing the
        # process the same task completes with whatever it managed to print,
        # which is usually the most useful part of a hung run.
        communicate = asyncio.ensure_future(proc.communicate())
        status = STATUS_SUCCESS
        try:
            out, err = await asyncio.wait_for(
                asyncio.shield(communicate), timeout=budget
            )
        except (asyncio.TimeoutError, TimeoutError):
            status = STATUS_TIMEOUT
            self._kill(proc)
            out, err = await communicate

        elapsed_ms = (time.perf_counter() - started) * 1000
        exit_code = proc.returncode if proc.returncode is not None else -1
        if status != STATUS_TIMEOUT:
            status = STATUS_SUCCESS if exit_code == 0 else STATUS_FAILED

        stderr = self._decode(err)
        if status == STATUS_TIMEOUT:
            note = f"timed out after {budget:g}s — process killed"
            stderr = f"{stderr}\n{note}" if stderr.strip() else note

        return self._result(
            status=status,
            language=language.name,
            stdout=self._decode(out),
            stderr=stderr,
            exit_code=exit_code,
            elapsed_ms=elapsed_ms,
            payload=payload,
        )

    def _kill(self, proc: asyncio.subprocess.Process) -> None:
        """Kill the child's whole process group, tolerating an already-dead one."""
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except (ProcessLookupError, PermissionError, OSError):
            # Group gone, or no permission (no start_new_session on this
            # platform) — fall back to the process itself.
            try:
                proc.kill()
            except ProcessLookupError:
                pass

    def _decode(self, raw: Optional[bytes]) -> str:
        """Decode child output, replacing bad bytes and capping the length.

        ``errors="replace"``: a snippet may print anything at all, and losing the
        run's output to a UnicodeDecodeError would be the worst possible trade.
        """
        if not raw:
            return ""
        clipped = raw[: self.max_output_bytes]
        text = clipped.decode("utf-8", errors="replace")
        if len(raw) > self.max_output_bytes:
            text += f"\n… truncated at {self.max_output_bytes} bytes"
        return text

    def _result(
        self,
        *,
        status: str,
        language: str,
        stdout: str,
        stderr: str,
        exit_code: int,
        elapsed_ms: float,
        payload: ExecInput,
    ) -> dict[str, Any]:
        return {
            "status": status,
            "language": language,
            "stdout": stdout,
            "stderr": stderr,
            "exit_code": exit_code,
            "execution_time_ms": round(elapsed_ms, 2),
            "code": payload.code,
            "file_path": payload.file_path,
        }

    # ── Output adaptation ───────────────────────────────────────────────────

    @staticmethod
    def to_aa(result: dict[str, Any], row_key: Optional[str] = None) -> AssocArray:
        """The result as a 1×8 AA in sparse triple form.

        One row, one column per contract field, in :data:`RESULT_COLUMNS` order.
        ``exit_code`` stays an int and ``execution_time_ms`` a float — the AA
        value type is ``str | int | float`` precisely so numeric columns need not
        be stringified.
        """
        row = row_key or f"exec:{uuid4().hex[:8]}"
        return AssocArray(
            rows=[row] * len(RESULT_COLUMNS),
            cols=list(RESULT_COLUMNS),
            vals=[result[col] for col in RESULT_COLUMNS],
        )


def merge_result_aa(
    source: Optional[AssocArray],
    result: dict[str, Any],
    *,
    row_key: str = "",
    source_column: str = "",
    stdout_mode: str = STDOUT_MODE_COLUMN,
    stdout_column: str = DEFAULT_STDOUT_COLUMN,
) -> AssocArray:
    """The execution result **merged into** the incoming AA.

    The node used to answer with metadata only, which dropped the caller's payload
    on the floor: a downstream node reading ``text`` found nothing, because the
    output had been replaced rather than extended. Here every input triple survives
    and the metadata is appended to the row the code came from, so one AA carries
    both the original source and what running it produced.

    Row keys are the **input's own**, which is what lets a downstream node line the
    results up against the rows it sent.

    Args:
        source: The incoming AA. When absent or empty the result is the standalone
            metadata row :meth:`PolyglotExecNode.to_aa` produces — a direct
            ``code=`` call has no rows to merge with.
        result: One :meth:`PolyglotExecNode.run` result.
        row_key: Row to hang the metadata on. Defaults to the first row of
            [source], matching the row :meth:`PolyglotExecNode.from_aa` reads.
        source_column: Column the code came from; ``replace`` mode writes there.
        stdout_mode: One of :data:`STDOUT_MODES`.
        stdout_column: Column for ``column`` mode.

    Raises:
        ValueError: [stdout_mode] is not one of :data:`STDOUT_MODES`.
    """
    if stdout_mode not in STDOUT_MODES:
        raise ValueError(
            f"unknown stdout_mode {stdout_mode!r}; known: {', '.join(STDOUT_MODES)}"
        )
    if source is None or not source.cols:
        return PolyglotExecNode.to_aa(result)

    target = row_key or (source.rows[0] if source.rows else f"exec:{uuid4().hex[:8]}")
    stdout = result.get("stdout") or ""

    # What the metadata will occupy on the target row. Collected first so any
    # same-named input cell is replaced rather than duplicated: two triples for one
    # (row, col) is not a cell an AA reader can resolve.
    appended: dict[str, Any] = {col: result[col] for col in RESULT_COLUMNS}
    if stdout.strip():
        if stdout_mode == STDOUT_MODE_COLUMN:
            appended[stdout_column] = stdout
        elif stdout_mode == STDOUT_MODE_REPLACE and source_column:
            appended[source_column] = stdout

    rows: list[str] = []
    cols: list[str] = []
    vals: list[Any] = []

    # Pass 1: every input triple, minus the cells the metadata is about to define.
    for row, col, val in zip(source.rows, source.cols, source.vals):
        if row == target and col in appended:
            continue
        rows.append(row)
        cols.append(col)
        vals.append(val)

    # Pass 2: the metadata, in a stable order — input-shadowing columns first so
    # `text` keeps roughly its original position, then the contract columns.
    extra = [c for c in appended if c not in RESULT_COLUMNS]
    for col in extra + list(RESULT_COLUMNS):
        rows.append(target)
        cols.append(col)
        vals.append(appended[col])

    return AssocArray(rows=rows, cols=cols, vals=vals)


def _split_args(raw: object) -> list[str]:
    """Coerce an ``args`` field to a list of strings.

    Accepts a real list (JSON / dict input) or a comma-delimited string, since an
    AA cell holds one scalar and that is how a list has to travel in one.
    """
    if raw is None:
        return []
    if isinstance(raw, (list, tuple)):
        return [str(a) for a in raw]
    text = str(raw).strip()
    if not text:
        return []
    return [part.strip() for part in text.split(",") if part.strip()]
