"""Save Loraset: write LoRA training pages to ``storage/loraset/<set>/<page>/``.

Each page is a self-contained folder::

    storage/loraset/<set>/<page>/
        metadata.jsonl                      one ``{"file_name", "text"}`` per image
        <session>_<pass>_<uuid>.png         one per segment

``file_name`` is relative to ``metadata.jsonl`` (the Hugging Face ``imagefolder``
convention, which also discovers a ``metadata.jsonl`` in every subfolder). Saving a
page replaces its whole folder, so edited captions never leave stale entries.

Input is the LLM caption AA: segment rows carrying ``file_name``, a caption
(``improved_caption`` preferred), ``page_name`` and ``image_b64``.
"""

from __future__ import annotations

import base64
import binascii
import json
import os
import re
import shutil
import tempfile
from pathlib import Path
from typing import Any, Optional

from .aa_utils import aa_rows
from .models import AssocArray

METADATA_NAME = "metadata.jsonl"
DEFAULT_SET = "mccay"
_UNSAFE = re.compile(r"[^A-Za-z0-9._-]+")


#: File names that say nothing about the page ("image.png" is what a pasted or
#: piped image is called), so they cannot name a folder.
GENERIC_PAGE_NAMES = frozenset({"", "image", "images", "untitled", "upload", "file", "page"})


def _session_of(file_name: str) -> str:
    """The session id leading a training image name (`<session>_<pass>_<uuid>.png`)."""
    return Path(file_name).name.split("_")[0]


def _owner_session(folder: Path) -> str:
    """Session that wrote [folder], read back from its first metadata line."""
    meta = folder / METADATA_NAME
    try:
        first = meta.read_text(encoding="utf-8").splitlines()[0]
        return _session_of(json.loads(first)["file_name"])
    except (OSError, IndexError, KeyError, ValueError):
        return ""


class LorasetError(ValueError):
    """The input cannot be saved as a loraset."""


def loraset_root() -> Path:
    """`storage/loraset`, or `$DOUBLE_TOUCH_LORASET_DIR` when set (tests)."""
    override = os.environ.get("DOUBLE_TOUCH_LORASET_DIR")
    base = (
        Path(override)
        if override
        else Path(__file__).parent.parent.parent.parent / "storage" / "loraset"
    )
    base.mkdir(parents=True, exist_ok=True)
    return base


def safe_name(value: object, fallback: str) -> str:
    """One path segment: letters, digits, `.`, `_`, `-`. Never empty, never `..`."""
    cleaned = _UNSAFE.sub("_", str(value or "")).strip("._")
    return cleaned or fallback


def _text(value: object) -> str:
    return "" if value is None else str(value).strip()


def save_loraset(
    aa: AssocArray, name: str = DEFAULT_SET, root: Optional[Path] = None
) -> dict[str, Any]:
    """Write every captioned segment row of [aa]; return what was written.

    Rows without a `file_name`, a caption or a decodable `image_b64` are skipped
    and counted, never guessed. Raises [LorasetError] when nothing is writable.
    """
    base = (root or loraset_root()) / safe_name(name, DEFAULT_SET)
    pages: dict[tuple[str, str], list[tuple[str, str, bytes]]] = {}
    skipped = 0

    for _row, rec in aa_rows(aa):
        file_name = _text(rec.get("file_name"))
        caption = _text(rec.get("improved_caption")) or _text(rec.get("caption"))
        encoded = _text(rec.get("image_b64"))
        if not file_name or not caption or not encoded:
            skipped += 1
            continue
        try:
            png = base64.b64decode(encoded, validate=False)
        except (binascii.Error, ValueError):
            skipped += 1
            continue
        if not png:
            skipped += 1
            continue
        stem = Path(file_name).name  # drop any directory the caller supplied
        session = safe_name(_session_of(stem), "session")
        page = safe_name(rec.get("page_name"), "")
        if page.lower() in GENERIC_PAGE_NAMES:
            page = f"page-{session[:8]}"  # unnamed page: its session names it
        pages.setdefault((page, session), []).append(
            (safe_name(stem, "image.png"), caption, png)
        )

    if not pages:
        have = sorted(set(aa.cols))
        need = [c for c in ("file_name", "image_b64") if c not in have]
        if "improved_caption" not in have and "caption" not in have:
            need.append("improved_caption")
        raise LorasetError(
            "nothing to save: rows need file_name, a caption and image_b64. "
            + (f"Missing columns: {', '.join(need)}. " if need else "")
            + f"Received columns: {', '.join(have) or 'none'}. "
            + "Wire this node straight from the LLM node's output, "
            + "after re-running Seg Forge and the LLM node."
        )

    base.mkdir(parents=True, exist_ok=True)
    written: list[dict[str, Any]] = []
    for (page, session), items in pages.items():
        target = base / page
        # Same folder name, different session: a different page that happens to
        # share a file name. Keep both rather than replacing the earlier one.
        owner = _owner_session(target) if target.exists() else ""
        if owner and owner != session:
            page = f"{page}-{session[:8]}"
            target = base / page
        tmp = Path(tempfile.mkdtemp(prefix=f".{page}.", dir=base))
        try:
            lines = []
            for fname, caption, png in items:
                (tmp / fname).write_bytes(png)
                lines.append(json.dumps({"file_name": fname, "text": caption}, ensure_ascii=False))
            (tmp / METADATA_NAME).write_text("\n".join(lines) + "\n", encoding="utf-8")
            if target.exists():
                shutil.rmtree(target)
            tmp.rename(target)
        except BaseException:
            shutil.rmtree(tmp, ignore_errors=True)
            raise
        written.append({"page": page, "images": len(items), "path": str(target)})

    return {
        "loraset": base.name,
        "pages": written,
        "images": sum(p["images"] for p in written),
        "skipped": skipped,
        "path": str(base),
    }
