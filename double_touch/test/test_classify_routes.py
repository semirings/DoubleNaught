"""Route + contract tests for the ModelClassifierNode route on DoubleTouch.

Run with: ``pip install -e '.[dev]' && pytest`` from ``double_touch/``.
Asserts the camelCase wire contract, the rcvs AA output shape (documents×labels
score matrix), and that the stub engine's scores react to document content. No
network or model weights involved — the default classifier is the deterministic
stub.
"""

from fastapi.testclient import TestClient

from double_touch.app import app

client = TestClient(app)


def _body(labels, docs):
    """A /classify request as it arrives on the wire (camelCase envelope)."""
    rows, cols, vals = [], [], []
    for doc_id, text in docs:
        rows.append(doc_id)
        cols.append("text")
        vals.append(text)
    return {
        "model": "MoritzLaurer/ModernBERT-large-zeroshot-v2.0",
        "sourceType": "huggingface",
        "task": "zero-shot-classification",
        "labels": labels,
        "documents": {"rows": rows, "cols": cols, "vals": vals},
    }


def _scores(aa, doc_id):
    return {
        c: v
        for r, c, v in zip(aa["rows"], aa["cols"], aa["vals"])
        if r == doc_id
    }


def test_classify_shape_and_content():
    resp = client.post(
        "/classify",
        json=_body(
            ["philosophy", "sports"],
            [
                ("doc:1", "A treatise on philosophy and metaphysics."),
                ("doc:2", "A thrilling sports match with a last-minute goal."),
            ],
        ),
    )
    assert resp.status_code == 200
    aa = resp.json()["aa"]

    # One triple per (document, label): 2 docs x 2 labels = 4.
    assert len(aa["rows"]) == len(aa["cols"]) == len(aa["vals"]) == 4
    assert set(aa["cols"]) == {"philosophy", "sports"}

    s1, s2 = _scores(aa, "doc:1"), _scores(aa, "doc:2")
    # Scores form a distribution per document.
    assert abs(sum(s1.values()) - 1.0) < 1e-6
    assert abs(sum(s2.values()) - 1.0) < 1e-6
    # Content-aware: each document leans toward its matching label.
    assert s1["philosophy"] > s1["sports"]
    assert s2["sports"] > s2["philosophy"]


def test_classify_rejects_empty_labels():
    resp = client.post("/classify", json=_body([], [("doc:1", "text")]))
    assert resp.status_code == 422


def test_classify_rejects_empty_documents():
    resp = client.post(
        "/classify",
        json={
            "model": "m",
            "labels": ["a", "b"],
            "documents": {"rows": [], "cols": [], "vals": []},
        },
    )
    assert resp.status_code == 422
