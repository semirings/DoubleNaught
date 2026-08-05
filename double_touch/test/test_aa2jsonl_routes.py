"""Route + contract tests for the AA2JSONLNode route on the DoubleTouch API.

Run with: ``pip install -e '.[dev]' && pytest`` from ``double_touch/``.
Asserts the camelCase wire contract, both Phi-4 formats, JSONL validity, skip
handling, the provenance AA, and the file actually written to disk (pytest's
``tmp_path`` keeps writes isolated).
"""

import json

from fastapi.testclient import TestClient

from double_touch.app import app

client = TestClient(app)


def _chunk_aa(passages, author: str = "chesterton", title: str = "Orthodoxy") -> dict:
    """A ChunkNode-style output AA (multi-row, integer position/token_count)."""
    rows, cols, vals = [], [], []
    columns = ["text", "author", "work_title", "position", "token_count", "chunk_strategy"]
    for i, passage in enumerate(passages):
        chunk_id = f"chunk:run0:{i:05d}"
        row_vals = [passage, author, title, i, len(passage.split()), "chesterton"]
        for col, val in zip(columns, row_vals):
            rows.append(chunk_id)
            cols.append(col)
            vals.append(val)
    return {"rows": rows, "cols": cols, "vals": vals}


def _column(aa: dict, name: str) -> list:
    return [aa["vals"][i] for i, c in enumerate(aa["cols"]) if c == name]


def test_instruction_completion_format(tmp_path):
    out = tmp_path / "train.jsonl"
    aa = _chunk_aa(["First passage.", "Second passage."])
    res = client.post(
        "/aa2jsonl",
        json={"aa": aa, "outputFile": str(out), "format": "instruction-completion"},
    )
    assert res.status_code == 200
    body = res.json()

    # Stats (camelCase).
    assert body["stats"]["linesWritten"] == 2
    assert body["stats"]["skipped"] == 0
    assert body["stats"]["outputFile"] == str(out)
    assert body["stats"]["fileSizeBytes"] > 0

    # File written, each line valid JSON in the instruction-completion shape.
    lines = out.read_text().splitlines()
    assert len(lines) == 2
    obj = json.loads(lines[0])
    assert obj == {"prompt": "Write in the GCC voice:", "completion": "First passage."}


def test_continuation_format(tmp_path):
    out = tmp_path / "cont.jsonl"
    res = client.post(
        "/aa2jsonl",
        json={"aa": _chunk_aa(["Alpha.", "Beta."]), "outputFile": str(out), "format": "continuation"},
    )
    assert res.status_code == 200
    assert json.loads(out.read_text().splitlines()[0]) == {"text": "Alpha."}


def test_output_aa_preserves_provenance(tmp_path):
    out = tmp_path / "p.jsonl"
    aa = _chunk_aa(["one", "two", "three"])
    body = client.post(
        "/aa2jsonl",
        json={"aa": aa, "outputFile": str(out), "format": "continuation"},
    ).json()
    result = body["aa"]

    # Columns per contract.
    assert result["cols"][:5] == [
        "jsonl_line", "format", "output_file", "write_timestamp", "status",
    ]
    # Each source chunkID is retained in the output AA (full provenance chain).
    src_ids = list(dict.fromkeys(_chunk_aa(["one", "two", "three"])["rows"]))
    assert list(dict.fromkeys(result["rows"])) == src_ids
    assert set(_column(result, "format")) == {"continuation"}
    assert set(_column(result, "status")) == {"written"}


def test_empty_text_is_skipped(tmp_path):
    out = tmp_path / "skip.jsonl"
    aa = _chunk_aa(["real text here", "   ", "more real text"])
    body = client.post(
        "/aa2jsonl",
        json={"aa": aa, "outputFile": str(out), "format": "continuation"},
    ).json()
    assert body["stats"]["linesWritten"] == 2
    assert body["stats"]["skipped"] == 1
    # Only non-skipped lines are written to the file.
    assert len(out.read_text().splitlines()) == 2
    # Provenance AA still has all three rows; middle one marked skipped.
    assert _column(body["aa"], "status") == ["written", "skipped", "written"]


def test_rows_written_in_position_order(tmp_path):
    out = tmp_path / "order.jsonl"
    # Build an AA whose triples are shuffled but positions define the order.
    aa = _chunk_aa(["p0", "p1", "p2"])
    # Reverse the row groups on the wire; position column must still drive order.
    groups = [aa["rows"][i:i + 6] for i in range(0, len(aa["rows"]), 6)]
    order = [2, 0, 1]
    def regroup(seq):
        g = [seq[i:i + 6] for i in range(0, len(seq), 6)]
        return [x for k in order for x in g[k]]
    shuffled = {"rows": regroup(aa["rows"]), "cols": regroup(aa["cols"]), "vals": regroup(aa["vals"])}
    body = client.post(
        "/aa2jsonl",
        json={"aa": shuffled, "outputFile": str(out), "format": "continuation"},
    ).json()
    texts = [json.loads(l)["text"] for l in out.read_text().splitlines()]
    assert texts == ["p0", "p1", "p2"]  # sorted back into position order


def test_generic_aa_with_raw_text_column(tmp_path):
    # General-purpose: a FetchNode-style AA (raw_text column) also works.
    out = tmp_path / "generic.jsonl"
    aa = {
        "rows": ["chunk:00000"] * 2,
        "cols": ["raw_text", "author"],
        "vals": ["Some cleaned body text.", "gilbert"],
    }
    res = client.post(
        "/aa2jsonl",
        json={"aa": aa, "outputFile": str(out), "format": "continuation"},
    )
    assert res.status_code == 200
    assert json.loads(out.read_text().splitlines()[0]) == {"text": "Some cleaned body text."}


def test_unknown_format_rejected(tmp_path):
    res = client.post(
        "/aa2jsonl",
        json={"aa": _chunk_aa(["x"]), "outputFile": str(tmp_path / "x.jsonl"), "format": "bogus"},
    )
    assert res.status_code == 422


def test_empty_path_rejected():
    res = client.post(
        "/aa2jsonl",
        json={"aa": _chunk_aa(["x"]), "outputFile": "  ", "format": "continuation"},
    )
    assert res.status_code == 422


def test_missing_text_column_rejected(tmp_path):
    bad = {"rows": ["r"], "cols": ["author"], "vals": ["gilbert"]}
    res = client.post(
        "/aa2jsonl",
        json={"aa": bad, "outputFile": str(tmp_path / "x.jsonl"), "format": "continuation"},
    )
    assert res.status_code == 422


def test_creates_parent_directories(tmp_path):
    out = tmp_path / "nested" / "deep" / "train.jsonl"
    res = client.post(
        "/aa2jsonl",
        json={"aa": _chunk_aa(["hello"]), "outputFile": str(out), "format": "continuation"},
    )
    assert res.status_code == 200
    assert out.exists()
