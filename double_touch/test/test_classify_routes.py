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


def _scores(classificationScores, doc_id):
    return {
        c: v
        for r, c, v in zip(classificationScores["rows"], classificationScores["cols"], classificationScores["vals"])
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
    classificationScores = resp.json()["classificationScores"]

    # Original metadata (1 text triple) + 2 score triples per doc × 2 docs = 6.
    assert len(classificationScores["rows"]) == len(classificationScores["cols"]) == len(classificationScores["vals"]) == 6
    assert set(classificationScores["cols"]) == {"text", "score:philosophy", "score:sports"}

    s1, s2 = _scores(classificationScores, "doc:1"), _scores(classificationScores, "doc:2")
    # Score columns form a distribution per document.
    score_vals_1 = [v for k, v in s1.items() if k.startswith("score:")]
    score_vals_2 = [v for k, v in s2.items() if k.startswith("score:")]
    assert abs(sum(score_vals_1) - 1.0) < 1e-6
    assert abs(sum(score_vals_2) - 1.0) < 1e-6
    # Content-aware: each document leans toward its matching label.
    assert s1["score:philosophy"] > s1["score:sports"]
    assert s2["score:sports"] > s2["score:philosophy"]


def test_classify_rejects_empty_labels():
    resp = client.post("/classify", json=_body([], [("doc:1", "text")]))
    assert resp.status_code == 422


def _categories_classificationScores(cats):
    """A categories AA on the wire: cats = list of (label, template, threshold)."""
    rows, cols, vals = [], [], []
    for i, (label, template, threshold) in enumerate(cats):
        row = f"cat:{i}"
        for col, val in (
            ("label", label),
            ("hypothesis_template", template),
            ("threshold", threshold),
        ):
            rows.append(row)
            cols.append(col)
            vals.append(val)
    return {"rows": rows, "cols": cols, "vals": vals}


def test_classify_categories_supersede_labels_and_flag_passed():
    body = _body([], [("doc:1", "A treatise on philosophy and metaphysics.")])
    # Flat labels are ignored; the categories AA supplies the candidate labels.
    body["categories"] = _categories_classificationScores(
        [
            ("philosophy", "This passage is {}", 0.1),
            ("sports", "This passage is {}", 0.9),
        ]
    )
    resp = client.post("/classify", json=body)
    assert resp.status_code == 200
    classificationScores = resp.json()["classificationScores"]

    scores = _scores(classificationScores, "doc:1")
    # Category `label`s become score: columns; original text is preserved.
    assert {"text", "score:philosophy", "score:sports", "passed"} == set(scores)
    # philosophy clears its low 0.1 threshold; sports cannot clear 0.9.
    assert "philosophy" in scores["passed"]
    assert "sports" not in scores["passed"]


def test_classify_accepts_dense_categories_classificationScores():
    # The shape of storage/categories/categories.json: rows/cols are the axes
    # and vals is a flattened rows×cols matrix (dense, not sparse triples).
    body = _body([], [("doc:1", "A grandiloquent rhetorical oration.")])
    body["categories"] = {
        "rows": ["cat:rhetorical", "cat:periodic", "cat:primitive"],
        "cols": ["label", "hypothesis_template", "threshold"],
        "vals": [
            "grandiloquent rhetorical speech", "This passage is {}", 0.1,
            "balanced periodic sentence", "This passage is {}", 0.9,
            "direct primitive narrative", "This passage is {}", 0.9,
        ],
    }
    resp = client.post("/classify", json=body)
    assert resp.status_code == 200
    classificationScores = resp.json()["classificationScores"]

    scores = _scores(classificationScores, "doc:1")
    # All three category labels are recovered as score: columns (spaces → _);
    # original text triple is preserved; passed carries bare label names.
    assert {
        "text",
        "score:grandiloquent_rhetorical_speech",
        "score:balanced_periodic_sentence",
        "score:direct_primitive_narrative",
        "passed",
    } == set(scores)
    assert "grandiloquent rhetorical speech" in scores["passed"]


def test_classify_rejects_categories_without_labels():
    body = _body([], [("doc:1", "text")])
    # A categories AA with rows but no usable `label` column -> no candidates.
    body["categories"] = {
        "rows": ["cat:0"],
        "cols": ["threshold"],
        "vals": [0.5],
    }
    resp = client.post("/classify", json=body)
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
