"""Author-aware text chunking for ChunkNode.

Splits a cleaned document into discrete passages using a per-author *strategy*,
then enforces a shared token-range contract on the result. Strategies live in a
registry keyed by author tag, so new authors/strategies can be added **without
touching the route or the shared machinery**: subclass :class:`ChunkStrategy`,
give it a ``name``, and decorate it with :func:`register_strategy`.

The pipeline is two stages:

1. ``strategy.split(text)`` -> *natural units* (author-specific boundaries).
2. :func:`normalize_units` -> passages obeying the ``[MIN_TOKENS, MAX_TOKENS]``
   range shared by every strategy.

Token counting goes through the single :func:`count_tokens` boundary (Phi-4
aligned via tiktoken ``o200k_base``); swap it there to retarget another model.
"""

from __future__ import annotations

import re
from abc import ABC, abstractmethod
from functools import lru_cache
from typing import Optional

# Shared token-range contract for every strategy.
MIN_TOKENS = 50
MAX_TOKENS = 300


# --- Tokenizer (Phi-4 aligned) ----------------------------------------------

@lru_cache(maxsize=1)
def _encoder():
    """The tiktoken ``o200k_base`` encoder (Phi-4's tokenizer family), or None
    when tiktoken is unavailable — in which case counting falls back to a
    deterministic regex approximation so results stay *consistent*."""
    try:
        import tiktoken

        return tiktoken.get_encoding("o200k_base")
    except Exception:  # pragma: no cover - optional dependency / offline
        return None


# Fallback token pattern: word runs and standalone punctuation — a rough,
# deterministic stand-in when tiktoken is not installed.
_FALLBACK_TOKEN_RE = re.compile(r"\w+|[^\w\s]", re.UNICODE)


def count_tokens(text: str) -> int:
    """Count tokens in [text] with the Phi-4-aligned tokenizer (or fallback)."""
    enc = _encoder()
    if enc is not None:
        return len(enc.encode(text))
    return len(_FALLBACK_TOKEN_RE.findall(text))


# --- Sentence segmentation (shared) -----------------------------------------

# Break after ., !, ? plus any trailing quotes/brackets, when followed by
# whitespace. Deliberately simple and deterministic; abbreviations may over-split
# but never split *inside* a word.
_SENTENCE_END_RE = re.compile(r'(?<=[.!?])["”\'’)\]]*\s+')


def split_sentences(text: str) -> list[str]:
    """Split [text] into sentences, preserving terminal punctuation."""
    return [s.strip() for s in _SENTENCE_END_RE.split(text.strip()) if s.strip()]


# --- Work extraction (multi-work files) -------------------------------------
# A large source file can hold several complete works (e.g. the Gilbert &
# Sullivan collection is one file of many operas). ``work_selector`` marks the
# start of the target work; extraction slices from that marker to the next
# title-level marker (or EOF) before any chunking strategy runs.

_HTML_HEADING_RE = re.compile(r"<(h[1-6])\b[^>]*>(.*?)</\1\s*>", re.IGNORECASE | re.DOTALL)
_TAG_RE = re.compile(r"<[^>]+>")


def _strip_tags(fragment: str) -> str:
    return _TAG_RE.sub("", fragment)


def _extract_work_html(text: str, selector: str) -> Optional[str]:
    """Heading-based extraction for HTML sources (e.g. Gutenberg ``-h.htm``).

    Finds the ``<h1>..<h6>`` whose text contains [selector] and returns the span
    up to the next heading at the same-or-higher level (a new section/work), or
    EOF. Returns None when no heading matches (caller falls back)."""
    headings = list(_HTML_HEADING_RE.finditer(text))
    if not headings:
        return None
    selector_lower = selector.lower()
    start_pos: Optional[int] = None
    start_level = 0
    start_i = 0
    for i, match in enumerate(headings):
        if selector_lower in _strip_tags(match.group(2)).strip().lower():
            start_pos = match.start()
            start_level = int(match.group(1)[1])
            start_i = i
            break
    if start_pos is None:
        return None
    end_pos = len(text)
    for match in headings[start_i + 1 :]:
        if int(match.group(1)[1]) <= start_level:  # same-or-higher-level heading
            end_pos = match.start()
            break
    return text[start_pos:end_pos].strip()


def _is_heading_line(line: str) -> bool:
    """A plain-text title-level marker: a short, (mostly) all-uppercase line."""
    stripped = line.strip()
    if not stripped or len(stripped) > 80:
        return False
    letters = [c for c in stripped if c.isalpha()]
    return len(letters) >= 2 and all(c.isupper() for c in letters)


def _extract_work_lines(text: str, selector: str) -> Optional[str]:
    """Plain-text fallback: from the line containing [selector] to the next
    all-caps heading line (or EOF). Returns None when the selector is absent."""
    lines = text.splitlines(keepends=True)
    selector_lower = selector.lower()
    start_line: Optional[int] = None
    for i, line in enumerate(lines):
        if selector_lower in line.lower():
            start_line = i
            break
    if start_line is None:
        return None
    end_line = len(lines)
    for j in range(start_line + 1, len(lines)):
        if _is_heading_line(lines[j]):
            end_line = j
            break
    return "".join(lines[start_line:end_line]).strip()


def extract_work(text: str, work_selector: str) -> str:
    """Slice a single work out of a possibly multi-work document.

    Returns the span from the ``work_selector`` marker to the next title-level
    marker (or EOF). Behaviour:

    * empty selector -> the whole [text] (single-work file);
    * selector found -> the sliced work (HTML headings preferred, else all-caps
      lines);
    * selector provided but not found -> the whole [text] unchanged
      (best-effort, keeps the node general-purpose).
    """
    selector = work_selector.strip()
    if not selector:
        return text
    for extractor in (_extract_work_html, _extract_work_lines):
        result = extractor(text, selector)
        if result is not None:
            return result
    return text


# --- Shared token-range normalization ---------------------------------------

def _split_oversized(unit: str, max_tokens: int) -> list[str]:
    """Split a unit exceeding [max_tokens] at sentence boundaries, greedily
    packing whole sentences up to the max. A single sentence longer than
    [max_tokens] is kept intact (never split mid-sentence)."""
    if count_tokens(unit) <= max_tokens:
        return [unit]
    pieces: list[str] = []
    buf = ""
    for sent in split_sentences(unit):
        cand = f"{buf} {sent}".strip() if buf else sent
        if buf and count_tokens(cand) > max_tokens:
            pieces.append(buf)
            buf = sent
        else:
            buf = cand
    if buf:
        pieces.append(buf)
    return pieces


def normalize_units(
    units: list[str],
    min_tokens: int = MIN_TOKENS,
    max_tokens: int = MAX_TOKENS,
) -> list[str]:
    """Enforce the shared token-range contract on a strategy's natural [units].

    * A unit **below** ``min_tokens`` is merged with the next unit.
    * A unit **above** ``max_tokens`` is split at the nearest sentence boundary
      below the max.
    * A trailing fragment that still can't reach ``min_tokens`` is discarded.

    Applies to every strategy, so the author strategies only decide *where the
    natural boundaries are* — never the size bookkeeping.
    """
    # 1) Merge forward until each accumulated unit reaches the minimum.
    merged: list[str] = []
    buf = ""
    for unit in units:
        unit = unit.strip()
        if not unit:
            continue
        buf = f"{buf}\n\n{unit}" if buf else unit
        if count_tokens(buf) >= min_tokens:
            merged.append(buf)
            buf = ""
    if buf:  # trailing sub-minimum fragment
        if merged:
            merged[-1] = f"{merged[-1]}\n\n{buf}"  # fold back into the last unit
        # else: the whole document is below the minimum -> nothing survives

    # 2) Split any over-maximum unit at sentence boundaries.
    split: list[str] = []
    for unit in merged:
        split.extend(_split_oversized(unit, max_tokens))

    # 3) A split can leave a trailing sub-minimum piece; fold it back if it fits
    #    under the max, otherwise discard it (an unmergeable fragment).
    cleaned: list[str] = []
    for piece in split:
        if cleaned and count_tokens(piece) < min_tokens:
            combined = f"{cleaned[-1]}\n\n{piece}"
            if count_tokens(combined) <= max_tokens:
                cleaned[-1] = combined
            # else: drop the sub-minimum fragment
            continue
        cleaned.append(piece)
    return cleaned


# --- Generic (non-author) chunking strategies -----------------------------------

_EOT = "<|endoftext|>"


def chunk_paragraph_sentence(
    text: str,
    max_tokens: int = MAX_TOKENS,
    stride: int = 0,
    inject_eot: bool = False,
) -> list[str]:
    """Chunk text at paragraph/sentence boundaries without mid-sentence splits.

    Pipeline:
    1. Split on ``\\n\\n`` paragraph breaks.
    2. If a paragraph exceeds *max_tokens*, split it further at sentence
       boundaries using :func:`split_sentences`.
    3. Greedily pack whole sentences into a chunk up to *max_tokens*.
       A single sentence longer than *max_tokens* is kept intact — never
       truncated mid-sentence.
    4. When *stride* > 0, the last *stride*-token tail of the completed chunk
       is prepended to the next chunk as overlap context.
    5. When *inject_eot* is True, the ``<|endoftext|>`` token is appended to
       every chunk.
    """
    paragraphs = [p.strip() for p in re.split(r"\n\s*\n", text) if p.strip()]

    # Break oversized paragraphs into sentence-level units.
    units: list[str] = []
    for para in paragraphs:
        if count_tokens(para) <= max_tokens:
            units.append(para)
        else:
            units.extend(split_sentences(para))

    chunks: list[str] = []
    buf: list[str] = []
    buf_tokens = 0

    def _flush() -> None:
        nonlocal buf, buf_tokens
        chunk_text = " ".join(buf)
        if inject_eot:
            chunk_text = chunk_text + " " + _EOT
        chunks.append(chunk_text)
        # Stride: retain the last *stride*-token tail for context overlap.
        if stride > 0:
            tail: list[str] = []
            tail_tokens = 0
            for s in reversed(buf):
                s_tok = count_tokens(s)
                if tail_tokens + s_tok <= stride:
                    tail.insert(0, s)
                    tail_tokens += s_tok
                else:
                    break
            buf = tail
            buf_tokens = tail_tokens
        else:
            buf = []
            buf_tokens = 0

    for unit in units:
        unit_tokens = count_tokens(unit)
        if buf and buf_tokens + unit_tokens > max_tokens:
            _flush()
        buf.append(unit)
        buf_tokens += unit_tokens

    if buf:
        _flush()

    return chunks


def chunk_character_count(
    text: str,
    max_chars: int = 1000,
    stride: int = 0,
) -> list[str]:
    """Character-count chunking — the original fixed-window fallback.

    Splits *text* into windows of at most *max_chars* characters, advancing
    by ``max_chars - stride`` characters per step. Windows are NOT
    sentence-aligned; any character boundary is accepted.

    Raises :exc:`ValueError` when *max_chars* ≤ 0.
    """
    if max_chars <= 0:
        raise ValueError("max_chars must be positive")
    step = max(1, max_chars - stride)
    return [
        text[i : i + max_chars]
        for i in range(0, len(text), step)
        if text[i : i + max_chars].strip()
    ]


# --- Chunking pipeline (AA-compatible) ------------------------------------------

_CHUNK_COLUMNS = ["text", "author", "work_title", "position", "token_count", "chunk_strategy"]


def chunk_generic_to_aa(
    text: str,
    chunk_strategy: str,
    run_id: str = "chunk",
    author: str = "",
    work_title: str = "",
    max_tokens: int = MAX_TOKENS,
    max_chars: int = 1000,
    stride: int = 0,
    inject_eot: bool = False,
) -> tuple[list[str], list[str], list]:
    """AA pipeline for the generic *paragraph_sentence* and *character_count*
    strategies.

    Returns ``(rows, cols, vals)`` in the same format as :func:`chunk_to_aa` so
    the route layer can handle both paths identically.

    Raises :exc:`ValueError` for an unrecognised *chunk_strategy*.
    """
    if chunk_strategy == "paragraph_sentence":
        passages = chunk_paragraph_sentence(
            text, max_tokens=max_tokens, stride=stride, inject_eot=inject_eot
        )
    elif chunk_strategy == "character_count":
        passages = chunk_character_count(text, max_chars=max_chars, stride=stride)
    else:
        raise ValueError(
            f"Unknown chunk_strategy {chunk_strategy!r}; "
            "expected 'paragraph_sentence' or 'character_count'"
        )

    rows: list[str] = []
    cols: list[str] = []
    vals: list = []

    for position, passage in enumerate(passages):
        chunk_id = f"{run_id}:{position:05d}"
        tokens = count_tokens(passage)
        row_values = [passage, author, work_title, position, tokens, chunk_strategy]
        for col, value in zip(_CHUNK_COLUMNS, row_values):
            rows.append(chunk_id)
            cols.append(col)
            vals.append(value)

    return rows, cols, vals


def chunk_to_aa(
    text: str,
    author: str,
    work_title: str,
    work_selector: str = "",
    run_id: str = "chunk",
) -> tuple[list[str], list[str], list]:
    """Chunk text and return rows, cols, vals for an Associative Array.

    Returns a tuple of (rows, cols, vals) parallel lists ready to be wrapped
    in an AssocArray. Values maintain their types: strings for text/metadata,
    ints for position/token_count.
    """
    strategy = get_strategy(author.strip().lower())
    work_text = extract_work(text, work_selector)
    passages = normalize_units(strategy.split(work_text))

    rows: list[str] = []
    cols: list[str] = []
    vals: list = []

    for position, passage in enumerate(passages):
        chunk_id = f"{run_id}:{position:05d}"
        tokens = count_tokens(passage)
        row_values = [passage, author, work_title, position, tokens, "author"]
        for col, value in zip(_CHUNK_COLUMNS, row_values):
            rows.append(chunk_id)
            cols.append(col)
            vals.append(value)

    return rows, cols, vals


# --- Strategy registry ------------------------------------------------------

class ChunkStrategy(ABC):
    """Author-specific splitter. Implementations decide only *where the natural
    boundaries fall*; the shared :func:`normalize_units` enforces token sizing."""

    #: Author tag / strategy id, recorded in the AA ``chunk_strategy`` column.
    name: str = ""

    @abstractmethod
    def split(self, text: str) -> list[str]:
        """Split [text] into natural units, before token normalization."""
        raise NotImplementedError


_STRATEGIES: dict[str, ChunkStrategy] = {}


def register_strategy(cls: type[ChunkStrategy]) -> type[ChunkStrategy]:
    """Class decorator: register a strategy instance under its ``name``."""
    instance = cls()
    if not instance.name:
        raise ValueError(f"{cls.__name__} must define a non-empty name")
    _STRATEGIES[instance.name] = instance
    return cls


def get_strategy(author: str) -> ChunkStrategy:
    """Look up the strategy for [author]; raises KeyError when none is registered."""
    return _STRATEGIES[author]


def available_strategies() -> list[str]:
    """Sorted list of registered strategy names (for error messages / discovery)."""
    return sorted(_STRATEGIES)


# --- Concrete strategies ----------------------------------------------------

@register_strategy
class GilbertStrategy(ChunkStrategy):
    """Dramatic / libretto text (W. S. Gilbert). Splits on song / scene /
    exchange boundaries — stage directions, song or scene headings, and speaker
    changes — starting a new unit at each boundary so a speaker's full speech
    stays together (complete exchanges, never split mid-dialogue)."""

    name = "gilbert"

    # "NAME." / "COLONEL FAIRFAX:" at line start — a speaker cue.
    _SPEAKER_RE = re.compile(r"^[A-Z][A-Z0-9 .'\-]{1,30}[.:]")
    # A line wholly wrapped in [brackets] or (parens) — a stage direction.
    _STAGE_RE = re.compile(r"^\s*[\[(].*[\])]\s*$")
    # Song / scene / musical-number headings.
    _HEADING_RE = re.compile(
        r"^\s*(ACT|SCENE|SONG|RECITATIVE|CHORUS|SOLO|DUET|TRIO|QUARTET|FINALE|"
        r"AIR|BALLAD|No\.\s*\d+)\b",
        re.IGNORECASE,
    )

    def _is_boundary(self, line: str) -> bool:
        return bool(line) and (
            bool(self._SPEAKER_RE.match(line))
            or bool(self._STAGE_RE.match(line))
            or bool(self._HEADING_RE.match(line))
        )

    def split(self, text: str) -> list[str]:
        units: list[str] = []
        current: list[str] = []
        for raw in text.splitlines():
            if self._is_boundary(raw.strip()) and current:
                units.append("\n".join(current).strip())
                current = [raw]
            else:
                current.append(raw)
        if current:
            units.append("\n".join(current).strip())
        return [u for u in units if u]


@register_strategy
class ChestertonStrategy(ChunkStrategy):
    """Essay / prose text (G. K. Chesterton). Splits on paragraph boundaries
    (blank lines); short consecutive paragraphs are merged toward the minimum by
    :func:`normalize_units`, and sentence integrity is preserved on any max
    split."""

    name = "chesterton"

    _PARAGRAPH_RE = re.compile(r"\n\s*\n")

    def split(self, text: str) -> list[str]:
        return [p.strip() for p in self._PARAGRAPH_RE.split(text) if p.strip()]


@register_strategy
class ChurchillStrategy(ChunkStrategy):
    """Oratorical prose (Winston Churchill). Groups sentences into *periodic
    clusters*: a run of clause-building sentences (semicolons, colons, em-dashes)
    is kept together with the sentence that resolves the build to a full stop, so
    a periodic sentence is never split mid-build."""

    name = "churchill"

    # Clause-building punctuation that signals an unresolved periodic build.
    _BUILD_RE = re.compile(r"[;:—]|--")

    def split(self, text: str) -> list[str]:
        clusters: list[str] = []
        current: list[str] = []
        for sentence in split_sentences(text):
            current.append(sentence)
            # A sentence with no build punctuation resolves the periodic cluster.
            if not self._BUILD_RE.search(sentence):
                clusters.append(" ".join(current))
                current = []
        if current:
            clusters.append(" ".join(current))
        return [c.strip() for c in clusters if c.strip()]
