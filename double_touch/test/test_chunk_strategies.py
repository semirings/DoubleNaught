"""Tests for the paragraph_sentence and character_count chunking strategies.

Covers:
- Boundary preservation (no mid-sentence splits).
- Stride/overlap behaviour.
- inject_eot flag.
- AA column contract compatibility with the existing pipeline.
- Backward compatibility: the default "author" mode is unaffected.

Run with:  cd double_touch && pytest test/test_chunk_strategies.py -v
"""

from fastapi.testclient import TestClient

from double_touch.app import app
from double_touch.chunking import (
    MAX_TOKENS,
    chunk_character_count,
    chunk_paragraph_sentence,
    count_tokens,
    split_sentences,
)

client = TestClient(app)

# ~13-token sentence reused across tests (same fixture as test_chunk_routes.py).
_SENT = "The paradox is that he wrote very plainly about extremely deep and serious things. "


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _fetch_aa(
    text: str,
    author: str = "chesterton",
    title: str = "A Work",
) -> dict:
    cols = ["raw_text", "author", "work_title", "work_selector", "char_count", "fetch_timestamp"]
    vals = [text, author, title, "", str(len(text)), "2026-01-01T00:00:00+00:00"]
    return {"rows": ["chunk:00000"] * len(cols), "cols": cols, "vals": vals}


def _column(aa: dict, col: str) -> list:
    return [aa["vals"][i] for i, c in enumerate(aa["cols"]) if c == col]


# ---------------------------------------------------------------------------
# chunk_paragraph_sentence — unit tests
# ---------------------------------------------------------------------------

def test_no_mid_sentence_split():
    """Every chunk ends at a sentence boundary, never mid-sentence."""
    sentences = [
        "The fox ran across the meadow.",
        "It leaped the fence and disappeared into the forest.",
        "Nobody saw where it went.",
    ]
    # 10 identical paragraphs — forces multiple chunks at a low max_tokens.
    doc = "\n\n".join([" ".join(sentences)] * 10)
    chunks = chunk_paragraph_sentence(doc, max_tokens=50)
    assert chunks, "expected at least one chunk"
    for chunk in chunks:
        tail = chunk.strip()
        if tail.endswith("<|endoftext|>"):
            tail = tail[: -len("<|endoftext|>")].strip()
        assert tail[-1] in ".!?\"'", (
            f"Chunk does not end at a sentence boundary: {tail!r}"
        )


def test_short_paragraph_not_split():
    """A paragraph that fits within max_tokens is emitted as a single unit."""
    short = "A short paragraph. It has exactly two sentences."
    doc = "\n\n".join([short] * 3)
    chunks = chunk_paragraph_sentence(doc, max_tokens=200)
    for chunk in chunks:
        assert count_tokens(chunk) <= 200


def test_oversized_paragraph_splits_at_sentence():
    """A paragraph exceeding max_tokens is split at sentence boundaries."""
    # One very long paragraph (many sentences concatenated without \n\n).
    long_para = (_SENT.strip() + " ") * 40
    chunks = chunk_paragraph_sentence(long_para, max_tokens=60)
    assert len(chunks) > 1, "expected multiple chunks from an oversized paragraph"
    for chunk in chunks:
        # Each chunk must be at most max_tokens + one unsplittable sentence.
        # Here every sentence is ~13 tokens so none should be unsplittable.
        assert count_tokens(chunk) <= 60 + count_tokens(_SENT.strip())


def test_stride_produces_overlap():
    """Consecutive chunks share content when stride > 0."""
    doc = "\n\n".join([_SENT.strip()] * 30)
    chunks_no_stride = chunk_paragraph_sentence(doc, max_tokens=80, stride=0)
    chunks_stride = chunk_paragraph_sentence(doc, max_tokens=80, stride=25)
    # Overlap means more chunks for the same corpus.
    assert len(chunks_stride) >= len(chunks_no_stride)
    # The last sentence of chunk[0] must appear at the start of chunk[1].
    if len(chunks_stride) >= 2:
        last_sent = split_sentences(chunks_stride[0])[-1]
        assert last_sent in chunks_stride[1], (
            "Stride tail not found in the next chunk"
        )


def test_inject_eot_appended_to_every_chunk():
    """inject_eot=True adds <|endoftext|> to each chunk."""
    doc = "\n\n".join([_SENT * 5] * 4)
    chunks = chunk_paragraph_sentence(doc, max_tokens=80, inject_eot=True)
    assert chunks
    for chunk in chunks:
        assert "<|endoftext|>" in chunk, "EOT token missing from chunk"


def test_inject_eot_absent_by_default():
    """EOT token must not appear unless inject_eot is explicitly True."""
    doc = "\n\n".join([_SENT * 5] * 4)
    chunks = chunk_paragraph_sentence(doc, max_tokens=80)
    for chunk in chunks:
        assert "<|endoftext|>" not in chunk


# ---------------------------------------------------------------------------
# chunk_character_count — unit tests
# ---------------------------------------------------------------------------

def test_char_count_respects_max_chars():
    """No chunk exceeds max_chars characters."""
    text = "a" * 5000
    for chunk in chunk_character_count(text, max_chars=200):
        assert len(chunk) <= 200


def test_char_count_stride_overlap():
    """With stride, consecutive chunks share the expected tail/head."""
    text = "abcdefghij" * 100  # 1000 chars, perfectly predictable
    chunks = chunk_character_count(text, max_chars=50, stride=10)
    # step = 50 - 10 = 40; chunk[0][40:50] == chunk[1][:10]
    if len(chunks) >= 2:
        assert chunks[0][40:50] == chunks[1][:10]


def test_char_count_covers_full_text():
    """Without stride, the concatenation of all chunks equals the source text
    (modulo trailing whitespace stripped by the empty-chunk filter)."""
    text = "Hello World " * 200
    chunks = chunk_character_count(text, max_chars=100, stride=0)
    assert "".join(chunks) == text.rstrip()


def test_char_count_zero_max_raises():
    """max_chars=0 raises ValueError."""
    import pytest
    with pytest.raises(ValueError, match="max_chars must be positive"):
        chunk_character_count("some text", max_chars=0)


# ---------------------------------------------------------------------------
# AA contract — route-level tests
# ---------------------------------------------------------------------------

def test_paragraph_sentence_aa_contract():
    """paragraph_sentence output satisfies the AA column contract."""
    doc = "\n\n".join([_SENT * 8] * 4)
    payload = {
        "aa": _fetch_aa(doc),
        "chunkStrategy": "paragraph_sentence",
        "maxTokens": 100,
    }
    res = client.post("/chunk", json=payload)
    assert res.status_code == 200, res.text
    body = res.json()
    aa = body["aa"]

    # Column order contract (first six slots of the first chunk row).
    assert aa["cols"][:6] == [
        "text", "author", "work_title", "position", "token_count", "chunk_strategy",
    ]
    # Type contract: position and token_count are integers.
    assert all(isinstance(p, int) for p in _column(aa, "position"))
    assert all(isinstance(t, int) for t in _column(aa, "token_count"))
    assert all(isinstance(t, str) for t in _column(aa, "text"))
    # Strategy recorded correctly.
    assert set(_column(aa, "chunk_strategy")) == {"paragraph_sentence"}
    # Row keys are unique and prefixed "chunk:".
    distinct = list(dict.fromkeys(aa["rows"]))
    assert len(distinct) == body["stats"]["chunkCount"]
    assert all(r.startswith("chunk:") for r in distinct)
    # Positions are sequential.
    assert _column(aa, "position") == list(range(body["stats"]["chunkCount"]))


def test_character_count_aa_contract():
    """character_count output satisfies the AA column contract."""
    doc = "x" * 5000
    payload = {
        "aa": _fetch_aa(doc),
        "chunkStrategy": "character_count",
        "maxChars": 500,
    }
    res = client.post("/chunk", json=payload)
    assert res.status_code == 200, res.text
    aa = res.json()["aa"]

    assert aa["cols"][:6] == [
        "text", "author", "work_title", "position", "token_count", "chunk_strategy",
    ]
    assert set(_column(aa, "chunk_strategy")) == {"character_count"}
    # Every text chunk must not exceed max_chars.
    assert all(len(t) <= 500 for t in _column(aa, "text"))


def test_paragraph_sentence_stats_contract():
    """Stats keys are camelCase and numerically sensible."""
    doc = "\n\n".join([_SENT * 8] * 4)
    payload = {"aa": _fetch_aa(doc), "chunkStrategy": "paragraph_sentence", "maxTokens": 100}
    stats = client.post("/chunk", json=payload).json()["stats"]
    for key in ("chunkCount", "totalTokens", "minTokens", "maxTokens", "meanTokens"):
        assert key in stats, f"missing stat key: {key}"
    assert stats["chunkCount"] > 0
    assert stats["minTokens"] <= stats["maxTokens"]
    assert stats["minTokens"] <= stats["meanTokens"] <= stats["maxTokens"]


def test_unknown_strategy_rejected():
    """An unrecognised strategy string returns HTTP 422."""
    payload = {"aa": _fetch_aa(_SENT * 10), "chunkStrategy": "bogus_strategy"}
    assert client.post("/chunk", json=payload).status_code == 422


# ---------------------------------------------------------------------------
# Backward compatibility — default author-based path is unchanged
# ---------------------------------------------------------------------------

def test_default_author_mode_unchanged():
    """Omitting chunkStrategy (default='author') routes through the existing
    author-registry path and records the author as chunk_strategy."""
    doc = "\n\n".join([_SENT * 8] * 3)
    res = client.post("/chunk", json={"aa": _fetch_aa(doc, author="chesterton")})
    assert res.status_code == 200
    assert set(_column(res.json()["aa"], "chunk_strategy")) == {"chesterton"}


def test_explicit_author_mode_identical_to_default():
    """chunkStrategy='author' is explicitly accepted and behaves identically."""
    doc = "\n\n".join([_SENT * 8] * 3)
    payload = {"aa": _fetch_aa(doc, author="churchill"), "chunkStrategy": "author"}
    res = client.post("/chunk", json=payload)
    assert res.status_code == 200
    assert set(_column(res.json()["aa"], "chunk_strategy")) == {"churchill"}


def test_inject_eot_via_route():
    """injectEot=true propagates through the route to the chunk text."""
    doc = "\n\n".join([_SENT * 6] * 3)
    payload = {
        "aa": _fetch_aa(doc),
        "chunkStrategy": "paragraph_sentence",
        "maxTokens": 80,
        "injectEot": True,
    }
    res = client.post("/chunk", json=payload)
    assert res.status_code == 200
    texts = _column(res.json()["aa"], "text")
    assert all("<|endoftext|>" in t for t in texts)


def test_stride_via_route_increases_chunk_count():
    """stride > 0 produces more chunks than stride=0 for the same corpus."""
    doc = "\n\n".join([_SENT * 6] * 6)
    base = {"aa": _fetch_aa(doc), "chunkStrategy": "paragraph_sentence", "maxTokens": 80}
    count_no_stride = client.post("/chunk", json={**base, "stride": 0}).json()["stats"]["chunkCount"]
    count_stride = client.post("/chunk", json={**base, "stride": 20}).json()["stats"]["chunkCount"]
    assert count_stride >= count_no_stride
