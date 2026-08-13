"""Turn a documented AST index into ChatML JSONL for LoRA fine-tuning.

Takes the 7-column index — extracted by ``extract_ast.jl``, documented by a teacher
node — and emits one ChatML training example per documented definition, each
serialised to a single JSON line.

The output is a **2-column** Arrow table: ``json_line`` and ``symbol_name``. Keeping
the symbol alongside its line means a bad example can be traced back to the
definition that produced it without re-parsing the JSON.

Row order is meaningful here in a way it is not elsewhere in this codebase: a JSONL
file is a sequence. Row keys are therefore zero-padded (``line:0007``), so a
consumer that sorts keys lexically — as ``save_aa_csv`` does — still gets the lines
in their original order rather than ``1, 10, 11, 2``.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any, Optional

import pyarrow as pa

from .models import AssocArray

#: The 7 columns this node consumes.
INPUT_COLUMNS: tuple[str, ...] = (
    "symbol_name",
    "kind",
    "file_path",
    "line_range",
    "docstring",
    "raw_code",
    "better_docstring",
)

#: The 2 columns it emits, in order.
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


class JsonlFormatError(ValueError):
    """The input is not the 7-column documented index."""


@dataclass
class JsonlFormatResult:
    """One formatting pass."""

    #: `json_line` / `symbol_name`, as Arrow.
    table: pa.Table

    #: Examples written.
    formatted: int = 0

    #: Rows dropped for having no generated docstring — the expected case for an
    #: index whose teacher node has only covered part of the codebase.
    skipped_no_doc: int = 0

    #: Rows dropped for having no source code. Not in the original contract, but a
    #: training pair whose prompt is an empty code fence teaches nothing.
    skipped_no_code: int = 0

    @property
    def line_count(self) -> int:
        return self.table.num_rows

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


def to_json_line(example: dict[str, Any]) -> str:
    """Serialise [example] to exactly one line.

    ``json.dumps`` escapes every newline in the content as ``\\n``, which is what
    makes one example one line — the invariant the whole format rests on.

    ``ensure_ascii=False`` keeps the source's own characters: Julia code is full of
    unicode operators (``∘``, ``≈``, ``∈``) and mangling them into ``\\uXXXX``
    escapes would train the model on text that does not look like the corpus.
    Separators are compact because nothing reads these lines by eye.
    """
    return json.dumps(example, ensure_ascii=False, separators=(",", ":"))


def _records_from_table(table: pa.Table) -> list[dict[str, Any]]:
    """Row-wise view of [table], validating the schema first."""
    missing = [name for name in INPUT_COLUMNS if name not in table.column_names]
    if missing:
        raise JsonlFormatError(
            f"input is missing the {missing} column(s); expected the 7-column "
            f"documented index {INPUT_COLUMNS}"
        )
    return table.select(list(INPUT_COLUMNS)).to_pylist()


def _text(value: Optional[Any]) -> str:
    """A cell as text, treating null as empty."""
    return "" if value is None else str(value)


class JsonlFormatterNode:
    """Format a documented index into ChatML JSONL.

    Stateless; instantiated per call so a future variant can carry its own prompt
    templates without threading them through every function.
    """

    def __init__(
        self,
        *,
        system_prompt: str = SYSTEM_PROMPT,
        user_template: str = USER_TEMPLATE,
        assistant_template: str = ASSISTANT_TEMPLATE,
    ) -> None:
        self.system_prompt = system_prompt
        self.user_template = user_template
        self.assistant_template = assistant_template

    def example_for(self, raw_code: str, better_docstring: str) -> dict[str, Any]:
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

    def format_table(self, table: pa.Table) -> JsonlFormatResult:
        """Format every documented row of [table].

        Rows whose ``better_docstring`` is null, empty or whitespace are dropped —
        an index straight from the extractor is entirely empty in that column, and
        a teacher node fills it in a few rows at a time.

        Raises:
            JsonlFormatError: [table] is not the 7-column index.
        """
        records = _records_from_table(table)

        lines: list[str] = []
        symbols: list[str] = []
        skipped_no_doc = 0
        skipped_no_code = 0

        for record in records:
            doc = _text(record.get("better_docstring"))
            code = _text(record.get("raw_code"))
            if not doc.strip():
                skipped_no_doc += 1
                continue
            if not code.strip():
                skipped_no_code += 1
                continue
            lines.append(to_json_line(self.example_for(code, doc)))
            symbols.append(_text(record.get("symbol_name")))

        out = pa.table(
            {
                "json_line": pa.array(lines, type=pa.string()),
                "symbol_name": pa.array(symbols, type=pa.string()),
            }
        )
        out = out.replace_schema_metadata(
            {
                "dn_schema": "jsonl_chatml_v1",
                "dn_line_count": str(len(lines)),
                "dn_skipped_no_doc": str(skipped_no_doc),
                "dn_skipped_no_code": str(skipped_no_code),
            }
        )
        return JsonlFormatResult(
            table=out,
            formatted=len(lines),
            skipped_no_doc=skipped_no_doc,
            skipped_no_code=skipped_no_code,
        )

    def format_aa(self, aa: AssocArray) -> JsonlFormatResult:
        """Same, for the wire AA the canvas speaks (sparse triples)."""
        return self.format_table(table_from_aa(aa))


def table_from_aa(aa: AssocArray) -> pa.Table:
    """Rebuild the 7-column table from an AA in sparse triple form.

    The canvas transports AAs as JSON triples, so a payload arriving from a node
    has to be regrouped into records before it can be treated as a table. Row
    order follows first appearance, which is the order the producer emitted.
    """
    order: list[str] = []
    records: dict[str, dict[str, Any]] = {}
    for row, col, val in zip(aa.rows, aa.cols, aa.vals):
        if row not in records:
            records[row] = {}
            order.append(row)
        records[row][col] = val

    columns: dict[str, list[str]] = {name: [] for name in INPUT_COLUMNS}
    for row in order:
        record = records[row]
        for name in INPUT_COLUMNS:
            columns[name].append(_text(record.get(name)))

    return pa.table({name: pa.array(values, type=pa.string()) for name, values in columns.items()})


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
