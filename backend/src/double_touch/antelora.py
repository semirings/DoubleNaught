"""Save Antelora: write LoRA training pages to ``storage/antelora/<set>/<page>/``.

Each page is a self-contained folder::

    storage/antelora/<set>/<page>/
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
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional, Sequence

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


class AnteloraError(ValueError):
    """The input cannot be saved as a antelora."""


def antelora_root() -> Path:
    """`storage/antelora`, or `$DOUBLE_TOUCH_LORASET_DIR` when set (tests)."""
    override = os.environ.get("DOUBLE_TOUCH_LORASET_DIR")
    base = (
        Path(override)
        if override
        else Path(__file__).parent.parent.parent.parent / "storage" / "antelora"
    )
    base.mkdir(parents=True, exist_ok=True)
    return base


def safe_name(value: object, fallback: str) -> str:
    """One path segment: letters, digits, `.`, `_`, `-`. Never empty, never `..`."""
    cleaned = _UNSAFE.sub("_", str(value or "")).strip("._")
    return cleaned or fallback


def _text(value: object) -> str:
    return "" if value is None else str(value).strip()


def save_antelora(
    aa: AssocArray, name: str = DEFAULT_SET, root: Optional[Path] = None
) -> dict[str, Any]:
    """Write every captioned segment row of [aa]; return what was written.

    Rows without a `file_name`, a caption or a decodable `image_b64` are skipped
    and counted, never guessed. Raises [AnteloraError] when nothing is writable.
    """
    base = (root or antelora_root()) / safe_name(name, DEFAULT_SET)
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
        raise AnteloraError(
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
        "antelora": base.name,
        "pages": written,
        "images": sum(p["images"] for p in written),
        "skipped": skipped,
        "path": str(base),
    }


# ── Collect: many page folders → one flat training folder ────────────────────

CHAT_NAME = "train.jsonl"
CHAT_PROMPT = "Describe this image."  # plain text: the model's chat template adds the image tokens
COLLECTED_DIR = "_collected"
MANIFEST_NAME = "collection.json"
_PROBLEM_CAP = 20


def _is_page_dir(path: Path) -> bool:
    """A page folder: a real directory, not `_collected`/temp, with its metadata."""
    return (
        path.is_dir()
        and not path.name.startswith((".", "_"))
        and (path / METADATA_NAME).is_file()
    )


def list_pages(name: str = DEFAULT_SET, root: Optional[Path] = None) -> list[dict[str, Any]]:
    """Saved pages of a antelora, alphabetical: `{page, images, path}`."""
    base = (root or antelora_root()) / safe_name(name, DEFAULT_SET)
    if not base.is_dir():
        return []
    pages = []
    for folder in sorted(base.iterdir(), key=lambda p: p.name.lower()):
        if not _is_page_dir(folder):
            continue
        try:
            lines = [
                x for x in (folder / METADATA_NAME).read_text(encoding="utf-8").splitlines() if x.strip()
            ]
        except OSError:
            continue
        pages.append({"page": folder.name, "images": len(lines), "path": str(folder)})
    return pages


def collect_antelora(
    name: str = DEFAULT_SET,
    exclude: Sequence[str] = (),
    output: str = "train",
    root: Optional[Path] = None,
    prompt: str = CHAT_PROMPT,
) -> dict[str, Any]:
    """Merge the saved pages (minus [exclude]) into one trainer-ready folder::

        storage/antelora/<set>/_collected/<output>/
            metadata.jsonl      {"file_name": "images/<png>", "text": ...}
            train.jsonl         same lines as image+chat pairs, the split file
                                `mlx_vlm.train --data <folder>` reads
            images/<png>
            collection.json     what went in, what was held out, when

    Images are copied, so the folder stands alone (movable to a training
    machine). A line whose image is missing, whose JSON is broken or whose text
    is empty is skipped and reported, never written. The output folder is
    rebuilt from scratch each time. Raises [AnteloraError] when nothing remains.
    """
    base = (root or antelora_root()) / safe_name(name, DEFAULT_SET)
    held = {safe_name(x, "") for x in exclude if x}
    out_name = safe_name(output, "train")
    included: list[str] = []
    problems: list[str] = []
    skipped = 0
    seen_names: set[str] = set()
    captions: dict[str, int] = {}

    def note(msg: str) -> None:
        nonlocal skipped
        skipped += 1
        if len(problems) < _PROBLEM_CAP:
            problems.append(msg)

    collected_root = base / COLLECTED_DIR
    collected_root.mkdir(parents=True, exist_ok=True)
    tmp = Path(tempfile.mkdtemp(prefix=f".{out_name}.", dir=collected_root))
    try:
        (tmp / "images").mkdir()
        lines_out: list[str] = []
        chat_out: list[str] = []
        for folder in sorted(base.iterdir(), key=lambda p: p.name.lower()):
            if not _is_page_dir(folder) or folder.name in held:
                continue
            kept = 0
            raw = (folder / METADATA_NAME).read_text(encoding="utf-8").splitlines()
            for n, line in enumerate(raw, 1):
                if not line.strip():
                    continue
                try:
                    rec = json.loads(line)
                    file_name = Path(str(rec["file_name"])).name
                    text = str(rec["text"]).strip()
                except (ValueError, KeyError, TypeError):
                    note(f"{folder.name} line {n}: not a valid file_name/text line")
                    continue
                src = folder / file_name
                if not text:
                    note(f"{folder.name}/{file_name}: empty caption")
                elif not src.is_file():
                    note(f"{folder.name}/{file_name}: image missing")
                elif file_name in seen_names:
                    note(f"{folder.name}/{file_name}: duplicate file name")
                else:
                    shutil.copyfile(src, tmp / "images" / file_name)
                    seen_names.add(file_name)
                    captions[text] = captions.get(text, 0) + 1
                    lines_out.append(
                        json.dumps({"file_name": f"images/{file_name}", "text": text}, ensure_ascii=False)
                    )
                    chat_out.append(json.dumps({
                        "images": [f"images/{file_name}"],
                        "messages": [
                            {"role": "user", "content": prompt},
                            {"role": "assistant", "content": text},
                        ],
                    }, ensure_ascii=False))
                    kept += 1
            if kept:
                included.append(folder.name)

        if not lines_out:
            raise AnteloraError(
                "nothing to collect: no usable lines in the selected pages"
                + (f" ({len(held)} held out)" if held else "")
            )

        (tmp / METADATA_NAME).write_text("\n".join(lines_out) + "\n", encoding="utf-8")
        (tmp / CHAT_NAME).write_text("\n".join(chat_out) + "\n", encoding="utf-8")
        manifest = {
            "antelora": base.name,
            "output": out_name,
            "created": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "pages": included,
            "held_out": sorted(held),
            "images": len(lines_out),
            "skipped": skipped,
            "duplicate_captions": sum(c - 1 for c in captions.values() if c > 1),
        }
        (tmp / MANIFEST_NAME).write_text(json.dumps(manifest, indent=2), encoding="utf-8")

        target = collected_root / out_name
        if target.exists():
            shutil.rmtree(target)
        tmp.rename(target)
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True)
        raise

    return {
        "antelora": base.name,
        "output": out_name,
        "path": str(collected_root / out_name),
        "pages": included,
        "excluded": sorted(held),
        "images": len(lines_out),
        "skipped": skipped,
        "problems": problems,
    }
