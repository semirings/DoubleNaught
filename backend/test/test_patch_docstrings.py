"""Tests for the docstring patcher.

Every test that touches the filesystem builds its own throwaway source tree under
``tmp_path``. Nothing here runs against a real checkout — the whole point of this
module is that it rewrites ``.jl`` files in place.

The end-to-end tests need Julia with Arrow.jl and skip with a clear reason
otherwise; the schema, validation and error-path tests run everywhere.
"""

from __future__ import annotations

import asyncio
import shutil
import textwrap

import pyarrow as pa
import pytest
from fastapi.testclient import TestClient

from double_touch.app import app
from double_touch.ast_extract import (
    SCHEMA_COLUMNS,
    AstExtractNode,
    read_arrow_table,
    to_arrow_bytes,
)
from double_touch.patch_docstrings import (
    SUMMARY_COLUMNS,
    PatchDocstringsError,
    PatchDocstringsNode,
    validate_summary,
)

client = TestClient(app)

julia_required = pytest.mark.skipif(
    shutil.which("julia") is None,
    reason="julia not on PATH — the patcher needs it",
)

SOURCE = textwrap.dedent(
    '''
    module Demo

    # A comment that must survive untouched.
    function undocumented(x)
    \tx + 1          # tab-indented body, trailing comment
    end

    "old docs"
    function documented(y)
        y * 2
    end

        indented_short(z) = z

    end
    '''
).lstrip()


def run(coro):
    return asyncio.run(coro)


@pytest.fixture
def tree(tmp_path):
    """A throwaway source tree, plus a pristine copy kept outside it."""
    (tmp_path / "work" / "src").mkdir(parents=True)
    target = tmp_path / "work" / "src" / "demo.jl"
    target.write_text(SOURCE)
    pristine = tmp_path / "pristine.jl"
    pristine.write_text(SOURCE)
    return type(
        "Tree",
        (),
        {"root": tmp_path / "work", "file": target, "pristine": pristine},
    )


def index_of(root):
    """Extract [root], as the pipeline would before a teacher node runs."""
    return run(AstExtractNode().extract(root)).table


def with_docstrings(table: pa.Table, mapping: dict[str, str]) -> pa.Table:
    """Fill `better_docstring` for the named symbols, keeping the metadata."""
    column = [mapping.get(name, "") for name in table.column("symbol_name").to_pylist()]
    filled = table.set_column(
        table.schema.get_field_index("better_docstring"),
        "better_docstring",
        pa.array(column, type=pa.string()),
    )
    return filled.replace_schema_metadata(
        {k.decode(): v.decode() for k, v in (table.schema.metadata or {}).items()}
    )


# --- Summary schema ---------------------------------------------------------


def test_validate_summary_accepts_the_agreed_shape():
    validate_summary(
        pa.table(
            {
                "file_path": ["a.jl"],
                "symbols_patched": pa.array([2], type=pa.int64()),
                "status": ["UPDATED"],
            }
        )
    )


def test_validate_summary_rejects_wrong_columns():
    with pytest.raises(PatchDocstringsError, match="unexpected patch summary schema"):
        validate_summary(pa.table({"file_path": ["a.jl"], "status": ["UPDATED"]}))


def test_validate_summary_requires_an_integer_count():
    """`symbols_patched` is a count; a string column would lose that."""
    with pytest.raises(PatchDocstringsError, match="must be an integer column"):
        validate_summary(
            pa.table(
                {
                    "file_path": ["a.jl"],
                    "symbols_patched": ["2"],
                    "status": ["UPDATED"],
                }
            )
        )


# --- Input validation -------------------------------------------------------


def test_a_table_that_is_not_the_index_is_refused():
    node = PatchDocstringsNode()
    with pytest.raises(PatchDocstringsError, match="not the AST index"):
        run(node.patch(pa.table({"nope": ["x"]})))


def test_relative_paths_without_a_root_are_refused():
    """Rather than guessing a root and patching the wrong tree."""
    table = pa.table({name: ["src/a.jl" if name == "file_path" else "v"] for name in SCHEMA_COLUMNS})
    node = PatchDocstringsNode()
    with pytest.raises(PatchDocstringsError, match="no root"):
        run(node.patch(table))


def test_a_missing_script_says_how_to_relocate_it(tmp_path):
    table = pa.table({name: ["v"] for name in SCHEMA_COLUMNS})
    node = PatchDocstringsNode(script=tmp_path / "absent.jl")
    with pytest.raises(PatchDocstringsError, match="DN_PATCH_DOCSTRINGS_JL"):
        run(node.patch(table, root=tmp_path))


def test_a_failed_run_reports_what_the_script_said(tmp_path):
    class Failing:
        async def run(self, payload, **kwargs):
            return {
                "status": "FAILED",
                "stdout": "",
                "stderr": "ERROR: LoadError: broke",
                "exit_code": 1,
                "execution_time_ms": 3.0,
                "language": "julia",
                "code": "",
                "file_path": "",
            }

    table = pa.table({name: ["v"] for name in SCHEMA_COLUMNS})
    node = PatchDocstringsNode(exec_node=Failing())
    with pytest.raises(PatchDocstringsError, match="broke"):
        run(node.patch(table, root=tmp_path))


# --- Patching, end to end ---------------------------------------------------


@julia_required
def test_inserts_replaces_and_reports(tree):
    summary = run(
        PatchDocstringsNode().patch(
            with_docstrings(
                index_of(tree.root),
                {
                    "undocumented": "Adds one to `x`.",
                    "documented": "Doubles `y`.",
                },
            )
        )
    )

    assert summary.updated == ["src/demo.jl"]
    assert summary.symbols_patched == 2
    assert summary.failed == []
    assert summary.errors == []

    patched = tree.file.read_text()
    assert '"""\nAdds one to `x`.\n"""\nfunction undocumented' in patched
    # The old one-line docstring is gone, replaced by the block.
    assert '"old docs"' not in patched
    assert '"""\nDoubles `y`.\n"""' in patched


@julia_required
def test_everything_outside_the_docstrings_is_byte_identical(tree):
    """The preservation guarantee, checked line by line rather than asserted."""
    original = tree.pristine.read_text()
    run(
        PatchDocstringsNode().patch(
            with_docstrings(index_of(tree.root), {"undocumented": "Adds one."})
        )
    )
    patched = tree.file.read_text()

    # Every original line survives verbatim, except the docstring that was
    # replaced — here, none were, so all of them.
    for line in original.splitlines():
        assert line in patched.splitlines(), f"lost line: {line!r}"
    # Including the tab indentation and the trailing comment.
    assert "\tx + 1          # tab-indented body, trailing comment" in patched
    assert "# A comment that must survive untouched." in patched
    # And the patch is purely additive.
    assert len(patched) > len(original)


@julia_required
def test_the_indentation_of_the_definition_is_matched(tree):
    run(
        PatchDocstringsNode().patch(
            with_docstrings(index_of(tree.root), {"indented_short": "Returns `z`."})
        )
    )
    patched = tree.file.read_text()

    # The definition sits at four spaces, so its docstring block does too.
    assert '    """\n    Returns `z`.\n    """\n    indented_short(z) = z' in patched


@julia_required
def test_docstrings_round_trip_exactly_through_the_file(tree):
    """The escaping property: what goes in is what comes back out.

    `$` would interpolate and `\\` would escape if written raw, and a `\"\"\"` would
    close the block early — so this is the test that the emitted literal is
    correct, not merely parseable.
    """
    awkward = {
        "undocumented": "Interpolation $x and LaTeX \\alpha_{i}.",
        "documented": 'Has a """ fence inside.',
        "indented_short": "Multi\n\nparagraph with trailing quote\"",
    }
    run(PatchDocstringsNode().patch(with_docstrings(index_of(tree.root), awkward)))

    reread = index_of(tree.root)
    got = dict(
        zip(
            reread.column("symbol_name").to_pylist(),
            reread.column("docstring").to_pylist(),
        )
    )
    for name, expected in awkward.items():
        assert got[name].rstrip("\n") == expected, name


@julia_required
def test_an_empty_better_docstring_changes_nothing(tree):
    before = tree.file.read_text()
    summary = run(PatchDocstringsNode().patch(index_of(tree.root)))

    assert summary.unchanged == ["src/demo.jl"]
    assert summary.symbols_patched == 0
    assert tree.file.read_text() == before


@julia_required
def test_an_unchanged_docstring_is_not_rewritten(tree):
    """Sending back the docstring that is already there is a no-op."""
    table = index_of(tree.root)
    existing = dict(
        zip(
            table.column("symbol_name").to_pylist(),
            table.column("docstring").to_pylist(),
        )
    )
    before = tree.file.read_text()

    summary = run(
        PatchDocstringsNode().patch(
            with_docstrings(table, {"documented": existing["documented"]})
        )
    )
    assert summary.unchanged == ["src/demo.jl"]
    assert tree.file.read_text() == before


@julia_required
def test_a_stale_line_range_leaves_the_whole_file_untouched(tree):
    """All-or-nothing: one unlocatable row must not half-patch the file."""
    table = with_docstrings(
        index_of(tree.root),
        {"undocumented": "Adds one.", "documented": "Doubles."},
    )
    # Break one row's line_range, as an edit since extraction would.
    ranges = table.column("line_range").to_pylist()
    names = table.column("symbol_name").to_pylist()
    ranges[names.index("documented")] = "999:1001"
    table = table.set_column(
        table.schema.get_field_index("line_range"),
        "line_range",
        pa.array(ranges, type=pa.string()),
    ).replace_schema_metadata(
        {k.decode(): v.decode() for k, v in (table.schema.metadata or {}).items()}
    )
    before = tree.file.read_text()

    summary = run(PatchDocstringsNode().patch(table))

    assert summary.failed == ["src/demo.jl"]
    assert summary.symbols_patched == 0
    assert tree.file.read_text() == before, "a stale row half-patched the file"
    assert any("stale" in message for message in summary.errors)


@julia_required
def test_dry_run_reports_without_writing(tree):
    before = tree.file.read_text()
    summary = run(
        PatchDocstringsNode().patch(
            with_docstrings(index_of(tree.root), {"undocumented": "Adds one."}),
            dry_run=True,
        )
    )

    assert summary.dry_run is True
    assert summary.updated == ["src/demo.jl"], "should report what it would change"
    assert summary.symbols_patched == 1
    assert tree.file.read_text() == before, "dry run wrote to disk"


@julia_required
def test_several_definitions_in_one_file_are_all_applied(tree):
    """Descending-offset application: earlier edits must not shift later ones."""
    summary = run(
        PatchDocstringsNode().patch(
            with_docstrings(
                index_of(tree.root),
                {
                    "undocumented": "First.",
                    "documented": "Second.",
                    "indented_short": "Third.",
                },
            )
        )
    )
    assert summary.symbols_patched == 3

    reread = index_of(tree.root)
    got = dict(
        zip(
            reread.column("symbol_name").to_pylist(),
            reread.column("docstring").to_pylist(),
        )
    )
    assert got["undocumented"].strip() == "First."
    assert got["documented"].strip() == "Second."
    assert got["indented_short"].strip() == "Third."


@julia_required
def test_several_files_are_summarised_separately(tmp_path):
    root = tmp_path / "multi"
    (root / "src").mkdir(parents=True)
    (root / "src" / "one.jl").write_text("alpha(x) = x\n")
    (root / "src" / "two.jl").write_text("beta(y) = y\n")

    summary = run(
        PatchDocstringsNode().patch(
            with_docstrings(index_of(root), {"alpha": "First file."})
        )
    )

    assert sorted(summary.updated) == ["src/one.jl"]
    assert sorted(summary.unchanged) == ["src/two.jl"]
    assert summary.table.num_rows == 2


@julia_required
def test_file_permissions_survive_the_atomic_write(tree):
    tree.file.chmod(0o755)
    run(
        PatchDocstringsNode().patch(
            with_docstrings(index_of(tree.root), {"undocumented": "Adds one."})
        )
    )
    assert tree.file.stat().st_mode & 0o777 == 0o755


@julia_required
def test_no_temporary_files_are_left_behind(tree):
    run(
        PatchDocstringsNode().patch(
            with_docstrings(index_of(tree.root), {"undocumented": "Adds one."})
        )
    )
    assert [p.name for p in (tree.root / "src").iterdir()] == ["demo.jl"]


@julia_required
def test_an_explicit_root_overrides_the_metadata(tmp_path, tree):
    """A tree moved since extraction can still be patched by naming the new root."""
    moved = tmp_path / "moved"
    shutil.copytree(tree.root, moved)
    table = with_docstrings(index_of(tree.root), {"undocumented": "Adds one."})

    summary = run(PatchDocstringsNode().patch(table, root=moved))

    assert summary.updated == ["src/demo.jl"]
    # The copy was patched; the original was not.
    assert "Adds one." in (moved / "src" / "demo.jl").read_text()
    assert "Adds one." not in tree.file.read_text()


# --- Route ------------------------------------------------------------------


@julia_required
def test_route_takes_arrow_and_returns_arrow(tree):
    table = with_docstrings(index_of(tree.root), {"undocumented": "Via the route."})

    response = client.post(
        "/ast/patch",
        content=to_arrow_bytes(table),
        headers={"Content-Type": "application/vnd.apache.arrow.file"},
    )

    assert response.status_code == 200
    assert response.headers["content-type"] == "application/vnd.apache.arrow.file"
    assert response.headers["X-Dn-Files-Updated"] == "1"
    assert response.headers["X-Dn-Symbols-Patched"] == "1"
    assert response.headers["X-Dn-Dry-Run"] == "false"

    summary = read_arrow_table(response.content)
    validate_summary(summary)
    assert summary.column("status").to_pylist() == ["UPDATED"]
    assert "Via the route." in tree.file.read_text()


@julia_required
def test_route_dry_run_does_not_write(tree):
    table = with_docstrings(index_of(tree.root), {"undocumented": "Not written."})
    before = tree.file.read_text()

    response = client.post(
        "/ast/patch?dry_run=true",
        content=to_arrow_bytes(table),
        headers={"Content-Type": "application/vnd.apache.arrow.file"},
    )

    assert response.status_code == 200
    assert response.headers["X-Dn-Dry-Run"] == "true"
    assert tree.file.read_text() == before


def test_route_rejects_an_empty_body():
    response = client.post("/ast/patch", content=b"")
    assert response.status_code == 422
    assert "Arrow IPC bytes" in response.json()["detail"]


def test_route_rejects_a_body_that_is_not_the_index():
    response = client.post(
        "/ast/patch",
        content=to_arrow_bytes(pa.table({"nope": ["x"]})),
        headers={"Content-Type": "application/vnd.apache.arrow.file"},
    )
    assert response.status_code == 422
    assert "not the AST index" in response.json()["detail"]
