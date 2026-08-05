"""Route + contract tests for the ReviewNode routes on the DoubleTouch API.

Run with: ``pip install -e '.[dev]' && pytest`` from ``double_touch/``.
Asserts the camelCase wire contract, decision tracking, disk persistence /
resume, the output audit AA (including original_text / edit_flag semantics), and
per-status forwarding. ``review_store`` is pointed at a tmp dir so no repo state
is written.
"""

import pytest
from fastapi.testclient import TestClient

from double_touch import app as app_module
from double_touch.app import app
from double_touch.review import ReviewStore, is_forwarded

client = TestClient(app)


@pytest.fixture(autouse=True)
def isolated_store(tmp_path):
    """Point the module-level review store at a temp dir for each test."""
    original = app_module.review_store
    app_module.review_store = ReviewStore(base_dir=str(tmp_path / "reviews"))
    yield
    app_module.review_store = original


def _chunk_aa(passages, author="gilbert", title="Yeomen"):
    rows, cols, vals = [], [], []
    columns = ["text", "author", "work_title", "position", "token_count", "chunk_strategy"]
    for i, p in enumerate(passages):
        chunk_id = f"chunk:runX:{i:05d}"
        for col, val in zip(columns, [p, author, title, i, len(p.split()), "gilbert"]):
            rows.append(chunk_id)
            cols.append(col)
            vals.append(val)
    return {"rows": rows, "cols": cols, "vals": vals}


def _column(aa, name):
    return [aa["vals"][i] for i, c in enumerate(aa["cols"]) if c == name]


def _start(passages):
    body = client.post("/review/start", json={"aa": _chunk_aa(passages)}).json()
    return body["reviewId"], [p["chunkId"] for p in body["passages"]]


def test_start_returns_camel_case_session():
    rid, cids = _start(["First passage.", "Second passage."])
    body = client.get(f"/review/session/{rid}").json()
    assert body["reviewId"] == rid
    assert body["complete"] is False
    assert body["counts"]["pending"] == 2
    assert set(body["passages"][0].keys()) >= {
        "chunkId", "text", "author", "workTitle", "position", "tokenCount",
        "chunkStrategy", "status", "editedText", "reviewTimestamp",
    }


def test_start_is_idempotent_resume():
    aa = _chunk_aa(["alpha", "beta"])
    first = client.post("/review/start", json={"aa": aa}).json()
    # Decide one, then re-start the same content: decisions must be preserved.
    client.post("/review/decision", json={
        "reviewId": first["reviewId"], "chunkId": first["passages"][0]["chunkId"],
        "status": "approved",
    })
    again = client.post("/review/start", json={"aa": aa}).json()
    assert again["reviewId"] == first["reviewId"]
    assert again["counts"]["approved"] == 1


def test_decision_tracking_and_completion():
    rid, cids = _start(["a", "b", "c", "d"])
    client.post("/review/decision", json={"reviewId": rid, "chunkId": cids[0], "status": "approved"})
    client.post("/review/decision", json={"reviewId": rid, "chunkId": cids[1], "status": "edited", "editedText": "B!"})
    client.post("/review/decision", json={"reviewId": rid, "chunkId": cids[2], "status": "rejected"})
    body = client.post("/review/decision", json={"reviewId": rid, "chunkId": cids[3], "status": "approved"}).json()
    assert body["complete"] is True
    assert body["counts"] == {"total": 4, "approved": 2, "edited": 1, "rejected": 1, "pending": 0}


def test_persistence_survives_new_store(tmp_path):
    # Simulate an interruption: decide, drop the in-process store, reload from disk.
    dir_ = str(tmp_path / "persist")
    app_module.review_store = ReviewStore(base_dir=dir_)
    rid, cids = _start(["one", "two"])
    client.post("/review/decision", json={"reviewId": rid, "chunkId": cids[0], "status": "approved"})
    # A brand-new store reading the same dir must see the saved decision.
    app_module.review_store = ReviewStore(base_dir=dir_)
    resumed = client.get(f"/review/session/{rid}").json()
    assert resumed["counts"]["approved"] == 1
    assert resumed["passages"][0]["status"] == "approved"


def test_output_aa_edit_semantics():
    rid, cids = _start(["keep me", "change me", "drop me"])
    client.post("/review/decision", json={"reviewId": rid, "chunkId": cids[0], "status": "approved"})
    client.post("/review/decision", json={"reviewId": rid, "chunkId": cids[1], "status": "edited", "editedText": "changed text"})
    client.post("/review/decision", json={"reviewId": rid, "chunkId": cids[2], "status": "rejected"})

    out = client.get(f"/review/output/{rid}").json()["aa"]
    assert out["cols"][:9] == [
        "text", "original_text", "author", "work_title", "position",
        "token_count", "review_status", "edit_flag", "review_timestamp",
    ]
    assert _column(out, "review_status") == ["approved", "edited", "rejected"]
    assert _column(out, "edit_flag") == ["false", "true", "false"]
    # Edited row: text is the edit, original_text preserves the pre-edit text.
    assert _column(out, "text") == ["keep me", "changed text", "drop me"]
    assert _column(out, "original_text") == ["", "change me", ""]
    # Rejected row is retained in the audit AA...
    assert "rejected" in _column(out, "review_status")
    # ...but is not forwarded downstream.
    assert is_forwarded("approved") and is_forwarded("edited")
    assert not is_forwarded("rejected")
    # position / token_count are integers.
    assert all(isinstance(x, int) for x in _column(out, "position"))
    assert all(isinstance(x, int) for x in _column(out, "token_count"))


def test_output_only_includes_decided_passages():
    rid, cids = _start(["decided", "still pending"])
    client.post("/review/decision", json={"reviewId": rid, "chunkId": cids[0], "status": "approved"})
    out = client.get(f"/review/output/{rid}").json()["aa"]
    # Only the one decided passage appears.
    assert list(dict.fromkeys(out["rows"])) == [cids[0]]


def test_general_purpose_raw_text_column():
    aa = {"rows": ["chunk:00000"] * 2, "cols": ["raw_text", "author"], "vals": ["Body text.", "gilbert"]}
    body = client.post("/review/start", json={"aa": aa}).json()
    assert body["passages"][0]["text"] == "Body text."


def test_bad_status_rejected():
    rid, cids = _start(["x"])
    res = client.post("/review/decision", json={"reviewId": rid, "chunkId": cids[0], "status": "maybe"})
    assert res.status_code == 422


def test_unknown_chunk_and_session():
    rid, cids = _start(["x"])
    assert client.post("/review/decision", json={"reviewId": rid, "chunkId": "nope", "status": "approved"}).status_code == 404
    assert client.get("/review/session/review-missing").status_code == 404
    assert client.get("/review/output/review-missing").status_code == 404


def test_start_without_text_column_rejected():
    aa = {"rows": ["r"], "cols": ["author"], "vals": ["gilbert"]}
    assert client.post("/review/start", json={"aa": aa}).status_code == 422
