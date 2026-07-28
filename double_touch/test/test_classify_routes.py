"""Route + contract tests for the ModelClassifierNode route on DoubleTouch.

Run with: ``pip install -e '.[dev]' && pytest`` from ``double_touch/``.
Asserts the camelCase wire contract, the rcvs AA output shape (documents×labels
score matrix), and that the stub engine's scores react to document content. No
network or model weights involved — the default classifier is the deterministic
stub.
"""

import pytest
from fastapi.testclient import TestClient

from double_touch import app as app_module
from double_touch.app import app
from double_touch.classify import (
    LocalTransformersClassifierEngine,
    StubClassifierEngine,
    default_classifier,
    transformers_available,
)

# Force the deterministic stub so the suite is hermetic and offline even if the
# optional torch/transformers ('.[local]') deps are installed.
app_module.classifier = StubClassifierEngine()

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


def test_default_classifier_matches_environment():
    engine = default_classifier()
    assert engine.name == (
        "localTransformers" if transformers_available() else "stub"
    )


def test_local_engine_falls_back_when_deps_missing():
    # Without torch/transformers, the local engine must not crash — it degrades
    # to the deterministic (content-aware) stub. Skipped when the deps exist,
    # since then a bad model id would hit the network.
    if transformers_available():
        pytest.skip("torch/transformers installed; missing-deps path not applicable")
    engine = LocalTransformersClassifierEngine()
    scores = engine.classify(
        "a treatise on philosophy",
        ["philosophy", "sports"],
        model="some/nonexistent-model",
    )
    assert abs(sum(scores.values()) - 1.0) < 1e-6
    assert scores["philosophy"] > scores["sports"]
