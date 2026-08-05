"""Route + contract tests for the ChunkNode route on the DoubleTouch API.

Run with: ``pip install -e '.[dev]' && pytest`` from ``double_touch/``.
Asserts the camelCase wire contract, the D4M/AA output shape (including integer
columns), the shared token-range contract, and per-author strategy selection.
Offline: chunking is pure-CPU, no network.
"""

from fastapi.testclient import TestClient

from double_touch.app import app
from double_touch.chunking import (
    MAX_TOKENS,
    MIN_TOKENS,
    ChunkStrategy,
    available_strategies,
    count_tokens,
    extract_work,
    normalize_units,
    register_strategy,
)

client = TestClient(app)

# A sentence of ~13 tokens; repeat to build documents over the minimum.
_SENT = "The paradox is that he wrote very plainly about extremely deep and serious things. "


def _fetch_aa(text: str, author: str, title: str = "A Work", work_selector: str = "") -> dict:
    """A FetchNode AA as it arrives on the wire."""
    cols = ["raw_text", "author", "work_title", "work_selector", "char_count", "fetch_timestamp"]
    vals = [text, author, title, work_selector, str(len(text)), "2026-01-01T00:00:00+00:00"]
    return {"rows": ["chunk:00000"] * len(cols), "cols": cols, "vals": vals}


def _column(aa: dict, col: str) -> list:
    """All values stored under [col], in row order."""
    return [aa["vals"][i] for i, c in enumerate(aa["cols"]) if c == col]


def test_chunk_aa_contract_and_integer_columns():
    doc = "\n\n".join([_SENT * 8, _SENT * 8, _SENT * 8])
    res = client.post("/chunk", json={"aa": _fetch_aa(doc, "chesterton", "Orthodoxy")})
    assert res.status_code == 200
    body = res.json()
    aa = body["aa"]

    # Columns present and in contract order (per chunk).
    assert aa["cols"][:6] == [
        "text", "author", "work_title", "position", "token_count", "chunk_strategy",
    ]

    # position / token_count are integers on the wire; the rest are strings.
    assert all(isinstance(p, int) for p in _column(aa, "position"))
    assert all(isinstance(t, int) for t in _column(aa, "token_count"))
    assert all(isinstance(t, str) for t in _column(aa, "text"))

    # position is sequential 0..N-1.
    assert _column(aa, "position") == list(range(body["stats"]["chunkCount"]))

    # chunk_strategy records the applied strategy for auditability.
    assert set(_column(aa, "chunk_strategy")) == {"chesterton"}

    # Row keys are sequential and globally unique (run-id prefixed).
    distinct = list(dict.fromkeys(aa["rows"]))
    assert len(distinct) == body["stats"]["chunkCount"]
    assert all(r.startswith("chunk:") for r in distinct)


def test_chunk_stats_are_camel_case():
    doc = _SENT * 30
    stats = client.post("/chunk", json={"aa": _fetch_aa(doc, "chesterton")}).json()["stats"]
    for key in ("chunkCount", "totalTokens", "minTokens", "maxTokens", "meanTokens"):
        assert key in stats


def test_token_range_contract_enforced():
    # A long single-author document; every chunk must respect [MIN, MAX] (the
    # backend counts with the same tokenizer we assert against).
    doc = "\n\n".join([_SENT * 6] * 12)
    aa = client.post("/chunk", json={"aa": _fetch_aa(doc, "chesterton")}).json()["aa"]
    texts = _column(aa, "text")
    assert texts, "expected at least one chunk"
    for t in texts:
        assert count_tokens(t) >= MIN_TOKENS
        # <= MAX except an unsplittable single sentence (not the case here).
        assert count_tokens(t) <= MAX_TOKENS


def test_strategy_selected_by_author():
    doc = _SENT * 30
    for author in ("gilbert", "chesterton", "churchill"):
        aa = client.post("/chunk", json={"aa": _fetch_aa(doc, author)}).json()["aa"]
        assert set(_column(aa, "chunk_strategy")) == {author}


def test_author_tag_is_case_insensitive():
    doc = _SENT * 20
    res = client.post("/chunk", json={"aa": _fetch_aa(doc, "Chesterton")})
    assert res.status_code == 200
    assert set(_column(res.json()["aa"], "chunk_strategy")) == {"chesterton"}


def test_unknown_author_rejected():
    assert client.post("/chunk", json={"aa": _fetch_aa("x", "tolkien")}).status_code == 422


def test_missing_raw_text_rejected():
    bad = {"rows": ["r"], "cols": ["author"], "vals": ["gilbert"]}
    assert client.post("/chunk", json={"aa": bad}).status_code == 422


# --- work_selector: extract the target work before chunking -----------------

# A multi-work HTML document: two "operas" as sibling <h2> headings.
_MULTI_WORK_HTML = (
    "<h1>Collected Operas</h1>"
    "<h2>The Sorcerer</h2>" + f"<p>{_SENT * 10}</p>"
    "<h2>The Mikado</h2>" + f"<p>{_SENT * 10}</p>"
    "<h2>The Gondoliers</h2>" + f"<p>{_SENT * 10}</p>"
)


def test_extract_work_unit():
    # HTML heading-based slicing keeps only the selected work.
    mikado = extract_work(_MULTI_WORK_HTML, "The Mikado")
    assert mikado.startswith("<h2>The Mikado")
    assert "Gondoliers" not in mikado and "Sorcerer" not in mikado
    # Empty selector -> whole document; unknown selector -> whole document.
    assert extract_work(_MULTI_WORK_HTML, "") == _MULTI_WORK_HTML
    assert extract_work(_MULTI_WORK_HTML, "No Such Opera") == _MULTI_WORK_HTML


def test_chunk_uses_work_selector_to_scope_extraction():
    # Chunking the whole file yields more chunks than chunking one extracted work.
    whole = client.post(
        "/chunk", json={"aa": _fetch_aa(_MULTI_WORK_HTML, "chesterton", "Collected")}
    ).json()
    scoped = client.post(
        "/chunk",
        json={
            "aa": _fetch_aa(
                _MULTI_WORK_HTML, "chesterton", "Collected", work_selector="The Mikado"
            )
        },
    ).json()
    assert scoped["stats"]["chunkCount"] < whole["stats"]["chunkCount"]
    # None of the scoped chunk text leaks from the sibling works.
    scoped_text = " ".join(_column(scoped["aa"], "text"))
    assert "Gondoliers" not in scoped_text and "Sorcerer" not in scoped_text


def test_normalize_discards_unmergeable_sub_minimum():
    # Three tiny units well under the minimum with nothing to merge into -> the
    # combined text stays below MIN_TOKENS, so nothing survives.
    assert normalize_units(["A short bit.", "Another.", "Tiny."]) == []


def test_normalize_merges_toward_minimum():
    units = [_SENT] * 8  # each ~13 tokens; merged they clear the minimum
    chunks = normalize_units(units)
    assert chunks
    assert all(count_tokens(c) >= MIN_TOKENS for c in chunks)


def test_registry_is_extensible_without_restructuring():
    # A new strategy can be added purely by registering it — proof the node is
    # architected for extension.
    @register_strategy
    class _DickensStrategy(ChunkStrategy):
        name = "dickens"

        def split(self, text: str) -> list[str]:
            return [text]

    try:
        assert "dickens" in available_strategies()
        doc = _SENT * 20
        aa = client.post("/chunk", json={"aa": _fetch_aa(doc, "dickens")}).json()["aa"]
        assert set(_column(aa, "chunk_strategy")) == {"dickens"}
    finally:
        # Keep the global registry clean for other tests.
        from double_touch import chunking

        chunking._STRATEGIES.pop("dickens", None)
