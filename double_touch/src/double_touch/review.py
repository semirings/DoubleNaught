"""Persistent review-session state and logic for ReviewNode.

A review session pairs the candidate passages (from a ChunkNode AA) with the
user's per-passage decisions. Unlike the SAM3 :class:`SessionStore`, sessions
here are **persisted to disk** (one JSON file per session) so a review survives
process restarts and can be resumed.

Sessions are keyed by a deterministic id derived from the passage content, so
re-starting a review of the same document transparently resumes the saved
decisions rather than starting over.
"""

from __future__ import annotations

import hashlib
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from .aa_utils import aa_rows, pick_text_column
from .chunking import count_tokens
from .models import (
    REVIEW_FORWARDED,
    REVIEW_STATUSES,
    AssocArray,
    ReviewCounts,
    ReviewPassage,
    ReviewSession,
)

# Output AA columns, in order.
OUTPUT_COLUMNS = [
    "text",
    "original_text",
    "author",
    "work_title",
    "position",
    "token_count",
    "review_status",
    "edit_flag",
    "review_timestamp",
]


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def compute_review_id(passages: list[ReviewPassage]) -> str:
    """Deterministic id from passage identity + text, so the same document
    resumes the same session."""
    digest = hashlib.sha256()
    for passage in passages:
        digest.update(passage.chunk_id.encode("utf-8"))
        digest.update(b"\x00")
        digest.update(passage.text.encode("utf-8"))
        digest.update(b"\x00")
    return f"review-{digest.hexdigest()[:16]}"


def session_from_aa(aa: AssocArray) -> Optional[ReviewSession]:
    """Build a fresh review session from an upstream AA, or None if the AA has
    no text column."""
    text_col = pick_text_column(aa)
    if text_col is None:
        return None
    passages: list[ReviewPassage] = []
    for index, (chunk_id, record) in enumerate(aa_rows(aa)):
        text = record.get(text_col, "")
        position = record.get("position")
        token_count = record.get("token_count")
        passages.append(
            ReviewPassage(
                chunk_id=chunk_id,
                text=str(text),
                author=str(record.get("author", "")),
                work_title=str(record.get("work_title", "")),
                position=position if isinstance(position, int) else index,
                token_count=token_count
                if isinstance(token_count, int)
                else count_tokens(str(text)),
                chunk_strategy=str(record.get("chunk_strategy", "")),
            )
        )
    passages.sort(key=lambda p: p.position)
    return ReviewSession(
        review_id=compute_review_id(passages),
        passages=passages,
        created_at=_now(),
    )


def apply_decision(
    session: ReviewSession,
    chunk_id: str,
    status: str,
    edited_text: Optional[str],
) -> ReviewPassage:
    """Record a decision for [chunk_id]; raises ValueError/KeyError on bad input."""
    if status not in REVIEW_STATUSES:
        raise ValueError(status)
    for passage in session.passages:
        if passage.chunk_id == chunk_id:
            passage.status = status
            passage.review_timestamp = _now()
            passage.edited_text = edited_text if status == "edited" else None
            return passage
    raise KeyError(chunk_id)


def counts(session: ReviewSession) -> ReviewCounts:
    tally = {status: 0 for status in REVIEW_STATUSES}
    pending = 0
    for passage in session.passages:
        if passage.status in tally:
            tally[passage.status] += 1
        else:
            pending += 1
    return ReviewCounts(
        total=len(session.passages),
        approved=tally["approved"],
        edited=tally["edited"],
        rejected=tally["rejected"],
        pending=pending,
    )


def is_complete(session: ReviewSession) -> bool:
    return all(p.status is not None for p in session.passages)


def output_aa(session: ReviewSession) -> AssocArray:
    """The full audit AA: one row per *decided* passage, including rejected ones.

    ``text`` is the final text (edited version when edited); ``original_text``
    preserves the pre-edit text when ``edit_flag`` is true. ``position`` and
    ``token_count`` are integers (token_count reflects the final text).
    """
    rows: list[str] = []
    cols: list[str] = []
    vals: list = []
    for passage in session.passages:
        if passage.status is None:
            continue
        edited = passage.status == "edited"
        final_text = passage.edited_text or "" if edited else passage.text
        row_values = {
            "text": final_text,
            "original_text": passage.text if edited else "",
            "author": passage.author,
            "work_title": passage.work_title,
            "position": passage.position,
            "token_count": count_tokens(final_text),
            "review_status": passage.status,
            "edit_flag": "true" if edited else "false",
            "review_timestamp": passage.review_timestamp or "",
        }
        for col in OUTPUT_COLUMNS:
            rows.append(passage.chunk_id)
            cols.append(col)
            vals.append(row_values[col])
    return AssocArray(rows=rows, cols=cols, vals=vals)


def is_forwarded(status: Optional[str]) -> bool:
    """Whether a passage with [status] flows downstream to AA2JSONLNode."""
    return status in REVIEW_FORWARDED


class ReviewStore:
    """Disk-backed review sessions: one ``<review_id>.json`` per session."""

    def __init__(self, base_dir: Optional[str] = None) -> None:
        self.base_dir = Path(
            base_dir
            or os.environ.get("DOUBLE_TOUCH_REVIEW_DIR", "../storage/reviews")
        )

    def _file(self, review_id: str) -> Path:
        return self.base_dir / f"{review_id}.json"

    def exists(self, review_id: str) -> bool:
        return self._file(review_id).exists()

    def load(self, review_id: str) -> Optional[ReviewSession]:
        path = self._file(review_id)
        if not path.exists():
            return None
        return ReviewSession.model_validate_json(path.read_text(encoding="utf-8"))

    def save(self, session: ReviewSession) -> None:
        self.base_dir.mkdir(parents=True, exist_ok=True)
        self._file(session.review_id).write_text(
            session.model_dump_json(), encoding="utf-8"
        )
