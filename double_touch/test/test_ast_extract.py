"""Tests for the Julia AST extractor and its Arrow-reading wrapper.

The reader, schema and error-handling tests run everywhere. The tests that
actually invoke ``extract_ast.jl`` need Julia with Arrow.jl, and skip with a clear
reason when it is absent — the extractor genuinely cannot work without it, so
faking that away would test nothing.
"""

from __future__ import annotations

import asyncio
import shutil
import textwrap

import pyarrow as pa
import pyarrow.ipc as ipc
import pytest
from fastapi.testclient import TestClient

from double_touch.app import app
from double_touch.ast_extract import (
    SCHEMA_COLUMNS,
    aa_from_table as ast_aa_from_table,
    AstExtractError,
    AstExtractNode,
    default_script_path,
    read_arrow_table,
    to_arrow_bytes,
    validate_schema,
)

client = TestClient(app)

julia_required = pytest.mark.skipif(
    shutil.which("julia") is None,
    reason="julia not on PATH — the extractor needs it",
)


def run(coro):
    return asyncio.run(coro)


@pytest.fixture
def codebase(tmp_path):
    """A source tree covering every definition form the extractor must handle."""
    (tmp_path / "src").mkdir()
    (tmp_path / "src" / "core.jl").write_text(
        textwrap.dedent(
            '''
            module Core

            "Adds one to `x`."
            function add_one(x)
                x + 1
            end

            double(y) = y * 2

            not_a_function = 42
            const LIMIT = 10

            where_form(x::T) where {T} = x

            Base.show(io::IO, ::Int) = print(io, "int")

            "A macro with docs."
            macro shout(e)
                quote
                    # A definition inside a template is generated code, not a
                    # definition — it must not be indexed.
                    function generated_inner($e)
                        1
                    end
                end
            end

            end
            '''
        ).lstrip()
    )
    # Nested directory, and a file whose second definition is truncated.
    (tmp_path / "src" / "nested").mkdir()
    (tmp_path / "src" / "nested" / "broken.jl").write_text(
        "survivor(x) = x\nfunction truncated(\n"
    )
    # Hidden and excluded directories must not be walked at all.
    (tmp_path / ".git").mkdir()
    (tmp_path / ".git" / "hook.jl").write_text("hidden_fn(x) = x\n")
    (tmp_path / "deps").mkdir()
    (tmp_path / "deps" / "build.jl").write_text("dep_fn(x) = x\n")
    # A non-Julia file is ignored.
    (tmp_path / "README.md").write_text("# not julia\n")
    return tmp_path


# --- The Arrow reader --------------------------------------------------------


def _table(rows=1):
    return pa.table({name: ["v"] * rows for name in SCHEMA_COLUMNS})


def test_reads_the_ipc_file_format(tmp_path):
    """What ``Arrow.write`` to a path produces: ARROW1 magic."""
    path = tmp_path / "file.arrow"
    with ipc.new_file(str(path), _table().schema) as writer:
        writer.write_table(_table())

    assert path.read_bytes().startswith(b"ARROW1")
    assert read_arrow_table(path).num_rows == 1


def test_reads_the_ipc_stream_format(tmp_path):
    """A stream has no magic — the reader must not assume the file format."""
    path = tmp_path / "stream.arrow"
    with path.open("wb") as handle:
        with ipc.new_stream(handle, _table().schema) as writer:
            writer.write_table(_table())

    assert not path.read_bytes().startswith(b"ARROW1")
    assert read_arrow_table(path).num_rows == 1


def test_reads_raw_bytes_in_either_format():
    assert read_arrow_table(to_arrow_bytes(_table(3))).num_rows == 3

    sink = pa.BufferOutputStream()
    with ipc.new_stream(sink, _table(2).schema) as writer:
        writer.write_table(_table(2))
    assert read_arrow_table(sink.getvalue().to_pybytes()).num_rows == 2


def test_a_missing_artifact_is_a_clear_error(tmp_path):
    with pytest.raises(AstExtractError, match="no Arrow artifact"):
        read_arrow_table(tmp_path / "absent.arrow")


def test_garbage_is_rejected_as_unreadable(tmp_path):
    path = tmp_path / "junk.arrow"
    path.write_bytes(b"definitely not arrow" * 8)
    with pytest.raises(AstExtractError, match="not a readable Arrow payload"):
        read_arrow_table(path)


def test_schema_metadata_survives_reserialisation():
    """Diagnostics ride inside the artifact, so they must survive a round trip."""
    table = _table().replace_schema_metadata({"dn_errors": "a\nb", "dn_files_scanned": "7"})
    again = read_arrow_table(to_arrow_bytes(table))
    assert again.schema.metadata[b"dn_files_scanned"] == b"7"


# --- Schema validation ------------------------------------------------------


def test_validate_accepts_the_agreed_schema():
    validate_schema(_table())  # does not raise


def test_validate_rejects_reordered_or_missing_columns():
    reordered = pa.table({name: ["v"] for name in reversed(SCHEMA_COLUMNS)})
    with pytest.raises(AstExtractError, match="unexpected AST index schema"):
        validate_schema(reordered)

    partial = pa.table({name: ["v"] for name in SCHEMA_COLUMNS[:3]})
    with pytest.raises(AstExtractError, match="unexpected AST index schema"):
        validate_schema(partial)


def test_validate_rejects_a_non_string_column():
    columns = {name: ["v"] for name in SCHEMA_COLUMNS}
    columns["line_range"] = [12]
    with pytest.raises(AstExtractError, match="non-string columns"):
        validate_schema(pa.table(columns))


# --- Wrapper preconditions --------------------------------------------------


def test_the_script_ships_with_the_package():
    assert default_script_path().is_file(), default_script_path()


def test_a_missing_root_fails_before_launching_julia(tmp_path):
    node = AstExtractNode()
    with pytest.raises(AstExtractError, match="no such file or directory"):
        run(node.extract(tmp_path / "nope"))


def test_a_missing_script_says_how_to_relocate_it(tmp_path):
    node = AstExtractNode(script=tmp_path / "absent.jl")
    with pytest.raises(AstExtractError, match="DN_EXTRACT_AST_JL"):
        run(node.extract(tmp_path))


def test_a_failed_run_reports_what_the_script_said(tmp_path, monkeypatch):
    """A Julia-side failure surfaces its stderr, not a bare exit code."""

    class Failing:
        async def run(self, payload, **kwargs):
            return {
                "status": "FAILED",
                "stdout": "",
                "stderr": "ERROR: LoadError: something broke",
                "exit_code": 1,
                "execution_time_ms": 5.0,
                "language": "julia",
                "code": "",
                "file_path": "",
            }

    node = AstExtractNode(exec_node=Failing())
    with pytest.raises(AstExtractError, match="something broke"):
        run(node.extract(tmp_path))


def test_a_timeout_is_reported_as_such(tmp_path):
    class TimingOut:
        async def run(self, payload, **kwargs):
            return {
                "status": "TIMEOUT",
                "stdout": "",
                "stderr": "timed out after 1s — process killed",
                "exit_code": -9,
                "execution_time_ms": 1000.0,
                "language": "julia",
                "code": "",
                "file_path": "",
            }

    node = AstExtractNode(exec_node=TimingOut())
    with pytest.raises(AstExtractError, match="timeout"):
        run(node.extract(tmp_path))


# --- End to end, through Julia ----------------------------------------------


@julia_required
def test_extracts_every_definition_form(codebase):
    index = run(AstExtractNode().extract(codebase))
    validate_schema(index.table)

    names = index.table.column("symbol_name").to_pylist()
    kinds = dict(zip(names, index.table.column("kind").to_pylist()))

    # Long form, short form, `where`, qualified, and a macro — with the `@`.
    assert "add_one" in names
    assert "double" in names
    assert "where_form" in names
    assert "Base.show" in names
    assert "@shout" in names
    assert kinds["@shout"] == "macro"
    assert kinds["add_one"] == "function"

    # Assignments and consts are not definitions.
    assert "not_a_function" not in names
    assert "LIMIT" not in names
    # A definition inside a macro's `quote` is generated code, not a definition.
    assert "generated_inner" not in names


@julia_required
def test_captures_docstrings_and_leaves_better_docstring_empty(codebase):
    index = run(AstExtractNode().extract(codebase))
    rows = {
        name: doc
        for name, doc in zip(
            index.table.column("symbol_name").to_pylist(),
            index.table.column("docstring").to_pylist(),
        )
    }

    assert rows["add_one"] == "Adds one to `x`."
    assert rows["@shout"] == "A macro with docs."
    # Undocumented definitions carry an empty string, not a null.
    assert rows["double"] == ""
    assert all(v == "" for v in index.table.column("better_docstring").to_pylist())
    assert index.table.column("docstring").null_count == 0


@julia_required
def test_line_ranges_and_relative_paths(codebase):
    index = run(AstExtractNode().extract(codebase))
    by_name = {
        name: (path, span)
        for name, path, span in zip(
            index.table.column("symbol_name").to_pylist(),
            index.table.column("file_path").to_pylist(),
            index.table.column("line_range").to_pylist(),
        )
    }

    path, span = by_name["add_one"]
    # Relative to the indexed root, not absolute.
    assert path == "src/core.jl"
    start, _, end = span.partition(":")
    assert int(start) < int(end), span
    # A one-line short form spans a single line.
    _, double_span = by_name["double"]
    assert double_span.split(":")[0] == double_span.split(":")[1]


@julia_required
def test_raw_code_is_the_whole_definition(codebase):
    index = run(AstExtractNode().extract(codebase))
    code = dict(
        zip(
            index.table.column("symbol_name").to_pylist(),
            index.table.column("raw_code").to_pylist(),
        )
    )
    assert code["add_one"].startswith("function add_one(x)")
    assert code["add_one"].rstrip().endswith("end")
    assert code["double"] == "double(y) = y * 2"


@julia_required
def test_a_broken_file_is_reported_without_halting_the_walk(codebase):
    """The definition before a truncated one still lands in the index."""
    index = run(AstExtractNode().extract(codebase))
    names = index.table.column("symbol_name").to_pylist()

    assert "survivor" in names, "a partly-broken file lost its good definitions"
    # And the run as a whole succeeded.
    assert index.definition_count > 5


@julia_required
def test_hidden_and_excluded_directories_are_skipped(codebase):
    index = run(AstExtractNode().extract(codebase))
    names = index.table.column("symbol_name").to_pylist()
    paths = set(index.table.column("file_path").to_pylist())

    assert "hidden_fn" not in names, ".git was walked"
    assert "dep_fn" not in names, "deps was walked"
    assert not any(p.startswith(".git") or p.startswith("deps") for p in paths)


@julia_required
def test_diagnostics_arrive_in_the_artifact_metadata(codebase):
    index = run(AstExtractNode().extract(codebase))

    assert index.files_scanned == 2, "src/core.jl and src/nested/broken.jl"
    assert index.root == str(codebase.resolve())
    assert index.table.schema.metadata[b"dn_schema"] == b"ast_index_v1"


@julia_required
def test_the_artifact_can_be_kept(codebase, tmp_path):
    out = tmp_path / "kept" / "index.arrow"
    index = run(AstExtractNode().extract(codebase, out_path=out))

    assert index.artifact == out
    assert out.is_file()
    # And it re-reads to the same table, schema and all.
    again = read_arrow_table(out)
    assert again.schema == index.table.schema
    assert again.num_rows == index.definition_count


@julia_required
def test_an_empty_tree_yields_an_empty_table_with_the_full_schema(tmp_path):
    """Zero definitions must still carry the schema, not collapse to nothing."""
    (tmp_path / "empty").mkdir()
    index = run(AstExtractNode().extract(tmp_path))

    assert index.definition_count == 0
    validate_schema(index.table)


# --- Route ------------------------------------------------------------------


@julia_required
def test_route_returns_arrow_bytes_not_json(codebase):
    response = client.post("/ast/extract", json={"rootPath": str(codebase)})

    assert response.status_code == 200
    assert response.headers["content-type"] == "application/vnd.apache.arrow.file"
    assert response.content.startswith(b"ARROW1")

    table = read_arrow_table(response.content)
    validate_schema(table)
    assert table.num_rows == int(response.headers["X-Dn-Definition-Count"])
    assert response.headers["X-Dn-Files-Scanned"] == "2"
    assert response.headers["X-Dn-Schema"] == "ast_index_v1"


def test_route_rejects_a_missing_directory(tmp_path):
    response = client.post(
        "/ast/extract",
        json={"rootPath": str(tmp_path / "absent")},
    )
    assert response.status_code == 422
    assert "no such file or directory" in response.json()["detail"]


# --- Single-file roots and the wire-AA route ---------------------------------


@julia_required
def test_a_single_file_is_a_valid_root(codebase):
    """The canvas extracts the file Load File opened, not the tree around it."""
    index = run(AstExtractNode().extract(codebase / "src" / "core.jl"))

    assert index.files_scanned == 1
    names = index.table.column("symbol_name").to_pylist()
    assert "add_one" in names
    # `file_path` is relative to the file's own directory.
    assert set(index.table.column("file_path").to_pylist()) == {"core.jl"}
    # And the neighbouring broken file was not touched.
    assert "survivor" not in names


@julia_required
def test_a_non_julia_file_root_yields_an_empty_index(tmp_path):
    (tmp_path / "notes.md").write_text("# prose")
    index = run(AstExtractNode().extract(tmp_path / "notes.md"))
    assert index.definition_count == 0


def test_a_missing_root_names_itself(tmp_path):
    with pytest.raises(AstExtractError, match="no such file or directory"):
        run(AstExtractNode().extract(tmp_path / "absent.jl"))


def test_aa_from_table_emits_one_row_per_definition():
    table = pa.table(
        {
            "symbol_name": ["add_one", "@shout"],
            "kind": ["function", "macro"],
            "file_path": ["a.jl", "a.jl"],
            "line_range": ["1:3", "5:7"],
            "docstring": ["", ""],
            "raw_code": ["add_one(x) = x", "macro shout() end"],
            "better_docstring": ["", ""],
        }
    )
    aa = ast_aa_from_table(table)

    cells = {}
    if len(aa.vals) == len(aa.rows) * len(aa.cols):
        for i, row in enumerate(aa.rows):
            for j, col in enumerate(aa.cols):
                cells.setdefault(row, {})[col] = aa.vals[i * len(aa.cols) + j]
    else:
        for row, col, val in zip(aa.rows, aa.cols, aa.vals):
            cells.setdefault(row, {})[col] = val

    assert len(cells) == 2
    assert set(next(iter(cells.values()))) == set(SCHEMA_COLUMNS)
    # Row keys locate the definition.
    assert "a.jl:1:3" in cells
    assert cells["a.jl:1:3"]["symbol_name"] == "add_one"
    assert cells["a.jl:5:7"]["kind"] == "macro"


def test_aa_from_table_disambiguates_a_repeated_location():
    """A duplicate row key would silently merge two definitions into one row."""
    table = pa.table(
        {name: ["x", "y"] for name in SCHEMA_COLUMNS}
    ).set_column(
        SCHEMA_COLUMNS.index("file_path"), "file_path", pa.array(["a.jl", "a.jl"])
    ).set_column(
        SCHEMA_COLUMNS.index("line_range"), "line_range", pa.array(["1:1", "1:1"])
    )
    aa = ast_aa_from_table(table)

    assert len(set(aa.rows)) == 2, "two definitions, two rows"
    assert "a.jl:1:1#1" in set(aa.rows)


def test_aa_from_table_on_an_empty_index_is_empty():
    table = pa.table({name: pa.array([], type=pa.string()) for name in SCHEMA_COLUMNS})
    aa = ast_aa_from_table(table)
    assert (aa.rows, aa.cols, aa.vals) == ([], [], [])


@julia_required
def test_aa_route_returns_the_index_as_triples(codebase):
    response = client.post(
        "/ast/extract/aa", json={"rootPath": str(codebase / "src" / "core.jl")}
    )

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["definitionCount"] > 0
    assert body["filesScanned"] == 1
    assert body["errors"] == []

    cells = {}
    aa = body["astIndex"]
    if len(aa["vals"]) == len(aa["rows"]) * len(aa["cols"]):
        for i, row in enumerate(aa["rows"]):
            for j, col in enumerate(aa["cols"]):
                cells.setdefault(row, {})[col] = aa["vals"][i * len(aa["cols"]) + j]
    else:
        for row, col, val in zip(aa["rows"], aa["cols"], aa["vals"]):
            cells.setdefault(row, {})[col] = val
    assert len(cells) == body["definitionCount"]

    names = {c["symbol_name"] for c in cells.values()}
    assert "add_one" in names
    assert "@shout" in names, "macros carry their @"


@julia_required
def test_aa_route_reports_skipped_files_without_failing(codebase):
    """The whole tree: one file in it is deliberately truncated."""
    response = client.post("/ast/extract/aa", json={"rootPath": str(codebase)})

    assert response.status_code == 200
    body = response.json()
    assert body["definitionCount"] > 0
    assert body["filesScanned"] == 2


def test_aa_route_rejects_a_missing_root(tmp_path):
    response = client.post(
        "/ast/extract/aa", json={"rootPath": str(tmp_path / "absent")}
    )
    assert response.status_code == 422
    assert "no such file or directory" in response.json()["detail"]
