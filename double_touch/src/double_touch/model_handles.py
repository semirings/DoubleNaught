"""In-memory store for built GPTModel instances, keyed by UUID handle."""

from __future__ import annotations

import threading
from uuid import uuid4

from .gpt_model import GPTModel

_lock = threading.Lock()
_store: dict[str, GPTModel] = {}


def store(model: GPTModel) -> str:
    handle_id = str(uuid4())
    with _lock:
        _store[handle_id] = model
    return handle_id


def get(handle_id: str) -> GPTModel | None:
    with _lock:
        return _store.get(handle_id)


def delete(handle_id: str) -> bool:
    with _lock:
        return _store.pop(handle_id, None) is not None


def list_handles() -> list[str]:
    with _lock:
        return list(_store.keys())
