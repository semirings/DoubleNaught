"""The one place JSONL training lines are built.

`JsonlFormatterNode` takes an AA — the documented AST index, chunked passages, or
anything else on the graph — and emits one JSON object per row as a **2-column**
table: ``json_line`` and ``symbol_name``. What goes into each line is chosen by
``format_mode``:

``chatml`` (default)
    Code and docstrings. Reads ``raw_code`` and ``better_docstring`` and produces
    a three-message ChatML example. Rows missing either are dropped.

``prompt_completion``
    The classic fine-tuning pair. Reads ``prompt`` / ``input`` / ``source`` and
    ``completion`` / ``target`` / ``output``.

``passthrough`` (alias ``row_dict``)
    Every non-empty cell in the row becomes a key in one JSON object.

``instruction_completion`` and ``continuation`` are the two formats the deprecated
``AA2JSONLNode`` offered. They live here so that route builds its lines with this
code rather than its own — consolidating the logic was the point — and they are not
offered in the node's dropdown.

Row order is meaningful in a way it is not elsewhere in this codebase: a JSONL file
is a sequence. Row keys are zero-padded (``line:0007``) so a consumer that sorts
keys lexically still gets the lines in order rather than ``1, 10, 11, 2``.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any, Optional, Sequence

import pyarrow as pa

from .models import AssocArray

#: The columns the ``chatml`` mode needs.
CHATML_COLUMNS: tuple[str, ...] = ("raw_code", "better_docstring")

#: The full documented index, for callers that want to name it.
INPUT_COLUMNS: tuple[str, ...] = (
    "symbol_name",
    "kind",
    "file_path",
    "line_range",
    "docstring",
    "raw_code",
    "better_docstring",
)

#: The 2 columns emitted, in order. ``json_line`` is the unified name — the
#: deprecated AA2JSONL node's ``jsonl_line`` is accepted by readers but never
#: written here.
OUTPUT_COLUMNS: tuple[str, ...] = ("json_line", "symbol_name")

SYSTEM_PROMPT = (
    "You are an expert Julia documentation assistant. Given Julia source code, "
    "write comprehensive, idiomatic Documenter.jl docstrings including parameter "
    "descriptions and jldoctest blocks."
)

USER_TEMPLATE = (
    "Write a Documenter.jl docstring for the following Julia definition:\n\n"
    "```julia\n{code}\n```"
)

#: Docstring first, then the code it documents — the shape the fine-tune is being
#: taught to produce.
ASSISTANT_TEMPLATE = "{doc}\n\n{code}"

#: The prompt AA2JSONL's "instruction-completion" format synthesised, kept so the
#: deprecated route's output is unchanged.
LEGACY_INSTRUCTION_PROMPT = "Write in the GCC voice:"

# Column aliases, first match wins.
PROMPT_COLUMNS: tuple[str, ...] = ("prompt", "input", "source", "instruction")
COMPLETION_COLUMNS: tuple[str, ...] = (
    "completion",
    "target",
    "output",
    "text",
    "raw_text",
)
TEXT_COLUMNS: tuple[str, ...] = ("text", "raw_text")
SYMBOL_COLUMNS: tuple[str, ...] = ("symbol_name", "symbol", "name")

MODE_CHATML = "chatml"
MODE_PROMPT_COMPLETION = "prompt_completion"
MODE_PASSTHROUGH = "passthrough"
MODE_INSTRUCTION_COMPLETION = "instruction_completion"
MODE_CONTINUATION = "continuation"

#: Modes offered on the canvas, in dropdown order.
PUBLIC_MODES: tuple[str, ...] = (
    MODE_CHATML,
    MODE_PROMPT_COMPLETION,
    MODE_PASSTHROUGH,
)

#: Every accepted spelling → canonical mode. Hyphens and camelCase are tolerated
#: because these names travel through a URL, a JSON body and a Dart enum.
MODE_ALIASES: dict[str, str] = {
    "chatml": MODE_CHATML,
    "chat_ml": MODE_CHATML,
    "prompt_completion": MODE_PROMPT_COMPLETION,
    "promptcompletion": MODE_PROMPT_COMPLETION,
    "passthrough": MODE_PASSTHROUGH,
    "row_dict": MODE_PASSTHROUGH,
    "rowdict": MODE_PASSTHROUGH,
    "instruction_completion": MODE_INSTRUCTION_COMPLETION,
    "instructioncompletion": MODE_INSTRUCTION_COMPLETION,
    "continuation": MODE_CONTINUATION,
}


class JsonlFormatError(ValueError):
    """The input does not carry what the chosen mode needs, or the mode is unknown."""


def normalise_mode(mode: Optional[str]) -> str:
    """Canonical mode name for [mode], defaulting to ``chatml``.

    Raises:
        JsonlFormatError: the name matches nothing, listing what is accepted.
    """
    if mode is None or not str(mode).strip():
        return MODE_CHATML
    key = str(mode).strip().lower().replace("-", "_").replace(" ", "_")
    canonical = MODE_ALIASES.get(key) or MODE_ALIASES.get(key.replace("_", ""))
    if canonical is None:
        raise JsonlFormatError(
            f"unknown format_mode {mode!r}; known modes: "
            f"{', '.join(sorted(set(MODE_ALIASES.values())))}"
        )
    return canonical


@dataclass
class JsonlFormatResult:
    """One formatting pass."""

    #: `json_line` / `symbol_name`, as Arrow.
    table: pa.Table

    #: The mode that produced it, canonicalised.
    mode: str = MODE_CHATML

    #: Examples written.
    formatted: int = 0

    #: `chatml`: rows with no generated docstring — the expected case for an index
    #: whose teacher node has only covered part of the codebase.
    skipped_no_doc: int = 0

    #: `chatml`: rows with a docstring but no code. Not in the original contract,
    #: but a training pair whose prompt is an empty code fence teaches nothing.
    skipped_no_code: int = 0

    #: Other modes: rows lacking the fields the mode needs.
    skipped_incomplete: int = 0

    @property
    def line_count(self) -> int:
        return self.table.num_rows

    @property
    def skipped_total(self) -> int:
        return self.skipped_no_doc + self.skipped_no_code + self.skipped_incomplete

    def as_text(self) -> str:
        """The whole file: every line joined by newline, with a trailing newline."""
        lines = self.table.column("json_line").to_pylist()
        return "".join(f"{line}\n" for line in lines)


def chatml_example(raw_code: str, better_docstring: str) -> dict[str, Any]:
    """The ChatML object for one definition."""
    return {
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": USER_TEMPLATE.format(code=raw_code)},
            {
                "role": "assistant",
                "content": ASSISTANT_TEMPLATE.format(
                    doc=better_docstring, code=raw_code
                ),
            },
        ]
    }


def to_json_line(example: Any) -> str:
    """Serialise [example] to exactly one line.

    ``json.dumps`` escapes every newline in the content as ``\\n``, which is what
    makes one example one line — the invariant the whole format rests on.

    ``ensure_ascii=False`` keeps the source's own characters: Julia code is full of
    unicode operators (``∘``, ``≈``, ``∈``) and mangling them into ``\\uXXXX``
    escapes would train the model on text that does not look like the corpus.
    Separators are compact because nothing reads these lines by eye.
    """
    return json.dumps(example, ensure_ascii=False, separators=(",", ":"))


def _text(value: Optional[Any]) -> str:
    """A cell as text, treating null as empty."""
    return "" if value is None else str(value)


def _pick(record: dict[str, Any], names: Sequence[str]) -> str:
    """First non-empty value among [names], matched case-insensitively."""
    lowered = {str(key).replace("-", "_").lower(): value for key, value in record.items()}
    for name in names:
        value = _text(lowered.get(name))
        if value.strip():
            return value
    return ""


class JsonlFormatterNode:
    """Format an AA into JSONL training lines.

    Args:
        format_mode: One of :data:`MODE_ALIASES`. Defaults to ``chatml``.
        system_prompt / user_template / assistant_template: ChatML overrides.
        default_prompt: Used by ``prompt_completion`` when a row has no prompt
            column — which is how the deprecated ``instruction_completion`` format
            is expressed as a special case of it rather than as its own code path.
    """

    def __init__(
        self,
        *,
        format_mode: Optional[str] = None,
        system_prompt: str = SYSTEM_PROMPT,
        user_template: str = USER_TEMPLATE,
        assistant_template: str = ASSISTANT_TEMPLATE,
        default_prompt: str = "",
    ) -> None:
        self.mode = normalise_mode(format_mode)
        self.system_prompt = system_prompt
        self.user_template = user_template
        self.assistant_template = assistant_template
        self.default_prompt = default_prompt

    # ── Line construction, one method per mode ──────────────────────────────

    def example_for(self, raw_code: str, better_docstring: str) -> dict[str, Any]:
        """The ChatML object, honouring this instance's templates."""
        return {
            "messages": [
                {"role": "system", "content": self.system_prompt},
                {"role": "user", "content": self.user_template.format(code=raw_code)},
                {
                    "role": "assistant",
                    "content": self.assistant_template.format(
                        doc=better_docstring, code=raw_code
                    ),
                },
            ]
        }

    def _chatml_object(self, record: dict[str, Any]) -> tuple[Optional[Any], str]:
        """`(object, skip_reason)` — skip_reason is `""` when the row is usable."""
        doc = _pick(record, ("better_docstring", "betterdocstring"))
        code = _pick(record, ("raw_code", "rawcode", "code", "source"))
        if not doc.strip():
            return None, "no_doc"
        if not code.strip():
            return None, "no_code"
        return self.example_for(code, doc), ""

    def _prompt_completion_object(
        self, record: dict[str, Any]
    ) -> tuple[Optional[Any], str]:
        prompt = _pick(record, PROMPT_COLUMNS) or self.default_prompt
        completion = _pick(record, COMPLETION_COLUMNS)
        if not completion.strip() or not prompt.strip():
            return None, "incomplete"
        return {"prompt": prompt, "completion": completion}, ""

    def _continuation_object(self, record: dict[str, Any]) -> tuple[Optional[Any], str]:
        text = _pick(record, COMPLETION_COLUMNS)
        if not text.strip():
            return None, "incomplete"
        return {"text": text}, ""

    def _passthrough_object(self, record: dict[str, Any]) -> tuple[Optional[Any], str]:
        """Every non-empty cell, as one object.

        Nulls and empty strings are dropped rather than emitted as `null`: a sparse
        AA would otherwise produce lines full of placeholders for columns that row
        never had.
        """
        obj = {
            str(key): value
            for key, value in record.items()
            if value is not None and _text(value) != ""
        }
        return (obj, "") if obj else (None, "incomplete")

    def _object_for(self, record: dict[str, Any]) -> tuple[Optional[Any], str]:
        if self.mode == MODE_CHATML:
            return self._chatml_object(record)
        if self.mode in (MODE_PROMPT_COMPLETION, MODE_INSTRUCTION_COMPLETION):
            return self._prompt_completion_object(record)
        if self.mode == MODE_CONTINUATION:
            return self._continuation_object(record)
        return self._passthrough_object(record)

    # ── Entry points ────────────────────────────────────────────────────────

    def validate(self, table: pa.Table) -> None:
        """Check [table] carries what this mode reads.

        Validation is **per mode**: `chatml` needs the index's code and docstring
        columns, while `passthrough` will take anything with a column in it. A
        single schema check would either reject valid passage AAs or wave through
        an index the ChatML path cannot use.

        Raises:
            JsonlFormatError: the required columns are absent.
        """
        present = {name.replace("-", "_").lower() for name in table.column_names}
        if self.mode == MODE_CHATML:
            missing = [name for name in CHATML_COLUMNS if name not in present]
            if missing:
                raise JsonlFormatError(
                    f"chatml mode is missing the {missing} column(s); it reads "
                    f"{list(CHATML_COLUMNS)} from the documented index"
                )
        elif self.mode in (MODE_PROMPT_COMPLETION, MODE_INSTRUCTION_COMPLETION, MODE_CONTINUATION):
            if not any(name in present for name in COMPLETION_COLUMNS):
                raise JsonlFormatError(
                    f"{self.mode} mode found no completion column; expected one of "
                    f"{list(COMPLETION_COLUMNS)}"
                )
        elif not table.column_names:
            raise JsonlFormatError("passthrough mode needs at least one column")

    def format_table(self, table: pa.Table) -> JsonlFormatResult:
        """Format every usable row of [table].

        Rows the mode cannot use are dropped and counted, not raised on: an index
        straight from the extractor has no generated docstrings at all, and a
        teacher node fills them in a few rows at a time.

        Raises:
            JsonlFormatError: [table] does not carry the columns this mode reads.
        """
        self.validate(table)
        records = table.to_pylist()

        lines: list[str] = []
        symbols: list[str] = []
        counts = {"no_doc": 0, "no_code": 0, "incomplete": 0}

        for index, record in enumerate(records):
            obj, skip = self._object_for(record)
            if obj is None:
                counts[skip] = counts.get(skip, 0) + 1
                continue
            lines.append(to_json_line(obj))
            # Traceability: the symbol when the AA names one, else the row's
            # position, so a bad line can always be found again.
            symbols.append(_pick(record, SYMBOL_COLUMNS) or str(index))

        out = pa.table(
            {
                "json_line": pa.array(lines, type=pa.string()),
                "symbol_name": pa.array(symbols, type=pa.string()),
            }
        )
        out = out.replace_schema_metadata(
            {
                "dn_schema": "jsonl_lines_v1",
                "dn_format_mode": self.mode,
                "dn_line_count": str(len(lines)),
                "dn_skipped_no_doc": str(counts["no_doc"]),
                "dn_skipped_no_code": str(counts["no_code"]),
                "dn_skipped_incomplete": str(counts["incomplete"]),
            }
        )
        return JsonlFormatResult(
            table=out,
            mode=self.mode,
            formatted=len(lines),
            skipped_no_doc=counts["no_doc"],
            skipped_no_code=counts["no_code"],
            skipped_incomplete=counts["incomplete"],
        )

    def format_aa(self, aa: AssocArray) -> JsonlFormatResult:
        """Same, for the wire AA the canvas speaks (sparse triples)."""
        return self.format_table(table_from_aa(aa))

    def line_for(self, record: dict[str, Any]) -> Optional[str]:
        """One record's line, or None when the mode cannot use it.

        The seam the deprecated ``/aa2jsonl`` route builds its lines through, so
        there is exactly one implementation of each format.
        """
        obj, _skip = self._object_for(record)
        return None if obj is None else to_json_line(obj)


def table_from_aa(aa: AssocArray, columns: Optional[Sequence[str]] = None) -> pa.Table:
    """Rebuild a table from an AA in sparse triple form.

    Columns default to whatever the payload actually carries, in first-appearance
    order — the node now accepts passage AAs and arbitrary rows, not just the
    7-column index, so forcing a fixed schema would drop their data. Pass
    [columns] to pin a specific set.

    Row order follows first appearance, which is the order the producer emitted.
    """
    order: list[str] = []
    records: dict[str, dict[str, Any]] = {}
    column_order: list[str] = []
    for row, col, val in zip(aa.rows, aa.cols, aa.vals):
        if row not in records:
            records[row] = {}
            order.append(row)
        if col not in column_order:
            column_order.append(col)
        records[row][col] = val

    names = list(columns) if columns is not None else column_order
    built: dict[str, list[str]] = {name: [] for name in names}
    for row in order:
        record = records[row]
        for name in names:
            built[name].append(_text(record.get(name)))

    if not names:
        # An empty AA still has to produce a table with rows, or every row is lost.
        return pa.table({})
    return pa.table({name: pa.array(values, type=pa.string()) for name, values in built.items()})


def aa_from_table(table: pa.Table) -> AssocArray:
    """The 2-column output as a wire AA.

    Row keys are ``line:0001``-style so that a consumer sorting keys lexically
    keeps the lines in order; the JSONL saver relies on appearance order instead,
    but nothing else in the codebase promises to.
    """
    lines = table.column("json_line").to_pylist()
    symbols = table.column("symbol_name").to_pylist()
    width = max(4, len(str(len(lines))))

    rows: list[str] = []
    cols: list[str] = []
    vals: list[Any] = []
    for index, (line, symbol) in enumerate(zip(lines, symbols)):
        key = f"line:{index:0{width}d}"
        rows.extend([key, key])
        cols.extend(["json_line", "symbol_name"])
        vals.extend([line, symbol])

    return AssocArray(rows=rows, cols=cols, vals=vals)
