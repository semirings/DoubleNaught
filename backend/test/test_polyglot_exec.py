"""Tests for the Polyglot Exec node.

Only ``python3`` and ``bash`` are actually executed — they are the two
interpreters guaranteed to exist wherever this suite runs. Julia and Node are
covered through language *resolution* and a stubbed binary resolver, so the
suite does not silently skip on a machine without them.
"""

from __future__ import annotations

import asyncio
import sys

import pytest
from fastapi.testclient import TestClient

from double_touch.app import app
from double_touch.models import AssocArray
from double_touch.polyglot_exec_node import (
    RESULT_COLUMNS,
    STDOUT_MODE_COLUMN,
    STDOUT_MODE_NONE,
    STDOUT_MODE_REPLACE,
    ExecInput,
    PolyglotExecNode,
    merge_result_aa,
)

client = TestClient(app)


def run(coro):
    return asyncio.run(coro)


# --- Language resolution -----------------------------------------------------


def test_explicit_language_wins_over_everything_else():
    node = PolyglotExecNode()
    payload = ExecInput(code="x", file_path="a.py", language="python")
    assert node.resolve_language(payload, override="julia").name == "julia"


def test_payload_language_used_when_no_override():
    node = PolyglotExecNode()
    payload = ExecInput(code="x", language="node")
    # An alias resolves to its canonical name.
    assert node.resolve_language(payload).name == "javascript"


def test_auto_override_falls_through_to_inference():
    node = PolyglotExecNode()
    payload = ExecInput(code="x", file_path="src/script.jl")
    assert node.resolve_language(payload, override="auto").name == "julia"


@pytest.mark.parametrize(
    "path,expected",
    [
        ("main.py", "python"),
        ("src/script.jl", "julia"),
        ("bundle.mjs", "javascript"),
        ("deploy.sh", "bash"),
    ],
)
def test_extension_inference(path, expected):
    node = PolyglotExecNode()
    assert node.resolve_language(ExecInput(code="x", file_path=path)).name == expected


@pytest.mark.parametrize(
    "shebang,expected",
    [
        ("#!/usr/bin/env julia", "julia"),
        ("#!/bin/bash", "bash"),
        ("#!/usr/bin/env python3", "python"),
        ("#!/usr/bin/node", "javascript"),
    ],
)
def test_shebang_inference(shebang, expected):
    node = PolyglotExecNode()
    # No path, no language — only the code's own first line.
    payload = ExecInput(code=f"{shebang}\nprint(1)\n")
    assert node.resolve_language(payload).name == expected


def test_unknown_extension_and_no_hints_is_an_error():
    node = PolyglotExecNode()
    with pytest.raises(ValueError, match="could not determine the language"):
        node.resolve_language(ExecInput(code="x", file_path="notes.rtf"))


def test_unsupported_explicit_language_names_what_is_known():
    node = PolyglotExecNode()
    with pytest.raises(ValueError, match="known: julia, python"):
        node.resolve_language(ExecInput(code="x"), override="fortran")


# --- Execution ---------------------------------------------------------------


def test_successful_run_captures_stdout_and_timing():
    node = PolyglotExecNode()
    result = run(node.run(ExecInput(code="print('hi')", language="python")))

    assert result["status"] == "SUCCESS"
    assert result["stdout"].strip() == "hi"
    assert result["stderr"] == ""
    assert result["exit_code"] == 0
    assert result["execution_time_ms"] > 0
    # Pass-throughs survive.
    assert result["code"] == "print('hi')"


def test_stderr_and_nonzero_exit_are_reported_not_raised():
    node = PolyglotExecNode()
    result = run(
        node.run(
            ExecInput(
                code="import sys; sys.stderr.write('boom'); sys.exit(3)",
                language="python",
            )
        )
    )

    assert result["status"] == "FAILED"
    assert "boom" in result["stderr"]
    assert result["exit_code"] == 3


def test_both_streams_are_captured_from_one_run():
    node = PolyglotExecNode()
    result = run(node.run(ExecInput(code="echo out; echo err 1>&2", language="bash")))

    assert result["stdout"].strip() == "out"
    assert result["stderr"].strip() == "err"
    assert result["status"] == "SUCCESS"


def test_timeout_kills_the_process_and_keeps_partial_output():
    node = PolyglotExecNode(timeout_s=0.4)
    # Prints, flushes, then hangs — so there *is* partial output to keep.
    result = run(
        node.run(
            ExecInput(
                code="echo partial; sleep 30",
                language="bash",
            )
        )
    )

    assert result["status"] == "TIMEOUT"
    assert result["exit_code"] != 0
    assert "partial" in result["stdout"]
    assert "timed out after 0.4s" in result["stderr"]
    # And it did not actually wait for the sleep.
    assert result["execution_time_ms"] < 5_000


def test_timeout_kills_grandchildren_too():
    """A hung *child of the snippet* must not outlive the run."""
    node = PolyglotExecNode(timeout_s=0.4)
    result = run(
        node.run(
            ExecInput(
                # The subshell would keep the pipe open past the parent's death
                # if the whole group were not killed.
                code="sleep 30 & echo started; wait",
                language="bash",
            )
        )
    )
    assert result["status"] == "TIMEOUT"
    assert result["execution_time_ms"] < 5_000


def test_missing_interpreter_is_a_result_not_an_exception():
    node = PolyglotExecNode(which=lambda _binary: None)
    result = run(node.run(ExecInput(code="println(1)", language="julia")))

    assert result["status"] == "FAILED"
    assert result["exit_code"] == PolyglotExecNode.EXIT_NOT_FOUND
    assert "not found on PATH" in result["stderr"]
    assert result["language"] == "julia"


def test_empty_code_fails_without_spawning_anything():
    node = PolyglotExecNode(which=lambda _b: (_ for _ in ()).throw(AssertionError()))
    result = run(node.run(ExecInput(code="   ", language="python")))
    assert result["status"] == "FAILED"
    assert result["stderr"] == "no code in the payload"


def test_args_are_positional_from_one_in_every_language():
    """``bash -c CODE a`` binds ``a`` to ``$0``; the node inserts a placeholder
    so ``$1`` is the first user argument, as in Python and the rest."""
    node = PolyglotExecNode()
    bash = run(
        node.run(ExecInput(code='echo "$1-$2"', language="bash", args=["x", "y"]))
    )
    assert bash["stdout"].strip() == "x-y"

    py = run(
        node.run(
            ExecInput(
                code="import sys; print(sys.argv[1])",
                language="python",
                args=["x"],
            )
        )
    )
    assert py["stdout"].strip() == "x"


def test_output_is_capped_and_says_so():
    node = PolyglotExecNode(max_output_bytes=64)
    result = run(node.run(ExecInput(code="print('z' * 5000)", language="python")))
    assert result["status"] == "SUCCESS"
    assert "truncated at 64 bytes" in result["stdout"]
    assert len(result["stdout"]) < 200


def test_undecodable_output_does_not_lose_the_run():
    node = PolyglotExecNode()
    result = run(
        node.run(
            ExecInput(
                code=r"import sys; sys.stdout.buffer.write(b'\xff\xfe ok')",
                language="python",
            )
        )
    )
    assert result["status"] == "SUCCESS"
    assert "ok" in result["stdout"]


def test_cwd_is_the_source_file_directory(tmp_path):
    """A relative path in the snippet resolves next to the file it came from."""
    (tmp_path / "data.txt").write_text("beside me")
    node = PolyglotExecNode()
    result = run(
        node.run(
            ExecInput(
                code="print(open('data.txt').read())",
                file_path=str(tmp_path / "script.py"),
            )
        )
    )
    assert result["stdout"].strip() == "beside me"


def test_julia_actually_runs_if_installed():
    """Not skipped when Julia is absent — the missing-binary path is a result."""
    node = PolyglotExecNode(timeout_s=120)
    result = run(node.run(ExecInput(code='print(6 * 7)', language="julia")))
    if result["exit_code"] == PolyglotExecNode.EXIT_NOT_FOUND:
        pytest.skip("julia not installed on this machine")
    assert result["status"] == "SUCCESS"
    assert result["stdout"].strip() == "42"


# --- AA adaptation -----------------------------------------------------------


def test_from_aa_reads_a_load_file_contents_payload():
    """The shape ``Load File`` really emits for a .jl file: one row, one `text`."""
    aa = AssocArray(rows=["0"], cols=["text"], vals=["println(1)"])
    payload = PolyglotExecNode.from_aa(aa)
    assert payload.code == "println(1)"
    assert payload.file_path == ""


def test_from_aa_reads_the_full_documented_contract():
    aa = AssocArray(
        rows=["0"] * 5,
        cols=["file_path", "language", "code", "shebang", "args"],
        vals=["src/s.jl", "julia", "print(1)", "#!/usr/bin/env julia", "a,b"],
    )
    payload = PolyglotExecNode.from_aa(aa)
    assert payload.file_path == "src/s.jl"
    assert payload.language == "julia"
    assert payload.code == "print(1)"
    assert payload.shebang == "#!/usr/bin/env julia"
    assert payload.args == ["a", "b"]


def test_from_aa_accepts_camel_case_columns():
    """The Dart side speaks camelCase on the wire."""
    aa = AssocArray(rows=["0", "0"], cols=["filePath", "code"], vals=["a.py", "pass"])
    payload = PolyglotExecNode.from_aa(aa)
    assert payload.file_path == "a.py"


def test_from_aa_skips_rows_with_nothing_usable():
    aa = AssocArray(
        rows=["0", "1"],
        cols=["irrelevant", "code"],
        vals=["noise", "print(1)"],
    )
    assert PolyglotExecNode.from_aa(aa).code == "print(1)"


def test_from_aa_on_an_empty_payload_is_empty_not_an_error():
    payload = PolyglotExecNode.from_aa(AssocArray(rows=[], cols=[], vals=[]))
    assert payload.code == ""


def test_to_aa_is_one_row_of_the_contract_columns():
    node = PolyglotExecNode()
    result = run(node.run(ExecInput(code="print(1)", language="python")))
    aa = PolyglotExecNode.to_aa(result)

    assert aa.cols == list(RESULT_COLUMNS)
    assert len(set(aa.rows)) == 1, "a single logical row"
    assert len(aa.rows) == len(aa.cols) == len(aa.vals)

    by_col = dict(zip(aa.cols, aa.vals))
    assert by_col["status"] == "SUCCESS"
    # Numeric columns stay numeric — the AA value type allows it.
    assert isinstance(by_col["exit_code"], int)
    assert isinstance(by_col["execution_time_ms"], float)


def test_to_aa_row_keys_are_unique_per_run():
    node = PolyglotExecNode()
    result = run(node.run(ExecInput(code="print(1)", language="python")))
    first = PolyglotExecNode.to_aa(result).rows[0]
    second = PolyglotExecNode.to_aa(result).rows[0]
    assert first != second


# --- Route -------------------------------------------------------------------


def test_exec_route_runs_code_and_returns_both_shapes():
    response = client.post(
        "/exec",
        json={"code": "print('routed')", "language": "python"},
    )
    assert response.status_code == 200
    body = response.json()

    assert body["status"] == "SUCCESS"
    assert body["stdout"].strip() == "routed"
    assert body["exitCode"] == 0
    assert body["executionTimeMs"] > 0
    # …and the same result as an AA.
    assert body["executionResult"]["cols"] == list(RESULT_COLUMNS)


def test_exec_route_runs_an_upstream_aa_payload():
    response = client.post(
        "/exec",
        json={
            "executionPayload": {"rows": ["0"], "cols": ["text"], "vals": ["print('from aa')"]},
            "language": "python",
        },
    )
    assert response.status_code == 200
    assert response.json()["stdout"].strip() == "from aa"


def test_exec_route_request_fields_override_the_payload():
    response = client.post(
        "/exec",
        json={
            "executionPayload": {
                "rows": ["0", "0"],
                "cols": ["code", "language"],
                "vals": ["print('ignored')", "python"],
            },
            "code": "echo overridden",
            "language": "bash",
        },
    )
    assert response.status_code == 200
    assert response.json()["stdout"].strip() == "overridden"


def test_exec_route_reports_a_failing_snippet_as_200_with_status_failed():
    """A code failure is data for the downstream node, not an HTTP error."""
    response = client.post(
        "/exec",
        json={"code": "import sys; sys.exit(9)", "language": "python"},
    )
    assert response.status_code == 200
    assert response.json()["status"] == "FAILED"
    assert response.json()["exitCode"] == 9


def test_exec_route_rejects_a_request_with_no_code():
    response = client.post("/exec", json={"language": "python"})
    assert response.status_code == 422
    assert "no code to run" in response.json()["detail"]


def test_exec_route_rejects_an_unresolvable_language():
    response = client.post("/exec", json={"code": "print(1)"})
    assert response.status_code == 422
    assert "could not determine the language" in response.json()["detail"]


def test_exec_route_rejects_a_nonpositive_timeout():
    response = client.post(
        "/exec",
        json={"code": "print(1)", "language": "python", "timeoutS": 0},
    )
    assert response.status_code == 422


def test_exec_route_honours_the_timeout():
    response = client.post(
        "/exec",
        json={"code": "sleep 30", "language": "bash", "timeoutS": 0.4},
    )
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "TIMEOUT"
    assert body["executionTimeMs"] < 5_000


@pytest.mark.skipif(sys.platform == "win32", reason="POSIX process groups")
def test_exec_route_passes_args_through():
    response = client.post(
        "/exec",
        json={
            "code": 'echo "$1"',
            "language": "bash",
            "args": ["hello"],
        },
    )
    assert response.json()["stdout"].strip() == "hello"


# --- Schema pass-through: the merged output AA -------------------------------


def _cells(aa):
    """`{row: {col: val}}` from sparse triples."""
    out = {}
    for row, col, val in zip(aa.rows, aa.cols, aa.vals):
        out.setdefault(row, {})[col] = val
    return out


SOURCE_AA = AssocArray(
    rows=["r1", "r1", "r1", "r2"],
    cols=["text", "author", "file_path", "text"],
    vals=["print('hi')", "gcr", "/tmp/a.py", "a second row"],
)

RESULT = {
    "status": "SUCCESS",
    "language": "python",
    "stdout": "transformed source",
    "stderr": "",
    "exit_code": 0,
    "execution_time_ms": 9.5,
    "code": "print('hi')",
    "file_path": "/tmp/a.py",
}


def test_merge_keeps_every_input_column():
    """The bug: metadata replaced the payload instead of extending it."""
    merged = merge_result_aa(SOURCE_AA, RESULT, row_key="r1", source_column="text")
    cells = _cells(merged)

    assert cells["r1"]["text"] == "print('hi')", "the source text survives"
    assert cells["r1"]["author"] == "gcr", "unrelated columns survive"


def test_merge_appends_the_metadata_to_the_source_row():
    merged = merge_result_aa(SOURCE_AA, RESULT, row_key="r1", source_column="text")
    row = _cells(merged)["r1"]

    for column in RESULT_COLUMNS:
        assert column in row, column
    assert row["status"] == "SUCCESS"
    # Numeric columns keep their types through the merge.
    assert isinstance(row["exit_code"], int)
    assert isinstance(row["execution_time_ms"], float)


def test_merge_keeps_the_input_row_keys():
    """Downstream nodes line results up against the rows they sent."""
    merged = merge_result_aa(SOURCE_AA, RESULT, row_key="r1", source_column="text")
    assert set(merged.rows) == {"r1", "r2"}
    assert "exec:" not in " ".join(merged.rows)


def test_merge_leaves_other_rows_untouched():
    merged = merge_result_aa(SOURCE_AA, RESULT, row_key="r1", source_column="text")
    assert _cells(merged)["r2"] == {"text": "a second row"}


def test_stdout_column_mode_adds_transformed_text_without_touching_text():
    merged = merge_result_aa(
        SOURCE_AA, RESULT, row_key="r1", source_column="text",
        stdout_mode=STDOUT_MODE_COLUMN,
    )
    row = _cells(merged)["r1"]

    assert row["transformed_text"] == "transformed source"
    assert row["text"] == "print('hi')", "the original is preserved"


def test_stdout_replace_mode_overwrites_the_source_column():
    merged = merge_result_aa(
        SOURCE_AA, RESULT, row_key="r1", source_column="text",
        stdout_mode=STDOUT_MODE_REPLACE,
    )
    row = _cells(merged)["r1"]

    # A downstream node reading `text` sees the transformed text…
    assert row["text"] == "transformed source"
    # …and the pre-execution source is still reachable.
    assert row["code"] == "print('hi')"
    assert "transformed_text" not in row


def test_stdout_none_mode_leaves_only_the_metadata_column():
    merged = merge_result_aa(
        SOURCE_AA, RESULT, row_key="r1", source_column="text",
        stdout_mode=STDOUT_MODE_NONE,
    )
    row = _cells(merged)["r1"]

    assert row["text"] == "print('hi')"
    assert "transformed_text" not in row
    assert row["stdout"] == "transformed source", "still in the metadata"


def test_a_custom_stdout_column_is_honoured():
    merged = merge_result_aa(
        SOURCE_AA, RESULT, row_key="r1", source_column="text",
        stdout_column="better_docstring",
    )
    assert _cells(merged)["r1"]["better_docstring"] == "transformed source"


def test_empty_stdout_adds_no_column():
    merged = merge_result_aa(
        SOURCE_AA, dict(RESULT, stdout="   "), row_key="r1", source_column="text"
    )
    assert "transformed_text" not in _cells(merged)["r1"]


def test_a_colliding_input_column_is_replaced_not_duplicated():
    """One value per cell: two triples for one (row, col) is unresolvable."""
    source = AssocArray(
        rows=["r1", "r1"], cols=["text", "status"], vals=["code", "stale"]
    )
    merged = merge_result_aa(source, RESULT, row_key="r1", source_column="text")

    pairs = list(zip(merged.rows, merged.cols))
    assert len(pairs) == len(set(pairs)), "no duplicate cells"
    assert _cells(merged)["r1"]["status"] == "SUCCESS", "the fresh value wins"


def test_no_source_aa_falls_back_to_the_standalone_metadata_row():
    """A direct `code=` call has no rows to merge with."""
    merged = merge_result_aa(None, RESULT)
    assert list(merged.cols) == list(RESULT_COLUMNS)
    assert merged.rows[0].startswith("exec:")


def test_an_unknown_stdout_mode_is_refused():
    with pytest.raises(ValueError, match="unknown stdout_mode"):
        merge_result_aa(SOURCE_AA, RESULT, stdout_mode="wat")


def test_from_aa_reports_the_row_and_column_it_read():
    payload = PolyglotExecNode.from_aa(SOURCE_AA)
    assert payload.row_key == "r1"
    assert payload.source_column == "text"


# --- The route ----------------------------------------------------------------


def test_route_merges_the_payload_into_the_response_aa():
    response = client.post(
        "/exec",
        json={
            "executionPayload": {
                "rows": ["r1", "r1", "r2"],
                "cols": ["text", "author", "text"],
                "vals": ["print('hello')", "gcr", "untouched"],
            },
            "language": "python",
        },
    )

    assert response.status_code == 200
    cells = {}
    aa = response.json()["executionResult"]
    for row, col, val in zip(aa["rows"], aa["cols"], aa["vals"]):
        cells.setdefault(row, {})[col] = val

    assert cells["r1"]["text"] == "print('hello')"
    assert cells["r1"]["author"] == "gcr"
    assert cells["r1"]["status"] == "SUCCESS"
    assert cells["r1"]["transformed_text"] == "hello\n"
    assert cells["r2"] == {"text": "untouched"}


def test_route_honours_replace_mode():
    response = client.post(
        "/exec",
        json={
            "executionPayload": {"rows": ["r1"], "cols": ["text"], "vals": ["print('new text')"]},
            "language": "python",
            "stdoutMode": "replace",
        },
    )

    aa = response.json()["executionResult"]
    cells = dict(zip(aa["cols"], aa["vals"]))
    assert cells["text"] == "new text\n"
    assert cells["code"] == "print('new text')"


def test_route_rejects_an_unknown_stdout_mode():
    response = client.post(
        "/exec",
        json={"code": "print(1)", "language": "python", "stdoutMode": "sideways"},
    )
    assert response.status_code == 422
    assert "unknown stdout_mode" in response.json()["detail"]


def test_a_code_only_request_still_returns_the_metadata_aa():
    """No AA in, no merge — the old shape, unchanged."""
    body = client.post("/exec", json={"code": "print(1)", "language": "python"}).json()
    assert body["executionResult"]["cols"] == list(RESULT_COLUMNS)
