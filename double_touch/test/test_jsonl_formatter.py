"""Tests for the ChatML JSONL formatter and the Save File JSONL extension."""

from __future__ import annotations

import json

import pyarrow as pa
import pytest
from fastapi.testclient import TestClient

from double_touch.app import app
from double_touch.ast_extract import read_arrow_table, to_arrow_bytes
from double_touch.jsonl_formatter_node import (
    INPUT_COLUMNS,
    LEGACY_INSTRUCTION_PROMPT,
    OUTPUT_COLUMNS,
    SYSTEM_PROMPT,
    JsonlFormatError,
    JsonlFormatterNode,
    aa_from_table,
    normalise_mode,
    table_from_aa,
    to_json_line,
)
from double_touch.models import AssocArray
from double_touch.save_file import aa_has_jsonl, save_aa_jsonl

client = TestClient(app)


def index_table(rows: list[dict[str, str]]) -> pa.Table:
    """A 7-column index table from partial row dicts."""
    columns = {
        name: pa.array([row.get(name, "") for row in rows], type=pa.string())
        for name in INPUT_COLUMNS
    }
    return pa.table(columns)


ONE_ROW = [
    {
        "symbol_name": "add_one",
        "kind": "function",
        "file_path": "src/core.jl",
        "line_range": "4:6",
        "docstring": "",
        "raw_code": "function add_one(x)\n    x + 1\nend",
        "better_docstring": "Adds one to `x`.\n\nReturns `x + 1`.",
    }
]


# --- Formatting -------------------------------------------------------------


def test_emits_two_string_columns_in_order():
    result = JsonlFormatterNode().format_table(index_table(ONE_ROW))

    assert tuple(result.table.column_names) == OUTPUT_COLUMNS
    assert all(pa.types.is_string(field.type) for field in result.table.schema)
    assert result.line_count == 1
    assert result.table.column("symbol_name").to_pylist() == ["add_one"]


def test_the_chatml_object_has_the_specified_three_messages():
    result = JsonlFormatterNode().format_table(index_table(ONE_ROW))
    example = json.loads(result.table.column("json_line")[0].as_py())

    roles = [message["role"] for message in example["messages"]]
    assert roles == ["system", "user", "assistant"]
    assert example["messages"][0]["content"] == SYSTEM_PROMPT

    user = example["messages"][1]["content"]
    assert user.startswith("Write a Documenter.jl docstring for the following Julia definition:")
    # The code is fenced as julia.
    assert "```julia\nfunction add_one(x)\n    x + 1\nend\n```" in user

    # Assistant: the docstring, a blank line, then the code.
    assistant = example["messages"][2]["content"]
    assert assistant == "Adds one to `x`.\n\nReturns `x + 1`.\n\nfunction add_one(x)\n    x + 1\nend"


def test_every_line_is_exactly_one_line():
    """The invariant the format rests on: newlines are escaped, never literal."""
    result = JsonlFormatterNode().format_table(index_table(ONE_ROW * 3))

    for line in result.table.column("json_line").to_pylist():
        assert "\n" not in line
        assert "\r" not in line
        # And still parses back to the original text.
        example = json.loads(line)
        assert "\n" in example["messages"][2]["content"], "newlines survive as data"


def test_rows_without_a_generated_docstring_are_dropped():
    rows = [
        dict(ONE_ROW[0], symbol_name="kept"),
        dict(ONE_ROW[0], symbol_name="empty", better_docstring=""),
        dict(ONE_ROW[0], symbol_name="blank", better_docstring="   \n  "),
    ]
    result = JsonlFormatterNode().format_table(index_table(rows))

    assert result.table.column("symbol_name").to_pylist() == ["kept"]
    assert result.skipped_no_doc == 2
    assert result.formatted == 1


def test_null_docstrings_are_treated_as_empty():
    """A null column is what a table built outside this pipeline may carry."""
    table = pa.table(
        {
            name: pa.array(
                [None] if name == "better_docstring" else ["x"], type=pa.string()
            )
            for name in INPUT_COLUMNS
        }
    )
    result = JsonlFormatterNode().format_table(table)
    assert result.line_count == 0
    assert result.skipped_no_doc == 1


def test_rows_with_a_docstring_but_no_code_are_dropped_and_counted():
    """Not in the original contract: a prompt with an empty code fence teaches
    nothing, so it is reported rather than written."""
    rows = [dict(ONE_ROW[0], symbol_name="no_code", raw_code="")]
    result = JsonlFormatterNode().format_table(index_table(rows))

    assert result.line_count == 0
    assert result.skipped_no_code == 1
    assert result.skipped_no_doc == 0


def test_input_order_is_preserved():
    rows = [dict(ONE_ROW[0], symbol_name=f"f{i}") for i in range(5)]
    result = JsonlFormatterNode().format_table(index_table(rows))
    assert result.table.column("symbol_name").to_pylist() == [f"f{i}" for i in range(5)]


def test_an_empty_index_yields_an_empty_table_with_the_schema():
    result = JsonlFormatterNode().format_table(index_table([]))
    assert result.line_count == 0
    assert tuple(result.table.column_names) == OUTPUT_COLUMNS


def test_chatml_refuses_a_table_without_code_and_docstring_columns():
    with pytest.raises(JsonlFormatError, match="chatml mode is missing"):
        JsonlFormatterNode().format_table(pa.table({"symbol_name": ["f"]}))


def test_quotes_backslashes_and_unicode_survive_the_round_trip():
    rows = [
        dict(
            ONE_ROW[0],
            raw_code='f(x) = "quoted \\ backslash"\ng(∘) = ∘ ≈ 1',
            better_docstring='Says "hi" with \\alpha and ∘.',
        )
    ]
    result = JsonlFormatterNode().format_table(index_table(rows))
    line = result.table.column("json_line")[0].as_py()
    example = json.loads(line)

    assert 'Says "hi" with \\alpha and ∘.' in example["messages"][2]["content"]
    assert "g(∘) = ∘ ≈ 1" in example["messages"][1]["content"]
    # Unicode is kept as itself rather than \uXXXX-escaped.
    assert "∘" in line


def test_metadata_records_the_counts():
    rows = [ONE_ROW[0], dict(ONE_ROW[0], better_docstring="")]
    result = JsonlFormatterNode().format_table(index_table(rows))
    metadata = {k.decode(): v.decode() for k, v in result.table.schema.metadata.items()}

    assert metadata["dn_schema"] == "jsonl_lines_v1"
    assert metadata["dn_format_mode"] == "chatml"
    assert metadata["dn_line_count"] == "1"
    assert metadata["dn_skipped_no_doc"] == "1"


def test_as_text_is_a_complete_jsonl_file():
    result = JsonlFormatterNode().format_table(index_table(ONE_ROW * 2))
    text = result.as_text()

    assert text.endswith("\n")
    lines = text.splitlines()
    assert len(lines) == 2
    assert all(json.loads(line) for line in lines)


def test_prompt_templates_can_be_overridden():
    node = JsonlFormatterNode(system_prompt="Custom system.")
    result = node.format_table(index_table(ONE_ROW))
    example = json.loads(result.table.column("json_line")[0].as_py())
    assert example["messages"][0]["content"] == "Custom system."


def test_to_json_line_is_compact_and_single_line():
    line = to_json_line({"messages": [{"role": "user", "content": "a\nb"}]})
    assert line == '{"messages":[{"role":"user","content":"a\\nb"}]}'


# --- AA conversion (the canvas path) ----------------------------------------


def test_table_from_aa_regroups_triples_into_records():
    aa = AssocArray(
        rows=["r1", "r1", "r1", "r2", "r2", "r2"],
        cols=["symbol_name", "raw_code", "better_docstring"] * 2,
        vals=["f", "f(x) = x", "Docs for f", "g", "g(y) = y", ""],
    )
    table = table_from_aa(aa)

    # Whatever the payload carries, in first-appearance order — the node now takes
    # passage AAs and arbitrary rows too, so a fixed schema would drop their data.
    assert tuple(table.column_names) == ("symbol_name", "raw_code", "better_docstring")
    assert table.num_rows == 2
    assert table.column("symbol_name").to_pylist() == ["f", "g"]


def test_table_from_aa_can_be_pinned_to_a_column_set():
    aa = AssocArray(rows=["r1"], cols=["raw_code"], vals=["f(x) = x"])
    table = table_from_aa(aa, columns=INPUT_COLUMNS)

    assert tuple(table.column_names) == INPUT_COLUMNS
    # Absent columns are filled with empty strings, not nulls.
    assert table.column("file_path").to_pylist() == [""]


def test_aa_from_table_pads_row_keys_so_lexical_order_matches_line_order():
    """`line:2` must not sort before `line:10` — some consumers sort keys."""
    rows = [dict(ONE_ROW[0], symbol_name=f"f{i}") for i in range(12)]
    result = JsonlFormatterNode().format_table(index_table(rows))
    aa = aa_from_table(result.table)

    keys = [key for key in aa.rows if key.endswith("0") or True][::2]
    assert keys[:3] == ["line:0000", "line:0001", "line:0002"]
    assert sorted(set(aa.rows)) == list(dict.fromkeys(aa.rows)), "lexical == emitted"
    assert set(aa.cols) == {"json_line", "symbol_name"}


def test_format_aa_end_to_end_over_the_wire_shape():
    aa = AssocArray(
        rows=["r1", "r1"],
        cols=["raw_code", "better_docstring"],
        vals=["f(x) = x", "Docs for f."],
    )
    result = JsonlFormatterNode().format_aa(aa)
    assert result.line_count == 1
    assert json.loads(result.table.column("json_line")[0].as_py())["messages"]


# --- Save File extension ----------------------------------------------------


def test_aa_has_jsonl_detects_the_column():
    assert aa_has_jsonl(AssocArray(rows=["a"], cols=["json_line"], vals=["{}"]))
    assert not aa_has_jsonl(AssocArray(rows=["a"], cols=["text"], vals=["x"]))


def test_save_aa_jsonl_writes_one_line_per_entry(tmp_path, monkeypatch):
    monkeypatch.setattr("double_touch.save_file.storage_out_dir", lambda: tmp_path)
    aa = AssocArray(
        rows=["line:0000", "line:0000", "line:0001", "line:0001"],
        cols=["json_line", "symbol_name", "json_line", "symbol_name"],
        vals=['{"a":1}', "f", '{"b":2}', "g"],
    )

    out = save_aa_jsonl(aa, "train")

    assert out.name == "train.jsonl"
    assert out.read_text() == '{"a":1}\n{"b":2}\n'
    # Every line is valid JSON.
    assert [json.loads(line) for line in out.read_text().splitlines()] == [
        {"a": 1},
        {"b": 2},
    ]


def test_save_aa_jsonl_keeps_appearance_order_not_sorted_keys(tmp_path, monkeypatch):
    """Sorted keys would put `line:10` before `line:2` and scramble the file."""
    monkeypatch.setattr("double_touch.save_file.storage_out_dir", lambda: tmp_path)
    aa = AssocArray(
        rows=["line:2", "line:10"],
        cols=["json_line", "json_line"],
        vals=['{"second":true}', '{"tenth":true}'],
    )

    out = save_aa_jsonl(aa, "order")
    assert out.read_text() == '{"second":true}\n{"tenth":true}\n'


def test_save_aa_jsonl_refuses_an_aa_without_the_column(tmp_path, monkeypatch):
    monkeypatch.setattr("double_touch.save_file.storage_out_dir", lambda: tmp_path)
    aa = AssocArray(rows=["a"], cols=["text"], vals=["hello"])
    with pytest.raises(ValueError, match="no 'json_line' column"):
        save_aa_jsonl(aa, "nope")


def test_save_aa_jsonl_refuses_a_line_containing_a_newline(tmp_path, monkeypatch):
    """It would silently become two records."""
    monkeypatch.setattr("double_touch.save_file.storage_out_dir", lambda: tmp_path)
    aa = AssocArray(rows=["a"], cols=["json_line"], vals=['{"a":"x\ny"}'])
    with pytest.raises(ValueError, match="literal newline"):
        save_aa_jsonl(aa, "broken")


def test_save_route_writes_jsonl_from_a_formatted_aa(tmp_path, monkeypatch):
    monkeypatch.setattr("double_touch.save_file.storage_out_dir", lambda: tmp_path)
    result = JsonlFormatterNode().format_table(index_table(ONE_ROW * 2))
    aa = aa_from_table(result.table)

    response = client.post(
        "/save",
        json={
            "dataToSave": {"rows": aa.rows, "cols": aa.cols, "vals": aa.vals},
            "filename": "phi4_train",
            "format": "jsonl",
        },
    )

    assert response.status_code == 200, response.text
    written = tmp_path / "phi4_train.jsonl"
    assert written.is_file()
    assert len(written.read_text().splitlines()) == 2
    assert response.json()["bytesWritten"] == written.stat().st_size


def test_save_route_infers_jsonl_from_a_filename(tmp_path, monkeypatch):
    """A `.jsonl` filename on an AA that carries the column is enough."""
    monkeypatch.setattr("double_touch.save_file.storage_out_dir", lambda: tmp_path)
    aa = aa_from_table(JsonlFormatterNode().format_table(index_table(ONE_ROW)).table)

    response = client.post(
        "/save",
        json={
            "dataToSave": {"rows": aa.rows, "cols": aa.cols, "vals": aa.vals},
            "filename": "inferred.jsonl",
            "format": "parquet",
        },
    )

    assert response.status_code == 200, response.text
    assert (tmp_path / "inferred.jsonl").is_file()


# --- Routes -----------------------------------------------------------------


def test_arrow_route_returns_the_two_column_table():
    body = to_arrow_bytes(index_table(ONE_ROW * 3 + [dict(ONE_ROW[0], better_docstring="")]))

    response = client.post(
        "/jsonl/format",
        content=body,
        headers={"Content-Type": "application/vnd.apache.arrow.file"},
    )

    assert response.status_code == 200
    assert response.headers["content-type"] == "application/vnd.apache.arrow.file"
    assert response.headers["X-Dn-Line-Count"] == "3"
    assert response.headers["X-Dn-Skipped-No-Doc"] == "1"

    table = read_arrow_table(response.content)
    assert tuple(table.column_names) == OUTPUT_COLUMNS
    assert table.num_rows == 3


def test_arrow_route_rejects_an_empty_body():
    response = client.post("/jsonl/format", content=b"")
    assert response.status_code == 422
    assert "Arrow IPC bytes" in response.json()["detail"]


def test_arrow_route_rejects_a_table_that_is_not_the_index():
    response = client.post(
        "/jsonl/format",
        content=to_arrow_bytes(pa.table({"nope": ["x"]})),
        headers={"Content-Type": "application/vnd.apache.arrow.file"},
    )
    assert response.status_code == 422
    assert "missing" in response.json()["detail"]


def test_aa_route_returns_a_wire_aa_and_counts():
    response = client.post(
        "/jsonl/format/aa",
        json={
            "astIndex": {
                "rows": ["r1", "r1", "r2", "r2"],
                "cols": ["raw_code", "better_docstring", "raw_code", "better_docstring"],
                "vals": ["f(x) = x", "Docs.", "g(y) = y", ""],
            }
        },
    )

    assert response.status_code == 200
    body = response.json()
    assert body["lineCount"] == 1
    assert body["skippedNoDoc"] == 1
    assert body["skippedNoCode"] == 0
    assert set(body["jsonlLines"]["cols"]) == {"json_line", "symbol_name"}
    # And the line is real ChatML.
    line = body["jsonlLines"]["vals"][body["jsonlLines"]["cols"].index("json_line")]
    assert json.loads(line)["messages"][0]["role"] == "system"


def test_aa_route_on_an_undocumented_index_returns_zero_lines_not_an_error():
    response = client.post(
        "/jsonl/format/aa",
        json={
            "astIndex": {
                "rows": ["r1", "r1"],
                "cols": ["raw_code", "better_docstring"],
                "vals": ["f(x) = x", ""],
            }
        },
    )
    assert response.status_code == 200
    assert response.json()["lineCount"] == 0


# --- Format modes ------------------------------------------------------------


def test_mode_defaults_to_chatml_and_is_recorded():
    result = JsonlFormatterNode().format_table(index_table(ONE_ROW))
    assert result.mode == "chatml"


@pytest.mark.parametrize(
    "spelling,expected",
    [
        ("chatml", "chatml"),
        ("ChatML", "chatml"),
        ("prompt_completion", "prompt_completion"),
        ("prompt-completion", "prompt_completion"),
        ("passthrough", "passthrough"),
        ("row_dict", "passthrough"),
        ("row-dict", "passthrough"),
        ("", "chatml"),
        (None, "chatml"),
    ],
)
def test_mode_aliases_normalise(spelling, expected):
    assert normalise_mode(spelling) == expected


def test_an_unknown_mode_names_the_known_ones():
    with pytest.raises(JsonlFormatError, match="unknown format_mode"):
        normalise_mode("yaml")


def test_prompt_completion_reads_prompt_and_completion_columns():
    table = pa.table(
        {
            "prompt": ["Explain this:"],
            "completion": ["It adds one."],
            "symbol_name": ["add_one"],
        }
    )
    result = JsonlFormatterNode(format_mode="prompt_completion").format_table(table)

    assert result.line_count == 1
    assert json.loads(result.table.column("json_line")[0].as_py()) == {
        "prompt": "Explain this:",
        "completion": "It adds one.",
    }
    # The symbol still travels beside its line.
    assert result.table.column("symbol_name").to_pylist() == ["add_one"]


@pytest.mark.parametrize(
    "prompt_col,completion_col",
    [("input", "target"), ("source", "output"), ("instruction", "text")],
)
def test_prompt_completion_accepts_the_documented_aliases(prompt_col, completion_col):
    table = pa.table({prompt_col: ["P"], completion_col: ["C"]})
    result = JsonlFormatterNode(format_mode="prompt_completion").format_table(table)
    assert json.loads(result.table.column("json_line")[0].as_py()) == {
        "prompt": "P",
        "completion": "C",
    }


def test_prompt_completion_skips_rows_missing_a_side():
    table = pa.table({"prompt": ["P", "", "P2"], "completion": ["C", "C2", ""]})
    result = JsonlFormatterNode(format_mode="prompt_completion").format_table(table)

    assert result.line_count == 1
    assert result.skipped_incomplete == 2
    assert result.skipped_total == 2


def test_prompt_completion_refuses_a_table_with_no_completion_column():
    with pytest.raises(JsonlFormatError, match="no completion column"):
        JsonlFormatterNode(format_mode="prompt_completion").format_table(
            pa.table({"prompt": ["P"]})
        )


def test_passthrough_turns_each_row_into_one_object():
    table = pa.table(
        {
            "symbol_name": ["f"],
            "kind": ["function"],
            "line_range": ["1:2"],
        }
    )
    result = JsonlFormatterNode(format_mode="passthrough").format_table(table)

    assert json.loads(result.table.column("json_line")[0].as_py()) == {
        "symbol_name": "f",
        "kind": "function",
        "line_range": "1:2",
    }


def test_passthrough_drops_empty_cells_rather_than_emitting_nulls():
    """A sparse AA would otherwise produce lines full of placeholders."""
    table = pa.table({"a": ["1"], "b": [""], "c": [None]})
    result = JsonlFormatterNode(format_mode="passthrough").format_table(table)

    assert json.loads(result.table.column("json_line")[0].as_py()) == {"a": "1"}


def test_passthrough_skips_a_wholly_empty_row():
    table = pa.table({"a": ["1", ""], "b": ["2", ""]})
    result = JsonlFormatterNode(format_mode="passthrough").format_table(table)
    assert result.line_count == 1
    assert result.skipped_incomplete == 1


def test_every_mode_emits_the_unified_column_name():
    """The whole point of the consolidation: one output schema."""
    cases = [
        ("chatml", index_table(ONE_ROW)),
        ("prompt_completion", pa.table({"prompt": ["P"], "completion": ["C"]})),
        ("passthrough", pa.table({"a": ["1"]})),
    ]
    for mode, table in cases:
        result = JsonlFormatterNode(format_mode=mode).format_table(table)
        assert tuple(result.table.column_names) == OUTPUT_COLUMNS, mode
        assert "jsonl_line" not in result.table.column_names, mode


def test_every_mode_produces_single_line_json():
    multiline = "first\nsecond\nthird"
    cases = [
        ("chatml", index_table([dict(ONE_ROW[0], better_docstring=multiline)])),
        ("prompt_completion", pa.table({"prompt": [multiline], "completion": [multiline]})),
        ("passthrough", pa.table({"a": [multiline]})),
    ]
    for mode, table in cases:
        result = JsonlFormatterNode(format_mode=mode).format_table(table)
        line = result.table.column("json_line")[0].as_py()
        assert "\n" not in line, mode
        assert json.loads(line), mode


def test_symbol_name_falls_back_to_the_row_position():
    """Modes over AAs with no symbol column still keep a traceable key."""
    table = pa.table({"prompt": ["P", "P"], "completion": ["C1", "C2"]})
    result = JsonlFormatterNode(format_mode="prompt_completion").format_table(table)
    assert result.table.column("symbol_name").to_pylist() == ["0", "1"]


# --- Legacy formats, via the unified node ------------------------------------


def test_legacy_instruction_completion_is_prompt_completion_with_a_fixed_prompt():
    node = JsonlFormatterNode(
        format_mode="instruction_completion",
        default_prompt=LEGACY_INSTRUCTION_PROMPT,
    )
    line = node.line_for({"text": "A passage."})
    assert json.loads(line) == {
        "prompt": LEGACY_INSTRUCTION_PROMPT,
        "completion": "A passage.",
    }


def test_legacy_continuation_emits_a_bare_text_object():
    node = JsonlFormatterNode(format_mode="continuation")
    assert json.loads(node.line_for({"text": "A passage."})) == {"text": "A passage."}


def test_line_for_returns_none_when_the_row_is_unusable():
    node = JsonlFormatterNode(format_mode="continuation")
    assert node.line_for({"text": "   "}) is None


# --- Route: modes ------------------------------------------------------------


def test_aa_route_honours_the_format_mode():
    response = client.post(
        "/jsonl/format/aa",
        json={
            "astIndex": {
                "rows": ["r1", "r1"],
                "cols": ["prompt", "completion"],
                "vals": ["Explain:", "It adds one."],
            },
            "formatMode": "prompt_completion",
        },
    )

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["formatMode"] == "prompt_completion"
    assert body["lineCount"] == 1
    line = body["jsonlLines"]["vals"][body["jsonlLines"]["cols"].index("json_line")]
    assert json.loads(line) == {"prompt": "Explain:", "completion": "It adds one."}


def test_aa_route_rejects_an_unknown_mode():
    response = client.post(
        "/jsonl/format/aa",
        json={"astIndex": {"rows": ["r"], "cols": ["a"], "vals": ["b"]}, "formatMode": "yaml"},
    )
    assert response.status_code == 422
    assert "unknown format_mode" in response.json()["detail"]


def test_arrow_route_honours_the_format_mode():
    body = to_arrow_bytes(pa.table({"prompt": ["P"], "completion": ["C"]}))
    response = client.post(
        "/jsonl/format?format_mode=prompt_completion",
        content=body,
        headers={"Content-Type": "application/vnd.apache.arrow.file"},
    )

    assert response.status_code == 200, response.text
    assert response.headers["X-Dn-Format-Mode"] == "prompt_completion"
    assert response.headers["X-Dn-Line-Count"] == "1"
    assert read_arrow_table(response.content).column_names == list(OUTPUT_COLUMNS)


def test_the_deprecated_route_still_works_and_is_marked_deprecated(tmp_path):
    """It writes the file itself and returns provenance, so it is kept, not redirected."""
    out = tmp_path / "legacy.jsonl"
    response = client.post(
        "/aa2jsonl",
        json={
            "aa": {
                "rows": ["c1", "c1"],
                "cols": ["text", "position"],
                "vals": ["A passage.", 0],
            },
            "outputFile": str(out),
            "format": "instruction-completion",
        },
    )

    assert response.status_code == 200, response.text
    assert response.json()["stats"]["linesWritten"] == 1
    assert out.is_file()
    assert json.loads(out.read_text().strip()) == {
        "prompt": LEGACY_INSTRUCTION_PROMPT,
        "completion": "A passage.",
    }
    # And OpenAPI advertises the deprecation.
    schema = client.get("/openapi.json").json()
    assert schema["paths"]["/aa2jsonl"]["post"]["deprecated"] is True


def test_save_accepts_the_legacy_jsonl_line_column(tmp_path, monkeypatch):
    """An AA from an older workflow still saves."""
    monkeypatch.setattr("double_touch.save_file.storage_out_dir", lambda: tmp_path)
    aa = AssocArray(
        rows=["c1", "c2"],
        cols=["jsonl_line", "jsonl_line"],
        vals=['{"a":1}', '{"b":2}'],
    )

    out = save_aa_jsonl(aa, "legacy")
    assert out.read_text() == '{"a":1}\n{"b":2}\n'


def test_the_unified_column_wins_when_both_are_present(tmp_path, monkeypatch):
    monkeypatch.setattr("double_touch.save_file.storage_out_dir", lambda: tmp_path)
    aa = AssocArray(
        rows=["c1", "c1"],
        cols=["json_line", "jsonl_line"],
        vals=['{"new":true}', '{"old":true}'],
    )

    out = save_aa_jsonl(aa, "both")
    assert out.read_text() == '{"new":true}\n'
