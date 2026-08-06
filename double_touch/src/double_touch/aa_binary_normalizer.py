"""Zero-copy ingestion and schema standardization for the AA binary pipeline.

Accepts raw source files in multiple formats, normalises them to a strongly-typed
Apache Arrow schema, writes a persistent ``.arrow`` binary cache, and returns a
memory-mapped HuggingFace ``Dataset`` handle — the ``aaOut`` payload for the
``AaBinaryNormalizerNode`` on the workflow canvas.

AA wire contract
----------------
aaIn keys:
    filePath        Absolute path to the source file.
    outputDirectory Directory where the ``.arrow`` cache will be written.
    splitName       Dataset split key (default ``'train'``).
    keepInMemory    When ``True``, load into Python heap instead of mmap.

aaOut keys:
    dataset         Memory-mapped HuggingFace Dataset instance.
    arrowFilePath   Absolute path of the generated ``.arrow`` file.
    rowCount        Total record count.
    columnSchema    Dict of field-name → Arrow type string.
    isMemoryMapped  True when the Dataset was memory-mapped (not heap-loaded).
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any, Callable, Optional

import pyarrow as pa
import pyarrow.ipc as ipc

# Format-specific readers — each returns a pa.Table.
import pyarrow.csv as pacsv
import pyarrow.json as pajson
import pyarrow.parquet as parquet
from datasets import Dataset

# ── Canonical AA Arrow schema ──────────────────────────────────────────────────
#
# Every row in the normalised table maps to one discrete passage/record.
# The list-typed columns (scores, inputIds, attentionMask, labels) are empty
# by default; downstream nodes (TokenizerNode, LabelNode) populate them.

_AA_SCHEMA = pa.schema([
    pa.field("chunkId",       pa.string()),
    pa.field("text",          pa.string()),
    pa.field("scores",        pa.list_(pa.float32())),
    pa.field("inputIds",      pa.list_(pa.int32())),
    pa.field("attentionMask", pa.list_(pa.int32())),
    pa.field("labels",        pa.list_(pa.int32())),
])

# Candidate column names, in preference order, used when the source does not
# have an explicit ``text`` column.
_TEXT_COLUMN_CANDIDATES = ("text", "content", "body", "passage", "sentence")

ProgressCallback = Callable[[str, float], None]


def _noop(stage: str, progress: float) -> None:  # noqa: ARG001
    pass


class AABinaryNormalizer:
    """Zero-copy AA ingestion, schema normalization, and binary-cache writer.

    Typical call
    ------------
    ::

        normalizer = AABinaryNormalizer()
        aaOut = normalizer.normalize({
            "filePath":        "/data/corpus.jsonl",
            "outputDirectory": "/data/cache",
            "splitName":       "train",
            "keepInMemory":    False,
        }, progressCallback=lambda stage, pct: print(stage, pct))
    """

    def normalize(
        self,
        aaIn: dict[str, Any],
        progressCallback: ProgressCallback = _noop,
    ) -> dict[str, Any]:
        """Run the full normalization pipeline and return ``aaOut``.

        Parameters
        ----------
        aaIn:
            AA payload dict — see module docstring for key contract.
        progressCallback:
            Called at each stage transition with ``(stageLabel, 0.0–1.0)``.
            Stages: ``'ingesting'``, ``'normalizing'``, ``'writingBinary'``,
            ``'complete'``.
        """
        filePath     = aaIn["filePath"]
        outputDir    = aaIn["outputDirectory"]
        splitName    = str(aaIn.get("splitName", "train"))
        keepInMemory = bool(aaIn.get("keepInMemory", False))

        src = Path(filePath)
        if not src.exists():
            raise FileNotFoundError(f"Source file not found: {filePath}")

        os.makedirs(outputDir, exist_ok=True)
        bookId  = src.stem
        outPath = Path(outputDir) / f"{bookId}.{splitName}.aa.arrow"

        # ── Stage 1: ingest ────────────────────────────────────────────────
        progressCallback("ingesting", 0.0)
        table = self._ingest(src)

        # ── Stage 2: normalise to AA schema ───────────────────────────────
        progressCallback("normalizing", 0.33)
        table = self._normalizeSchema(table, bookId)

        # ── Stage 3: write persistent binary cache ────────────────────────
        progressCallback("writingBinary", 0.66)
        self._writeArrow(table, outPath)

        # ── Stage 4: memory-map the written file ──────────────────────────
        progressCallback("complete", 1.0)
        dataset, isMemoryMapped = self._loadMmap(outPath, keepInMemory)

        columnSchema: dict[str, str] = {
            field.name: str(field.type)
            for field in _AA_SCHEMA
        }

        return {
            "dataset":        dataset,
            "arrowFilePath":  str(outPath),
            "rowCount":       len(dataset),
            "columnSchema":   columnSchema,
            "isMemoryMapped": isMemoryMapped,
        }

    # ── Ingestion ──────────────────────────────────────────────────────────────

    def _ingest(self, src: Path) -> pa.Table:
        suffix = src.suffix.lower()
        if suffix in (".arrow", ".feather"):
            return self._loadArrowDirect(src)
        if suffix == ".parquet":
            return parquet.read_table(str(src))
        if suffix == ".csv":
            return pacsv.read_csv(str(src))
        if suffix == ".jsonl":
            return pajson.read_json(str(src))
        if suffix == ".txt":
            return self._loadTxt(src)
        raise ValueError(
            f"Unsupported source format: {suffix!r}. "
            "Expected .txt · .jsonl · .csv · .parquet · .arrow · .feather"
        )

    def _loadArrowDirect(self, src: Path) -> pa.Table:
        """Zero-copy Arrow IPC load via memory map — no Python-heap copy."""
        mmap   = pa.memory_map(str(src), "r")
        reader = ipc.open_file(mmap)
        return reader.read_all()

    def _loadTxt(self, src: Path) -> pa.Table:
        """Plain-text file: each non-empty paragraph becomes one record."""
        raw        = src.read_text(encoding="utf-8", errors="replace")
        paragraphs = [p.strip() for p in raw.split("\n\n") if p.strip()]
        bookId     = src.stem
        n          = len(paragraphs)
        return pa.table(
            {
                "chunkId": [f"{bookId}:{i:05d}" for i in range(n)],
                "text":    paragraphs,
            }
        )

    # ── Schema normalisation ───────────────────────────────────────────────────

    def _normalizeSchema(self, table: pa.Table, bookId: str) -> pa.Table:
        """Map incoming columns to the canonical AA schema.

        * ``chunkId`` is generated from *bookId* + row index when absent.
        * ``text`` is detected from a ranked list of candidate column names
          when not present under the literal name.
        * All list-typed columns (scores, inputIds, attentionMask, labels) are
          filled with empty typed arrays when absent — downstream nodes fill them.
        * Present columns are cast to the target Arrow type; unsafe casts are
          accepted (numeric strings → ints, etc.).
        """
        incoming  = set(table.schema.names)
        n         = len(table)
        newCols: dict[str, pa.Array] = {}

        for field in _AA_SCHEMA:
            fName = field.name

            if fName == "chunkId":
                if "chunkId" in incoming:
                    newCols[fName] = table.column("chunkId").cast(pa.string())
                else:
                    newCols[fName] = pa.array(
                        [f"{bookId}:{i:05d}" for i in range(n)], type=pa.string()
                    )
                continue

            if fName == "text":
                srcCol = self._resolveTextColumn(incoming)
                if srcCol:
                    newCols[fName] = table.column(srcCol).cast(pa.string())
                else:
                    newCols[fName] = pa.nulls(n, type=pa.string())
                continue

            if fName in incoming:
                newCols[fName] = table.column(fName).cast(field.type, safe=False)
            elif pa.types.is_list(field.type):
                newCols[fName] = pa.array([[] for _ in range(n)], type=field.type)
            else:
                newCols[fName] = pa.nulls(n, type=field.type)

        return pa.table(newCols, schema=_AA_SCHEMA)

    def _resolveTextColumn(self, colNames: set[str]) -> Optional[str]:
        for candidate in _TEXT_COLUMN_CANDIDATES:
            if candidate in colNames:
                return candidate
        return None

    # ── Binary write ──────────────────────────────────────────────────────────

    def _writeArrow(self, table: pa.Table, outPath: Path) -> None:
        """Write *table* to an Arrow IPC file at *outPath*."""
        with ipc.new_file(str(outPath), table.schema) as writer:
            writer.write_table(table)

    # ── Memory-mapped load ────────────────────────────────────────────────────

    def _loadMmap(
        self, outPath: Path, keepInMemory: bool
    ) -> tuple[Dataset, bool]:
        """Load the written file as a HuggingFace ``Dataset``.

        ``keep_in_memory=False`` (the default) instructs the library to
        memory-map the Arrow IPC file — downstream slicing incurs zero
        Python-heap copy.
        """
        dataset = Dataset.from_file(str(outPath), keep_in_memory=keepInMemory)
        return dataset, not keepInMemory
