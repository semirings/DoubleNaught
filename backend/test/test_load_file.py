"""Unit tests for the Load File node backend (``load_file`` / ``/load``).

Run with: ``pip install -e '.[dev]' && pytest`` from ``backend/``.

Coverage:
  * CSV → AA reconstruction in table form (first column = row keys) and triple
    form (``rowKey,colKey,val``), matching D4M.jl's ``ReadCSV``
  * schema_mode handling, including the camelCase spellings the Flutter node
    sends on the wire
  * ``/load`` HTTP contract for a CSV
"""

import json

import pytest
from fastapi.testclient import TestClient

from double_touch.app import app
from double_touch.load_file import load_file

client = TestClient(app)


# ── Fixture helpers ───────────────────────────────────────────────────────────

# Table form: column 1 holds the row keys, and (p1, GENDER) is deliberately
# blank so the sparse-skip behaviour is exercised.
_TABLE_CSV = (
    "ID,GENDER,CITY\n"
    "p1,,Norfolk\n"
    "p2,M,\"Newport News, VA\"\n"
)

_TRIPLE_CSV = "rowKey,colKey,val\np1,GENDER,F\np2,GENDER,M\n"


def _write(tmp_path, name, text):
    path = tmp_path / name
    path.write_text(text)
    return str(path)


def _cells(aa):
    return {(r, c): v for r, c, v in zip(aa.rows, aa.cols, aa.vals)}


# ── CSV → AA ─────────────────────────────────────────────────────────────────

def test_csv_table_form_uses_first_column_as_row_keys(tmp_path):
    aa, data = load_file(_write(tmp_path, "t.csv", _TABLE_CSV), "auto")

    assert aa is not None
    # The ID header is a label for the key column, not a column key of its own.
    assert set(aa.cols) == {"GENDER", "CITY"}
    assert set(aa.rows) == {"p1", "p2"}
    # Blank (p1, GENDER) yields no triple; the quoted comma survives.
    assert _cells(aa) == {
        ("p1", "CITY"): "Norfolk",
        ("p2", "GENDER"): "M",
    } | {("p2", "CITY"): "Newport News, VA"}
    # The raw view is still returned for the node's `contents` port.
    assert len(data["rows"]) == 2


def test_csv_values_stay_strings(tmp_path):
    aa, _ = load_file(_write(tmp_path, "z.csv", "ID,ZIP\np1,00000\n"), "auto")
    assert aa.vals == ["00000"]


def test_csv_triple_form_is_reconstructed_directly(tmp_path):
    aa, _ = load_file(_write(tmp_path, "tr.csv", _TRIPLE_CSV), "auto")

    assert _cells(aa) == {("p1", "GENDER"): "F", ("p2", "GENDER"): "M"}


def test_csv_blank_key_cell_falls_back_to_line_number(tmp_path):
    aa, _ = load_file(
        _write(tmp_path, "b.csv", "ID,GENDER\n,F\n,M\n"), "auto"
    )
    # Both lines would otherwise collapse onto a single "" row key.
    assert _cells(aa) == {("0", "GENDER"): "F", ("1", "GENDER"): "M"}


def test_csv_single_column_has_no_aa_to_build(tmp_path):
    aa, data = load_file(_write(tmp_path, "one.csv", "ID\np1\n"), "auto")
    assert aa is None
    assert data["rows"] == [{"ID": "p1"}]

    with pytest.raises(ValueError, match="force_aa"):
        load_file(_write(tmp_path, "one2.csv", "ID\np1\n"), "force_aa")


# ── schema_mode ──────────────────────────────────────────────────────────────

def test_raw_table_mode_skips_reconstruction(tmp_path):
    aa, data = load_file(_write(tmp_path, "t.csv", _TABLE_CSV), "raw_table")
    assert aa is None
    assert len(data["rows"]) == 2


@pytest.mark.parametrize(
    "mode,expect_aa",
    [("rawTable", False), ("forceAa", True), ("auto", True)],
)
def test_camel_case_wire_modes_are_honoured(tmp_path, mode, expect_aa):
    aa, _ = load_file(_write(tmp_path, "t.csv", _TABLE_CSV), mode)
    assert (aa is not None) is expect_aa


# ── Parquet (D4M.jl wide form) → AA ──────────────────────────────────────────
#
# D4M.jl's `saveParquet` writes any string-valued Assoc (every SegForge AA is
# one) in "wide" form: a `chunkId` row-key column plus one column per D4M
# column key, with an entry's absence stored as a genuine Parquet null — see
# D4M.jl/src/Assoc/parquet_io.jl's `_saveParquetWide`. A cell absent for one
# row but present for another (e.g. a mask with no caption yet) is exactly
# how a real SegForge storage/sf/sessions/<id>/segment.parquet looks.

def _write_wide_parquet(tmp_path, name, columns):
    """`columns` is an ordered {col_name: [values...]} dict; any value may be
    None. The first key becomes the row-key column (mirrors `chunkId` when
    named that, or `_wide_table_to_aa`'s first-column fallback otherwise)."""
    import pyarrow as pa
    import pyarrow.parquet as pq

    table = pa.table(columns)
    path = tmp_path / name
    pq.write_table(table, str(path))
    return str(path)


def test_wide_parquet_with_nulls_loads_only_the_non_null_triples(tmp_path):
    path = _write_wide_parquet(tmp_path, "segment.parquet", {
        "chunkId": ["sess:mask-a", "sess:mask-b"],
        "caption": ["a red egg", None],       # mask-b never captioned
        "text_tag": [None, "figure"],          # mask-a has no text_tag
        "score": ["0.9", "0.8"],               # both scored
    })

    aa, _ = load_file(path, "auto")

    assert aa is not None
    cells = _cells(aa)
    assert cells == {
        ("sess:mask-a", "caption"): "a red egg",
        ("sess:mask-a", "score"): "0.9",
        ("sess:mask-b", "text_tag"): "figure",
        ("sess:mask-b", "score"): "0.8",
    }
    # The null cells must not appear as None/""/0 triples of their own.
    assert ("sess:mask-a", "text_tag") not in cells
    assert ("sess:mask-b", "caption") not in cells
    assert None not in aa.vals


def test_wide_parquet_row_of_all_nulls_contributes_no_triples(tmp_path):
    path = _write_wide_parquet(tmp_path, "segment.parquet", {
        "chunkId": ["sess:mask-a", "sess:mask-empty", "sess:mask-c"],
        "caption": ["a red egg", None, "a wheel"],
        "score": ["0.9", None, "0.7"],
    })

    aa, _ = load_file(path, "auto")

    assert aa is not None
    assert "sess:mask-empty" not in aa.rows
    assert set(aa.rows) == {"sess:mask-a", "sess:mask-c"}
    assert len(aa.vals) == 4  # 2 rows x 2 populated columns each


def test_wide_parquet_with_no_nulls_loads_as_before(tmp_path):
    path = _write_wide_parquet(tmp_path, "segment.parquet", {
        "chunkId": ["sess:mask-a", "sess:mask-b"],
        "caption": ["a red egg", "a wheel"],
        "score": ["0.9", "0.8"],
    })

    aa, _ = load_file(path, "auto")

    assert aa is not None
    # Dense table: every cell is a triple, nothing to filter.
    assert len(aa.vals) == 4
    assert _cells(aa) == {
        ("sess:mask-a", "caption"): "a red egg",
        ("sess:mask-a", "score"): "0.9",
        ("sess:mask-b", "caption"): "a wheel",
        ("sess:mask-b", "score"): "0.8",
    }


def test_load_route_returns_200_not_400_for_a_wide_parquet_with_nulls(tmp_path):
    """The reported bug: loading a wide, nullable-column Parquet (a real
    SegForge session file's exact shape) used to 400 with a raw pydantic
    dump — 'AssocArray ... vals.4 / vals.5 ... input_value=None'. Confirms
    the actual HTTP contract, not just the bare `load_file()` call."""
    path = _write_wide_parquet(tmp_path, "segment.parquet", {
        "chunkId": ["sess:mask-a", "sess:mask-b", "sess:mask-c"],
        "caption": ["a red egg", None, None],
        "text_tag": [None, "figure", "a wheel"],
        "score": ["0.9", "0.8", "0.7"],
    })

    r = client.post("/load", json={"filePath": path, "schemaMode": "auto"})

    assert r.status_code == 200
    body = r.json()
    assert body["parsedPayload"] is not None
    assert None not in body["parsedPayload"]["vals"]


def test_narrow_triplet_parquet_with_a_null_val_skips_that_triple(tmp_path):
    """Defensive: `_table_to_aa` (the already-narrow rowKey/colKey/val form)
    gets the same null-is-absent treatment, not just the wide pivot."""
    import pyarrow as pa
    import pyarrow.parquet as pq

    table = pa.table({
        "rowKey": ["r1", "r1", "r2"],
        "colKey": ["a", "b", "a"],
        "val": ["x", None, "y"],
    })
    path = tmp_path / "triplet.parquet"
    pq.write_table(table, str(path))

    aa, _ = load_file(str(path), "auto")

    assert aa is not None
    assert _cells(aa) == {("r1", "a"): "x", ("r2", "a"): "y"}


def test_json_triple_form_with_a_null_val_skips_that_triple(tmp_path):
    """Same null-is-absent rule applies to the JSON {rows,cols,vals} branch."""
    payload = {
        "rows": ["r1", "r1", "r2"],
        "cols": ["a", "b", "a"],
        "vals": ["x", None, "y"],
    }
    path = _write(tmp_path, "t.json", json.dumps(payload))

    aa, _ = load_file(path, "auto")

    assert aa is not None
    assert _cells(aa) == {("r1", "a"): "x", ("r2", "a"): "y"}


def test_validation_failure_after_null_filtering_gets_a_short_summary(tmp_path):
    """Item 4: something that still doesn't fit `str | int | float` after
    null-filtering (a Parquet LIST column, not a null) must not surface the
    raw multi-paragraph pydantic dump."""
    import pyarrow as pa
    import pyarrow.parquet as pq

    table = pa.table({
        "chunkId": pa.array(["r1"], type=pa.string()),
        "tags": pa.array([["a", "b"]], type=pa.list_(pa.string())),
    })
    path = tmp_path / "listcol.parquet"
    pq.write_table(table, str(path))

    r = client.post(
        "/load", json={"filePath": str(path), "schemaMode": "forceAa"}
    )

    assert r.status_code == 400
    detail = r.json()["detail"]
    assert "validation errors for AssocArray" not in detail  # not the raw dump
    assert "row=" in detail and "col=" in detail


# ── Images (.png etc.) ───────────────────────────────────────────────────────

def test_an_image_pil_cannot_introspect_still_loads_width_height_just_omitted(tmp_path):
    """Found alongside the Parquet null bug — same crash, same fix: PIL
    failing to open a file (garbage bytes with an image suffix, or a
    genuinely unsupported format) leaves width/height as None, which used
    to reach `AssocArray` unfiltered at vals[4]/vals[5] and 400."""
    path = _write(tmp_path, "not_really_a_png.png", "not really a png")

    aa, _ = load_file(path, "auto")

    assert aa is not None
    cells = _cells(aa)
    assert cells[("0", "format")] == "png"
    assert ("0", "width") not in cells
    assert ("0", "height") not in cells
    assert None not in aa.vals


# ── Plain text (.txt / .jl / .md) ────────────────────────────────────────────

@pytest.mark.parametrize("name", ["notes.txt", "model.jl", "README.md"])
def test_text_files_come_back_verbatim_as_a_single_cell_aa(tmp_path, name):
    body = "module M\n  f(x) = x + 1\nend\n"
    path = _write(tmp_path, name, body)

    aa, data = load_file(path, "auto")

    # The text goes through untouched on both routes: raw on `data`, and as one
    # AA cell so the `aa` port has the data contract downstream nodes expect.
    assert data == {"text": body}
    assert aa is not None
    # The text, plus the path so a downstream node knows what it is reading.
    assert aa.cols == ["text", "file_path"]
    assert aa.vals[0] == body
    assert aa.vals[1].endswith(name)
    assert set(aa.rows) == {"0"}, "one logical row"


def test_text_honours_schema_mode(tmp_path):
    path = _write(tmp_path, "model.jl", "x = 1\n")

    # auto / force_aa build the single-cell AA…
    assert load_file(path, "auto")[0] is not None
    assert load_file(path, "force_aa")[0] is not None
    # …raw_table withholds it: the bytes, nothing inferred.
    assert load_file(path, "raw_table")[0] is None

    # The raw representation is identical in every mode.
    for mode in ("auto", "force_aa", "raw_table"):
        assert load_file(path, mode)[1] == {"text": "x = 1\n"}


def test_the_loader_accepts_everything_the_picker_allows(tmp_path):
    # The picker's allowedExtensions, minus the structured ones covered above.
    # A selectable file the loader rejects is the bug this pins.
    for name in ("a.txt", "b.jl", "c.md"):
        aa, data = load_file(_write(tmp_path, name, "hi"), "auto")
        assert data["text"] == "hi", name


def test_a_still_unsupported_suffix_names_itself(tmp_path):
    with pytest.raises(ValueError, match=r"Unsupported file format: \.png"):
        load_file(_write(tmp_path, "image.png", "not really a png"), "auto")


def test_load_route_returns_text_for_a_julia_file(tmp_path):
    path = _write(tmp_path, "model.jl", "greet() = println(\"hi\")\n")
    response = client.post("/load", json={"filePath": path, "schemaMode": "auto"})

    assert response.status_code == 200
    body = response.json()
    source = "greet() = println(\"hi\")\n"
    # Both ports are fed: raw string on `contents`, one-cell AA on `aa`.
    assert body["contents"] == source
    assert body["parsedPayload"]["vals"][0] == source
    assert body["data"]["text"] == source


# ── JSON / missing file ──────────────────────────────────────────────────────

def test_rcvs_json_still_loads_as_aa(tmp_path):
    payload = {"rows": ["r1"], "cols": ["c1"], "vals": ["v1"]}
    aa, _ = load_file(_write(tmp_path, "a.json", json.dumps(payload)), "auto")
    assert _cells(aa) == {("r1", "c1"): "v1"}


def test_missing_file_raises(tmp_path):
    with pytest.raises(FileNotFoundError):
        load_file(str(tmp_path / "nope.csv"), "auto")


# ── /load route ──────────────────────────────────────────────────────────────

def test_load_route_returns_aa_for_a_csv(tmp_path):
    path = _write(tmp_path, "t.csv", _TABLE_CSV)
    response = client.post("/load", json={"filePath": path, "schemaMode": "auto"})

    assert response.status_code == 200
    body = response.json()
    assert body["payloadType"] == "associative_array"
    assert set(body["parsedPayload"]["cols"]) == {"GENDER", "CITY"}
    assert len(body["data"]["rows"]) == 2


def test_load_route_404s_on_a_missing_file(tmp_path):
    response = client.post(
        "/load", json={"filePath": str(tmp_path / "nope.csv"), "schemaMode": "auto"}
    )
    assert response.status_code == 404


def test_a_source_file_is_labelled_text_not_table(tmp_path):
    """`payloadType` describes the file, not whether an AA came back."""
    src = tmp_path / "selectors.jl"
    src.write_text("sw_str(s) = StartsWith(s)\n")

    body = client.post("/load", json={"filePath": str(src)}).json()

    assert body["payloadType"] == "text"
    assert "text" in body["message"]


def test_a_source_file_feeds_both_ports(tmp_path):
    """`contents` gets the raw string, `aa` gets the single-cell AA."""
    src = tmp_path / "selectors.jl"
    src.write_text("sw_str(s) = StartsWith(s)\n")

    body = client.post("/load", json={"filePath": str(src)}).json()

    # contents -> raw file string.
    assert body["contents"] == "sw_str(s) = StartsWith(s)\n"
    # aa -> a one-cell AA carrying the same text, in the shape Polyglot Exec and
    # Prompt Node already read (a `text` column).
    assert body["parsedPayload"]["cols"] == ["text", "file_path"]
    assert body["parsedPayload"]["vals"][0] == "sw_str(s) = StartsWith(s)\n"
    assert body["parsedPayload"]["vals"][1].endswith("selectors.jl")
    # `data` still carries the legacy raw representation.
    assert body["data"] == {"text": "sw_str(s) = StartsWith(s)\n"}


def test_raw_table_mode_withholds_the_text_aa(tmp_path):
    """A caller that wants the bytes and nothing inferred can say so."""
    src = tmp_path / "notes.md"
    src.write_text("# just prose\n")

    body = client.post(
        "/load", json={"filePath": str(src), "schemaMode": "rawTable"}
    ).json()

    assert body["parsedPayload"] is None
    assert body["contents"] == "# just prose\n"


def test_a_tabular_file_has_no_raw_string(tmp_path):
    """`contents` is None for Parquet/Arrow/CSV — there is no raw text form."""
    csv = tmp_path / "t.csv"
    csv.write_text("a,b\n1,2\n")

    body = client.post("/load", json={"filePath": str(csv)}).json()

    assert body["contents"] is None
    assert body["data"], "the table view still comes back on `data`"


def test_a_real_table_is_still_labelled_table(tmp_path):
    csv = tmp_path / "t.csv"
    csv.write_text("a,b\n1,2\n")
    body = client.post("/load", json={"filePath": str(csv), "schemaMode": "raw_table"}).json()
    assert body["payloadType"] == "table"
