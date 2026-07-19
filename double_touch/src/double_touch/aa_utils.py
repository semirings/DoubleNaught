"""Shared helpers for reading D4M/AA associative arrays in sparse triple form.

Used by the processing routes that consume multi-row AAs (AA2JSONLNode,
ReviewNode). Kept separate from the route module so both the routes and the
review store can use them without a circular import.
"""

from __future__ import annotations

from typing import Optional

from .models import AssocArray


def aa_rows(aa: AssocArray) -> list[tuple[str, dict[str, object]]]:
    """Reconstruct ``(row_key, {col: val})`` records from the sparse triples,
    preserving first-appearance row order."""
    order: list[str] = []
    records: dict[str, dict[str, object]] = {}
    for row, col, val in zip(aa.rows, aa.cols, aa.vals):
        if row not in records:
            records[row] = {}
            order.append(row)
        records[row][col] = val
    return [(row, records[row]) for row in order]


def pick_text_column(aa: AssocArray) -> Optional[str]:
    """The column holding passage text: ``text`` (ChunkNode) or ``raw_text``
    (FetchNode), whichever is present — keeps consumers general-purpose."""
    cols = set(aa.cols)
    for candidate in ("text", "raw_text"):
        if candidate in cols:
            return candidate
    return None
