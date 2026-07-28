"""Zero-shot classification abstraction for DoubleTouch (D4M AA Aware).

The route layer calls a :class:`ClassifierEngine`. Two engines implement the interface:

* :class:`StubClassifierEngine` — deterministic, dependency-free placeholder
  (lexical overlap between labels and text). Used when ``torch`` /
  ``transformers`` aren't installed, and as the per-request fallback when a real
  model can't be loaded — so the pipeline never crashes.
* :class:`LocalTransformersClassifierEngine` — real, **offline** zero-shot
  inference via ``transformers.pipeline`` + ``torch``, with a warm in-memory
  model cache so a model loaded once stays resident across requests.

:func:`default_classifier` picks the local engine when the optional deps are
importable, otherwise the stub. ``torch``/``transformers`` are imported lazily
(inside methods), so this module imports fine without them.

Now updated to consume and produce D4M Associative Arrays (AA-in, AA-out).
"""

from __future__ import annotations

import importlib.util
import logging
import re
import threading
from collections import OrderedDict
from typing import Any, Protocol, runtime_checkable

_log = logging.getLogger("double_touch.classify")

_MAX_INPUT_CHARS = 10_000
_DEFAULT_TASK = "zero-shot-classification"


def extract_aa_chunks(aa_dict: dict) -> dict[str, str]:
    """Extracts a map of {row_id: text_payload} from a D4M AA dictionary."""
    rows = aa_dict.get("row", [])
    cols = aa_dict.get("col", [])
    vals = aa_dict.get("val", [])

    chunks: dict[str, str] = {}
    for r, c, v in zip(rows, cols, vals):
        if c == "text":
            chunks[r] = str(v)
    return chunks


def _to_sparse_triples(
    rows: list, cols: list, vals: list
) -> tuple[list, list, list]:
    """Normalise an AA to canonical sparse triples (parallel ``row``/``col``/``val``).

    Most AAs arrive sparse (all three lists the same length). A hand-authored
    table such as ``storage/categories/categories.json`` may instead be **dense**
    — ``vals`` is a row-major ``rows × cols`` matrix — which is expanded here so
    the rest of the parser can assume sparse. Anything else is returned as-is
    (best effort)."""
    if len(vals) == len(rows):
        return rows, cols, vals
    if cols and len(vals) == len(rows) * len(cols):
        ncols = len(cols)
        r: list = []
        c: list = []
        v: list = []
        for i, row in enumerate(rows):
            for j, col in enumerate(cols):
                r.append(row)
                c.append(col)
                v.append(vals[i * ncols + j])
        return r, c, v
    return rows, cols, vals


def parse_categories_aa(
    aa_dict: dict,
) -> tuple[list[str], list[str | None], list[float | None]]:
    """Unpack a **categories** AA into three parallel lists aligned by category.

    The AA carries one row per category (``storage/categories/categories.json``):
    a required ``label`` column (the candidate label), plus optional
    ``hypothesis_template`` and ``threshold`` columns. Rows are grouped
    preserving first-appearance order so the label order is stable, and a row
    without a non-empty ``label`` is skipped. Both the sparse and dense AA
    shapes are accepted.

    Returns ``(labels, templates, thresholds)`` where ``templates[i]`` is the
    zero-shot hypothesis template for ``labels[i]`` (``None`` -> use the model
    default) and ``thresholds[i]`` its acceptance cutoff (``None`` -> no cutoff).
    """
    rows, cols, vals = _to_sparse_triples(
        aa_dict.get("row", []),
        aa_dict.get("col", []),
        aa_dict.get("val", []),
    )

    order: list[str] = []
    by_row: dict[str, dict[str, Any]] = {}
    for r, c, v in zip(rows, cols, vals):
        attrs = by_row.get(r)
        if attrs is None:
            attrs = by_row[r] = {}
            order.append(r)
        attrs[c] = v

    labels: list[str] = []
    templates: list[str | None] = []
    thresholds: list[float | None] = []
    for r in order:
        attrs = by_row[r]
        label = attrs.get("label")
        if label is None or not str(label).strip():
            continue
        labels.append(str(label).strip())

        tmpl = attrs.get("hypothesis_template")
        templates.append(str(tmpl) if tmpl not in (None, "") else None)

        thr = attrs.get("threshold")
        try:
            thresholds.append(float(thr) if thr not in (None, "") else None)
        except (TypeError, ValueError):
            thresholds.append(None)
    return labels, templates, thresholds


def _group_by_template(
    labels: list[str], templates: list[str | None] | None
) -> "OrderedDict[str | None, list[str]]":
    """Group labels by their hypothesis template, preserving first-appearance
    order. A zero-shot pipeline takes one template per call, so labels sharing a
    template are scored together in a single pass. ``None`` templates fall back
    to the model default. With no templates, all labels form one default group.
    """
    groups: "OrderedDict[str | None, list[str]]" = OrderedDict()
    for i, label in enumerate(labels):
        template = templates[i] if templates is not None and i < len(templates) else None
        groups.setdefault(template, []).append(label)
    return groups


def build_classified_aa(
    classification_results: dict[str, dict[str, float]],
    passed_by_row: dict[str, str] | None = None,
    *,
    aa_in: dict | None = None,
) -> dict:
    """Builds a classification-scores AA, preserving all original chunk metadata.

    Starts from every triple in ``aa_in`` (the input AA), then appends one
    ``score:{label}`` column per candidate label per chunk row. The ``score:``
    prefix prevents collisions with existing metadata columns (``text``,
    ``position``, ``author``, etc.). When ``passed_by_row`` is given, each row
    also gains a ``passed`` triple listing the labels that cleared their
    per-category threshold.
    """
    rows: list[str] = list(aa_in.get("row", [])) if aa_in else []
    cols: list[str] = list(aa_in.get("col", [])) if aa_in else []
    vals: list = list(aa_in.get("val", [])) if aa_in else []

    for row_id, scores in classification_results.items():
        for label, score in scores.items():
            rows.append(row_id)
            cols.append(f"score:{label.replace(' ', '_')}")
            vals.append(round(float(score), 4))
        if passed_by_row is not None:
            rows.append(row_id)
            cols.append("passed")
            vals.append(passed_by_row.get(row_id, ""))

    return {"row": rows, "col": cols, "val": vals}


def _passing_labels(
    scores: dict[str, float],
    labels: list[str],
    thresholds: list[float | None] | None,
) -> str | None:
    """The comma-joined categories whose score met their threshold, or ``None``
    when no thresholds were supplied (so no ``passed`` column is emitted)."""
    if thresholds is None:
        return None
    hits = [
        labels[i]
        for i in range(len(labels))
        if i < len(thresholds)
        and thresholds[i] is not None
        and scores.get(labels[i], 0.0) >= thresholds[i]
    ]
    return ", ".join(hits)


@runtime_checkable
class ClassifierEngine(Protocol):
    name: str

    def classify_aa(
        self,
        aa_in: dict,
        labels: list[str],
        *,
        model: str = "",
        task: str = _DEFAULT_TASK,
        templates: list[str | None] | None = None,
        thresholds: list[float | None] | None = None,
    ) -> dict:
        """Score each chunk inside ``aa_in`` and return an updated AA dict.

        [templates] / [thresholds] are optional per-label metadata (aligned with
        ``labels``) sourced from a categories AA: a zero-shot ``hypothesis_template``
        and an acceptance ``threshold``. When [thresholds] is supplied the result
        gains a ``passed`` column per document.
        """
        ...


class StubClassifierEngine:
    """Deterministic placeholder engine operating on AA payloads.

    Scores are lexical-overlap based (how often a label's words occur in the
    text), with a base weight so no label collapses to zero, then normalised.
    Content-aware and plausible, but *not* a real model; ``model``/``task`` /
    ``templates`` are ignored. Per-category ``thresholds`` are still honoured to
    populate the ``passed`` column, so the thresholding path stays testable
    offline.
    """

    name = "stub"

    def classify_aa(
        self,
        aa_in: dict,
        labels: list[str],
        *,
        model: str = "",
        task: str = _DEFAULT_TASK,
        templates: list[str | None] | None = None,
        thresholds: list[float | None] | None = None,
    ) -> dict:
        chunks = extract_aa_chunks(aa_in)
        if not labels or not chunks:
            return aa_in

        results: dict[str, dict[str, float]] = {}
        passed: dict[str, str] | None = {} if thresholds is not None else None
        for row_id, text in chunks.items():
            text_l = text.lower()
            raw: list[float] = []
            for label in labels:
                words = [w for w in re.split(r"\W+", label.lower()) if w]
                hits = sum(text_l.count(w) for w in words) if words else 0
                raw.append(1.0 + float(hits))
            total = sum(raw) or 1.0
            scores = {label: round(r / total, 6) for label, r in zip(labels, raw)}
            results[row_id] = scores
            if passed is not None:
                passed[row_id] = _passing_labels(scores, labels, thresholds)

        return build_classified_aa(results, passed, aa_in=aa_in)


class _ModelManager:
    """Thread-safe, LRU-bounded cache of loaded zero-shot pipelines.

    A model is loaded on first use (a slow cold start — download + weights into
    memory) and then kept **warm** for subsequent requests. A per-model load
    lock ensures concurrent first-requests for the same model load it once;
    least-recently-used models are evicted past [max_models] to bound memory
    (the weights are large)."""

    def __init__(self, *, max_models: int = 1) -> None:
        self._max = max(1, max_models)
        self._pipes: "OrderedDict[str, Any]" = OrderedDict()
        self._lock = threading.Lock()
        self._load_locks: dict[str, threading.Lock] = {}

    def get(self, model_id: str, task: str) -> Any:
        with self._lock:
            cached = self._pipes.get(model_id)
            if cached is not None:
                self._pipes.move_to_end(model_id)
                return cached
            load_lock = self._load_locks.setdefault(model_id, threading.Lock())

        # Load outside the global lock (slow) but under the per-model lock so a
        # model is only built once even under concurrent first-requests.
        with load_lock:
            with self._lock:
                cached = self._pipes.get(model_id)
                if cached is not None:
                    self._pipes.move_to_end(model_id)
                    return cached
            pipe = _build_pipeline(model_id, task)
            with self._lock:
                self._pipes[model_id] = pipe
                self._pipes.move_to_end(model_id)
                while len(self._pipes) > self._max:
                    self._pipes.popitem(last=False)  # evict LRU
            return pipe


def _build_pipeline(model_id: str, task: str) -> Any:
    """Construct a zero-shot pipeline on the best available device. Imports are
    local so the module loads without torch/transformers present."""
    import torch  # noqa: PLC0415
    from transformers import pipeline  # noqa: PLC0415

    if torch.cuda.is_available():
        device: Any = 0
    elif getattr(torch.backends, "mps", None) is not None and torch.backends.mps.is_available():
        device = torch.device("mps")
    else:
        device = -1
    return pipeline(task or _DEFAULT_TASK, model=model_id, device=device)


class LocalTransformersClassifierEngine:
    """Real zero-shot inference for D4M AA streams via modernBert / transformers.

    The model identifier — a Hugging Face repo id or a local path — is passed to
    ``transformers.pipeline`` verbatim. Any failure (missing deps, unknown
    model, download error, OOM, unsupported source) degrades gracefully to the
    [StubClassifierEngine] for that request rather than crashing the pipeline.
    """

    name = "localTransformers"

    def __init__(self, *, max_models: int = 1, max_chars: int = _MAX_INPUT_CHARS) -> None:
        self._manager = _ModelManager(max_models=max_models)
        self._max_chars = max_chars
        self._fallback = StubClassifierEngine()

    def classify_aa(
        self,
        aa_in: dict,
        labels: list[str],
        *,
        model: str = "",
        task: str = _DEFAULT_TASK,
        templates: list[str | None] | None = None,
        thresholds: list[float | None] | None = None,
    ) -> dict:
        chunks = extract_aa_chunks(aa_in)
        if not labels or not chunks:
            return aa_in

        if not model:
            return self._fallback.classify_aa(
                aa_in, labels, model=model, task=task,
                templates=templates, thresholds=thresholds,
            )

        try:
            pipe = self._manager.get(model, task or _DEFAULT_TASK)
            # Per-category thresholds imply independent probabilities, so score
            # with multi_label; without them keep the single-label softmax
            # distribution (the historical behaviour).
            multi_label = thresholds is not None
            groups = _group_by_template(labels, templates)
            results: dict[str, dict[str, float]] = {}
            passed: dict[str, str] | None = {} if thresholds is not None else None

            # Execute prediction across all extracted chunk passages.
            for row_id, text in chunks.items():
                clipped = text[: self._max_chars]
                scored: dict[str, float] = {}
                # One pass per distinct hypothesis template (the pipeline takes a
                # single template per call).
                for template, group_labels in groups.items():
                    kwargs: dict[str, Any] = {
                        "candidate_labels": group_labels,
                        "multi_label": multi_label,
                    }
                    if template is not None:
                        kwargs["hypothesis_template"] = template
                    out = pipe(clipped, **kwargs)
                    result = out[0] if isinstance(out, list) else out
                    for label, score in zip(result["labels"], result["scores"]):
                        scored[label] = float(score)

                results[row_id] = {label: scored.get(label, 0.0) for label in labels}
                if passed is not None:
                    passed[row_id] = _passing_labels(results[row_id], labels, thresholds)

            return build_classified_aa(results, passed, aa_in=aa_in)

        except Exception as exc:
            _log.warning(
                "local classify fell back to stub for model %r: %s: %s",
                model,
                type(exc).__name__,
                exc,
            )
            return self._fallback.classify_aa(
                aa_in, labels, model=model, task=task,
                templates=templates, thresholds=thresholds,
            )


def transformers_available() -> bool:
    """True when both optional deps are importable (checked without importing)."""
    return (
        importlib.util.find_spec("transformers") is not None
        and importlib.util.find_spec("torch") is not None
    )


def default_classifier() -> ClassifierEngine:
    """The local engine when torch/transformers are installed, else the stub."""
    if transformers_available():
        return LocalTransformersClassifierEngine()
    return StubClassifierEngine()
