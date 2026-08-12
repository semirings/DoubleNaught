"""Integration test: Arrow IPC and Parquet round-trip for D4M Associative Arrays.

Verifies the full Arrow → Parquet pipeline defined in ``aa_serializer``:

1. Synthesize a representative AA with mixed string/numeric columns.
2. Serialize to ``.aa.arrow`` via ``save_aa_arrow``.
3. Memory-map the file and assert schema validity and record integrity.
4. Convert the same AA to ``.aa.parquet`` via ``save_aa_parquet`` (ZSTD).
5. Read back from Parquet, assert exact structural and numeric equality.
6. Confirm that no ``.jsonl`` data files are emitted by the serializer
   (JSONL is reserved for Phi-4 fine-tuning export — never for AA payloads).

Run with::

    cd double_touch && pytest test/test_arrow_parquet_pipeline.py -v
"""

from __future__ import annotations

import pyarrow as pa
import pytest

from double_touch.aa_serializer import (
    AA_TRIPLET_SCHEMA,
    load_aa_arrow,
    load_aa_parquet,
    save_aa_arrow,
    save_aa_parquet,
    table_to_assoc,
)
from double_touch.models import AssocArray


# ── Fixtures ──────────────────────────────────────────────────────────────────


def _synthetic_aa() -> AssocArray:
    """Multi-row AA representative of a chunked text pipeline output.

    Columns: text (str), author (str), position (int), token_count (int),
    score (float).
    """
    chunks = [
        ("chunk:00001", "text",        "To be, or not to be"),
        ("chunk:00001", "author",      "shakespeare"),
        ("chunk:00001", "position",    1),
        ("chunk:00001", "token_count", 6),
        ("chunk:00001", "score",       0.91),
        ("chunk:00002", "text",        "All the world's a stage"),
        ("chunk:00002", "author",      "shakespeare"),
        ("chunk:00002", "position",    2),
        ("chunk:00002", "token_count", 5),
        ("chunk:00002", "score",       0.87),
        ("chunk:00003", "text",        "Friends, Romans, countrymen"),
        ("chunk:00003", "author",      "shakespeare"),
        ("chunk:00003", "position",    3),
        ("chunk:00003", "token_count", 3),
        ("chunk:00003", "score",       0.95),
    ]
    rows, cols, vals = zip(*chunks)
    return AssocArray(rows=list(rows), cols=list(cols), vals=list(vals))


@pytest.fixture()
def aa() -> AssocArray:
    return _synthetic_aa()


@pytest.fixture()
def arrow_path(tmp_path, aa):
    return save_aa_arrow(aa, tmp_path / "corpus.aa.arrow")


@pytest.fixture()
def parquet_path(tmp_path, aa):
    return save_aa_parquet(aa, tmp_path / "corpus.aa.parquet")


# ── Task 2: Arrow IPC write / schema validation ───────────────────────────────


def test_arrow_file_created(arrow_path):
    assert arrow_path.exists()
    assert arrow_path.suffix == ".arrow"


def test_arrow_schema(arrow_path):
    tbl = load_aa_arrow(arrow_path, memory_map=False)
    assert tbl.schema == AA_TRIPLET_SCHEMA, (
        f"Schema mismatch.\nExpected: {AA_TRIPLET_SCHEMA}\nGot: {tbl.schema}"
    )


def test_arrow_column_names(arrow_path):
    tbl = load_aa_arrow(arrow_path, memory_map=False)
    assert tbl.schema.names == ["rowKey", "colKey", "val", "metadata"]


def test_arrow_row_count(arrow_path, aa):
    tbl = load_aa_arrow(arrow_path, memory_map=False)
    assert len(tbl) == len(aa.rows)


# ── Task 3: Memory-mapped read ────────────────────────────────────────────────


def test_arrow_memory_map(arrow_path):
    tbl = load_aa_arrow(arrow_path, memory_map=True)
    # Arrow memory-mapped tables back a buffer directly from the file.
    # The schema and data must still be intact.
    assert tbl.schema == AA_TRIPLET_SCHEMA
    assert tbl.num_rows > 0


def test_arrow_mmap_row_keys(arrow_path, aa):
    tbl = load_aa_arrow(arrow_path, memory_map=True)
    assert tbl.column("rowKey").to_pylist() == aa.rows


def test_arrow_mmap_col_keys(arrow_path, aa):
    tbl = load_aa_arrow(arrow_path, memory_map=True)
    assert tbl.column("colKey").to_pylist() == aa.cols


def test_arrow_mmap_vals(arrow_path, aa):
    tbl = load_aa_arrow(arrow_path, memory_map=True)
    stored = tbl.column("val").to_pylist()
    expected = [str(v) for v in aa.vals]
    assert stored == expected


def test_arrow_metadata_column_empty_strings(arrow_path):
    tbl = load_aa_arrow(arrow_path, memory_map=False)
    assert all(v == "" for v in tbl.column("metadata").to_pylist())


# ── Task 4: Parquet write / read-back ─────────────────────────────────────────


def test_parquet_file_created(parquet_path):
    assert parquet_path.exists()
    assert parquet_path.suffix == ".parquet"


def test_parquet_schema(parquet_path):
    tbl = load_aa_parquet(parquet_path)
    assert tbl.schema == AA_TRIPLET_SCHEMA


def test_parquet_row_count(parquet_path, aa):
    tbl = load_aa_parquet(parquet_path)
    assert len(tbl) == len(aa.rows)


def test_parquet_row_keys_exact(parquet_path, aa):
    tbl = load_aa_parquet(parquet_path)
    assert tbl.column("rowKey").to_pylist() == aa.rows


def test_parquet_col_keys_exact(parquet_path, aa):
    tbl = load_aa_parquet(parquet_path)
    assert tbl.column("colKey").to_pylist() == aa.cols


def test_parquet_vals_exact(parquet_path, aa):
    tbl = load_aa_parquet(parquet_path)
    stored = tbl.column("val").to_pylist()
    expected = [str(v) for v in aa.vals]
    assert stored == expected


# ── Arrow ↔ Parquet structural equality ───────────────────────────────────────


def test_arrow_parquet_schema_equal(arrow_path, parquet_path):
    arrow_tbl   = load_aa_arrow(arrow_path,   memory_map=False)
    parquet_tbl = load_aa_parquet(parquet_path)
    assert arrow_tbl.schema == parquet_tbl.schema


def test_arrow_parquet_data_equal(arrow_path, parquet_path):
    arrow_tbl   = load_aa_arrow(arrow_path,   memory_map=False)
    parquet_tbl = load_aa_parquet(parquet_path)
    assert arrow_tbl.equals(parquet_tbl), (
        "Arrow and Parquet tables must contain identical data after round-trip."
    )


# ── table_to_assoc round-trip ─────────────────────────────────────────────────


def test_table_to_assoc_rows(arrow_path, aa):
    tbl = load_aa_arrow(arrow_path, memory_map=False)
    out = table_to_assoc(tbl)
    assert out.rows == aa.rows


def test_table_to_assoc_cols(arrow_path, aa):
    tbl = load_aa_arrow(arrow_path, memory_map=False)
    out = table_to_assoc(tbl)
    assert out.cols == aa.cols


def test_table_to_assoc_vals_stringified(arrow_path, aa):
    tbl = load_aa_arrow(arrow_path, memory_map=False)
    out = table_to_assoc(tbl)
    assert out.vals == [str(v) for v in aa.vals]


# ── list[dict] source path ────────────────────────────────────────────────────


def test_save_from_records(tmp_path):
    records = [
        {"rowKey": "r1", "colKey": "text", "val": "hello", "metadata": ""},
        {"rowKey": "r1", "colKey": "score", "val": "0.9",  "metadata": ""},
    ]
    path = save_aa_arrow(records, tmp_path / "records.arrow")
    tbl  = load_aa_arrow(path, memory_map=False)
    assert tbl.schema == AA_TRIPLET_SCHEMA
    assert len(tbl) == 2
    assert tbl.column("rowKey").to_pylist() == ["r1", "r1"]


# ── pa.Table source path ──────────────────────────────────────────────────────


def test_save_from_pa_table(tmp_path):
    incoming = pa.table(
        {"rowKey": ["r1"], "colKey": ["text"], "val": ["world"]},
    )
    path = save_aa_arrow(incoming, tmp_path / "from_table.arrow")
    tbl  = load_aa_arrow(path, memory_map=False)
    assert tbl.schema == AA_TRIPLET_SCHEMA
    # metadata column was added by _cast_to_schema
    assert tbl.column("metadata").to_pylist() == [""]


# ── No JSONL output from serializer ───────────────────────────────────────────


def test_no_jsonl_files_from_serializer(tmp_path, aa):
    """The serializer must never emit .jsonl files.

    JSONL is reserved for Phi-4 fine-tuning export (aa2jsonl route), not for
    AA payload persistence.
    """
    save_aa_arrow(aa,  tmp_path / "check.aa.arrow")
    save_aa_parquet(aa, tmp_path / "check.aa.parquet")
    jsonl_files = list(tmp_path.glob("**/*.jsonl"))
    assert jsonl_files == [], (
        f"Serializer emitted unexpected .jsonl files: {jsonl_files}"
    )


# ── Parquet compression is ZSTD ───────────────────────────────────────────────


def test_parquet_zstd_compression(tmp_path, aa):
    """Parquet files must use ZSTD compression (archive persistence tier)."""
    import pyarrow.parquet as pq
    path = save_aa_parquet(aa, tmp_path / "compressed.aa.parquet", compression="zstd")
    meta = pq.read_metadata(str(path))
    for rg in range(meta.num_row_groups):
        for col in range(meta.num_columns):
            codec = meta.row_group(rg).column(col).compression
            assert codec.lower() == "zstd", (
                f"Column {col} in row group {rg} uses {codec!r}, expected ZSTD"
            )


# ── Parent directory creation ─────────────────────────────────────────────────


def test_save_creates_parent_dirs(tmp_path, aa):
    nested = tmp_path / "a" / "b" / "c" / "corpus.aa.arrow"
    save_aa_arrow(aa, nested)
    assert nested.exists()


def test_save_parquet_creates_parent_dirs(tmp_path, aa):
    nested = tmp_path / "x" / "y" / "corpus.aa.parquet"
    save_aa_parquet(aa, nested)
    assert nested.exists()
