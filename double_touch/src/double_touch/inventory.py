"""Persistent inventory of URL entries for InventoryNode.

The inventory is stored on disk **as a D4M/AA** (one row per entry, keyed by a
stable ``entryID``). CRUD operations reconstruct the rows, mutate, and write the
AA back. On first run the store is pre-populated with a seed set of entries.

Kept separate from the route module (like :mod:`review`) so the store and the
AA <-> entry helpers can be reused without a circular import.
"""

from __future__ import annotations

import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional
from uuid import uuid4

from .aa_serializer import load_aa_arrow, save_aa_arrow, table_to_assoc
from .aa_utils import aa_rows
from .models import AssocArray

# Inventory AA columns (per entry). ``entryID`` is the row key, not a column.
INVENTORY_COLUMNS = ["url", "author", "work_title", "work_selector", "description"]

# Output AA columns for a selected entry (adds a selection timestamp).
SELECT_COLUMNS = INVENTORY_COLUMNS + ["selected_timestamp"]

# Seed entries created on first run (the Gilbert & Sullivan operas in the single
# multi-work Gutenberg file). Chesterton / Churchill entries can be added later
# through the CRUD API.
_GNS_URL = "https://www.gutenberg.org/files/808/808-h/808-h.htm"
SEED_ENTRIES = [
    {
        "url": _GNS_URL,
        "author": "gilbert",
        "work_title": "HMS Pinafore",
        "work_selector": "H.M.S. PINAFORE",
        "description": "Gilbert & Sullivan — HMS Pinafore",
    },
    {
        "url": _GNS_URL,
        "author": "gilbert",
        "work_title": "The Pirates of Penzance",
        "work_selector": "THE PIRATES OF PENZANCE",
        "description": "Gilbert & Sullivan — The Pirates of Penzance",
    },
    {
        "url": _GNS_URL,
        "author": "gilbert",
        "work_title": "Iolanthe",
        "work_selector": "IOLANTHE; OR, THE PEER AND THE PERI",
        "description": "Gilbert & Sullivan — Iolanthe",
    },
    {
        "url": _GNS_URL,
        "author": "gilbert",
        "work_title": "The Mikado",
        "work_selector": "THE MIKADO; OR, THE TOWN OF TITIPU",
        "description": "Gilbert & Sullivan — The Mikado",
    },
]


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def new_entry_id() -> str:
    return f"entry-{uuid4().hex[:8]}"


def entries_to_aa(entries: list[dict]) -> AssocArray:
    """Serialize an ordered list of entry dicts (each with ``entry_id``) to an AA."""
    rows: list[str] = []
    cols: list[str] = []
    vals: list = []
    for entry in entries:
        entry_id = entry["entry_id"]
        for col in INVENTORY_COLUMNS:
            rows.append(entry_id)
            cols.append(col)
            vals.append(str(entry.get(col, "")))
    return AssocArray(rows=rows, cols=cols, vals=vals)


def aa_to_entries(aa: AssocArray) -> list[dict]:
    """Reconstruct the ordered list of entry dicts from the inventory AA."""
    entries: list[dict] = []
    for entry_id, record in aa_rows(aa):
        entry = {"entry_id": entry_id}
        for col in INVENTORY_COLUMNS:
            entry[col] = str(record.get(col, ""))
        entries.append(entry)
    return entries


def select_aa(entry: dict) -> AssocArray:
    """A single-entry output AA (with a selection timestamp) for URLNode."""
    timestamp = _now()
    values = [entry.get(col, "") for col in INVENTORY_COLUMNS] + [timestamp]
    return AssocArray(
        rows=[entry["entry_id"]] * len(SELECT_COLUMNS),
        cols=list(SELECT_COLUMNS),
        vals=[str(v) for v in values],
    )


class InventoryStore:
    """Disk-backed inventory AA (``inventory.arrow``), seeded on first load.

    Persistence tier: Arrow IPC (zero-copy, binary).  A legacy ``inventory.json``
    is migrated to Arrow automatically on the first load and left in place for
    reference — the Arrow file takes precedence on all subsequent reads.
    """

    def __init__(self, base_dir: Optional[str] = None) -> None:
        base = Path(base_dir or os.environ.get("DOUBLE_TOUCH_STORAGE_DIR", "../storage"))
        self.path      = base / "inventory.arrow"
        self._json_path = base / "inventory.json"   # legacy migration source

    def load(self) -> AssocArray:
        """Return the inventory AA, migrating from JSON or seeding on first run."""
        if self.path.exists():
            return table_to_assoc(load_aa_arrow(self.path, memory_map=False))

        # One-time migration: JSON → Arrow.
        if self._json_path.exists():
            aa = AssocArray.model_validate_json(
                self._json_path.read_text(encoding="utf-8")
            )
            self.save(aa)
            return aa

        # First run: seed, persist, return.
        seeded = [{"entry_id": new_entry_id(), **entry} for entry in SEED_ENTRIES]
        aa = entries_to_aa(seeded)
        self.save(aa)
        return aa

    def save(self, aa: AssocArray) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        save_aa_arrow(aa, self.path)

    def entries(self) -> list[dict]:
        return aa_to_entries(self.load())

    def get(self, entry_id: str) -> Optional[dict]:
        for entry in self.entries():
            if entry["entry_id"] == entry_id:
                return entry
        return None

    def create(self, fields: dict) -> AssocArray:
        entries = self.entries()
        entries.append({"entry_id": new_entry_id(), **fields})
        aa = entries_to_aa(entries)
        self.save(aa)
        return aa

    def update(self, entry_id: str, fields: dict) -> Optional[AssocArray]:
        entries = self.entries()
        found = False
        for entry in entries:
            if entry["entry_id"] == entry_id:
                entry.update(fields)
                found = True
        if not found:
            return None
        aa = entries_to_aa(entries)
        self.save(aa)
        return aa

    def delete(self, entry_id: str) -> Optional[AssocArray]:
        entries = self.entries()
        remaining = [e for e in entries if e["entry_id"] != entry_id]
        if len(remaining) == len(entries):
            return None
        aa = entries_to_aa(remaining)
        self.save(aa)
        return aa
