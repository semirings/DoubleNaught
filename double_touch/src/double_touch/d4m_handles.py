"""In-memory handle store for D4M AssocArray objects.

Handles are UUIDs that identify ephemeral AAs held in this process's memory.
The store is intentionally simple: no expiry, no persistence, no size limit.
It exists so the frontend can ingest AAs once and then reference them by id
rather than shipping full wire payloads on every exec call.
"""

from __future__ import annotations

import threading
from uuid import uuid4

from .models import AssocArray

_lock = threading.Lock()
_store: dict[str, AssocArray] = {}


def store(aa: AssocArray) -> str:
    """Persist *aa* and return a new UUID handle id."""
    handle_id = str(uuid4())
    with _lock:
        _store[handle_id] = aa
    return handle_id


def get(handle_id: str) -> AssocArray | None:
    """Return the AA for *handle_id*, or None if unknown."""
    with _lock:
        return _store.get(handle_id)


def get_slice(handle_id: str, page: int, page_size: int) -> AssocArray | None:
    """Return a page of entries from the AA identified by *handle_id*.

    Slices by *triple* index (each row/col/val entry is one triple) rather than
    by row key.  Returns None when *handle_id* is unknown.
    """
    with _lock:
        aa = _store.get(handle_id)
    if aa is None:
        return None
    start = page * page_size
    end = start + page_size
    return AssocArray(
        rows=aa.rows[start:end],
        cols=aa.cols[start:end],
        vals=aa.vals[start:end],
    )


def shape(handle_id: str) -> tuple[int, int] | None:
    """Return *(num_unique_rows, num_unique_cols)* or None."""
    with _lock:
        aa = _store.get(handle_id)
    if aa is None:
        return None
    return len(set(aa.rows)), len(set(aa.cols))


def nnz(handle_id: str) -> int | None:
    """Return the number of non-zero entries, or None if unknown."""
    with _lock:
        aa = _store.get(handle_id)
    if aa is None:
        return None
    return len(aa.vals)


def delete(handle_id: str) -> bool:
    """Remove the handle. Returns True if it existed."""
    with _lock:
        return _store.pop(handle_id, None) is not None
