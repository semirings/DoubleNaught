"""Route + contract tests for the URLNode routes on the DoubleTouch API.

Run with: ``pip install -e '.[dev]' && pytest`` from ``backend/``.
Asserts the camelCase wire contract and the D4M/AA payload shape the Flutter
front-end depends on. Network-free: the reachability probe is only exercised on
inputs that fail before any socket is opened (empty / malformed URL).
"""

from fastapi.testclient import TestClient

from double_touch.app import app

client = TestClient(app)


def test_url_payload_aa_contract():
    res = client.post(
        "/url/payload",
        json={
            "nodeId": "7",
            "url": "https://example.com/thursday",
            "author": "chesterton",
            "workTitle": "The Man Who Was Thursday",
            "validated": True,
        },
    )
    assert res.status_code == 200
    body = res.json()
    assert body["nodeId"] == "7"  # camelCase on the wire

    aa = body["aa"]

    def value(col):
        return aa["vals"][aa["cols"].index(col)]

    # 1-row AA: every triple's row is the node id.
    assert aa["cols"] == [
        "url", "author", "work_title", "work_selector", "validated", "timestamp",
    ]
    assert aa["rows"] == ["7"] * len(aa["cols"])
    # All values are strings; validated is stringified; timestamp is ISO-8601.
    assert all(isinstance(v, str) for v in aa["vals"])
    assert value("url") == "https://example.com/thursday"
    assert value("author") == "chesterton"
    assert value("work_title") == "The Man Who Was Thursday"
    assert value("validated") == "true"
    assert value("timestamp").startswith("20")  # ISO timestamp


def test_url_payload_validated_false_is_string():
    body = client.post(
        "/url/payload",
        json={
            "nodeId": "1",
            "url": "http://x",
            "author": "gilbert",
            "workTitle": "t",
            "validated": False,
        },
    ).json()
    aa = body["aa"]
    assert aa["vals"][aa["cols"].index("validated")] == "false"


def test_url_payload_includes_work_selector():
    # work_selector is carried when supplied...
    body = client.post(
        "/url/payload",
        json={
            "nodeId": "1",
            "url": "http://x",
            "author": "gilbert",
            "workTitle": "Collected Operas",
            "workSelector": "The Mikado",
            "validated": True,
        },
    ).json()
    aa = body["aa"]
    assert aa["vals"][aa["cols"].index("work_selector")] == "The Mikado"

    # ...and defaults to "" when omitted (single-work files).
    body2 = client.post(
        "/url/payload",
        json={"nodeId": "1", "url": "http://x", "author": "gilbert", "workTitle": "t"},
    ).json()
    aa2 = body2["aa"]
    assert aa2["vals"][aa2["cols"].index("work_selector")] == ""


def test_url_payload_rejects_unknown_author():
    res = client.post(
        "/url/payload",
        json={
            "nodeId": "1",
            "url": "http://x",
            "author": "tolkien",
            "workTitle": "t",
            "validated": False,
        },
    )
    assert res.status_code == 422


def test_url_validate_rejects_empty_url():
    assert client.post("/url/validate", json={"url": "   "}).status_code == 422


def test_url_validate_unreachable_does_not_raise():
    # A malformed URL fails the probe without a network round-trip; the route
    # must still answer 200 with reachable=false and a detail string.
    body = client.post("/url/validate", json={"url": "not-a-url"}).json()
    assert body["reachable"] is False
    assert body["detail"]
