"""Route + contract tests for the FetchNode route on the DoubleTouch API.

Run with: ``pip install -e '.[dev]' && pytest`` from ``backend/``.
Asserts the camelCase wire contract, the D4M/AA output shape, and the Project
Gutenberg boilerplate stripping. The network GET is monkeypatched so the suite
stays offline and deterministic.
"""

import httpx
import pytest
from fastapi.testclient import TestClient

from double_touch import app as app_module
from double_touch.app import _strip_gutenberg, app

client = TestClient(app)

_GUTENBERG_DOC = (
    "The Project Gutenberg eBook license header ...\n"
    "*** START OF THE PROJECT GUTENBERG EBOOK THE MAN WHO WAS THURSDAY ***\n"
    "It was the real body of the book.\n"
    "*** END OF THE PROJECT GUTENBERG EBOOK THE MAN WHO WAS THURSDAY ***\n"
    "License footer ..."
)


def _url_aa(url: str = "https://gutenberg.org/x.txt", work_selector: str = "") -> dict:
    """An upstream URLNode AA, as it arrives on the wire (camelCase envelope)."""
    cols = ["url", "author", "work_title", "work_selector", "validated", "timestamp"]
    vals = [url, "chesterton", "The Man Who Was Thursday", work_selector, "true",
            "2026-01-01T00:00:00+00:00"]
    return {"rows": [url] * len(cols), "cols": cols, "vals": vals}


class _FakeResponse:
    def __init__(self, text: str, status_code: int = 200):
        self.text = text
        self.status_code = status_code

    def raise_for_status(self):
        if self.status_code >= 400:
            raise httpx.HTTPStatusError("err", request=None, response=None)


class _FakeClient:
    """Stands in for httpx.AsyncClient in the /fetch route."""

    def __init__(self, text: str, **kwargs):
        self._text = text

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False

    async def get(self, url):
        return _FakeResponse(self._text)


@pytest.fixture
def fake_get(monkeypatch):
    def _install(text: str):
        monkeypatch.setattr(
            app_module.httpx,
            "AsyncClient",
            lambda **kwargs: _FakeClient(text, **kwargs),
        )

    return _install


def test_strip_gutenberg_between_markers():
    assert _strip_gutenberg(_GUTENBERG_DOC) == "It was the real body of the book."


def test_strip_gutenberg_passthrough_for_non_gutenberg():
    assert _strip_gutenberg("just a normal webpage") == "just a normal webpage"


def test_fetch_strips_gutenberg_and_emits_aa(fake_get):
    fake_get(_GUTENBERG_DOC)
    res = client.post("/fetch", json={"workMetadata": _url_aa()})
    assert res.status_code == 200
    aa = res.json()["workMetadata"]

    body = "It was the real body of the book."

    def value(col):
        return aa["vals"][aa["cols"].index(col)]

    assert aa["cols"] == [
        "raw_text", "author", "work_title", "work_selector", "char_count", "fetch_timestamp",
    ]
    # Single chunk row, sequential id.
    assert aa["rows"] == ["chunk:00000"] * len(aa["cols"])
    assert value("raw_text") == body
    assert value("author") == "chesterton"  # carried through
    assert value("work_title") == "The Man Who Was Thursday"  # carried through
    assert value("char_count") == str(len(body))  # matches cleaned text
    assert all(isinstance(v, str) for v in aa["vals"])  # values are strings


def test_fetch_passes_work_selector_through(fake_get):
    fake_get(_GUTENBERG_DOC)
    aa = client.post(
        "/fetch", json={"workMetadata": _url_aa(work_selector="The Mikado")}
    ).json()["workMetadata"]
    assert aa["vals"][aa["cols"].index("work_selector")] == "The Mikado"


def test_fetch_general_purpose_non_gutenberg(fake_get):
    fake_get("plain page, no markers")
    aa = client.post("/fetch", json={"workMetadata": _url_aa("https://example.com")}).json()["workMetadata"]
    assert aa["vals"][aa["cols"].index("raw_text")] == "plain page, no markers"


def test_fetch_rejects_missing_url_column():
    bad = {"rows": ["r"], "cols": ["author"], "vals": ["gilbert"]}
    assert client.post("/fetch", json={"workMetadata": bad}).status_code == 422
