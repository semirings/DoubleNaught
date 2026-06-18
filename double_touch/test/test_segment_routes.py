"""Route + contract tests for the DoubleTouch API.

Run with: ``pip install -e '.[dev]' && pytest`` from ``double_touch/``.
Asserts the camelCase wire contract the Flutter front-end depends on.
"""

from fastapi.testclient import TestClient

from double_touch.app import app

client = TestClient(app)


def _new_session() -> str:
    res = client.post("/session", params={"width": 800, "height": 600})
    assert res.status_code == 200
    body = res.json()
    assert body["originalWidth"] == 800  # camelCase on the wire
    return body["sessionId"]


def test_health_is_camel_case():
    body = client.get("/health").json()
    assert body["status"] == "healthy"
    assert body["activeSessions"] >= 0


def test_text_prompt_contract():
    sid = _new_session()
    res = client.post("/segment/text", json={"sessionId": sid, "prompt": "cat"})
    assert res.status_code == 200
    body = res.json()
    assert body["sessionId"] == sid
    assert body["promptKind"] == "text"
    assert "segmentMask" in body["results"]
    assert "inferenceMetrics" in body
    assert "processingTimeMs" in body["inferenceMetrics"]
    assert body["inferenceMetrics"]["maskCount"] == len(body["results"]["segmentMask"])


def test_box_prompt_include_exclude():
    sid = _new_session()
    inc = client.post(
        "/segment/box",
        json={"sessionId": sid, "box": [0.5, 0.5, 0.4, 0.4], "include": True},
    ).json()
    assert inc["promptKind"] == "box"
    assert inc["inferenceMetrics"]["maskCount"] == 1

    exc = client.post(
        "/segment/box",
        json={"sessionId": sid, "box": [0.1, 0.1, 0.2, 0.2], "include": False},
    ).json()
    # Exclusion contributes no positive mask, but is echoed as a prompted region.
    assert exc["inferenceMetrics"]["maskCount"] == 0
    assert any(not r["include"] for r in exc["results"]["promptedRegions"])


def test_point_prompt_contract():
    sid = _new_session()
    body = client.post(
        "/segment/point",
        json={"sessionId": sid, "point": [0.25, 0.75], "include": True},
    ).json()
    assert body["promptKind"] == "point"
    assert body["results"]["promptedRegions"][0]["isPoint"] is True


def test_unknown_session_is_404():
    res = client.post("/segment/text", json={"sessionId": "nope", "prompt": "x"})
    assert res.status_code == 404
