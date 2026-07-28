"""Zero-shot classification abstraction for DoubleTouch.

The route layer never talks to a model directly — it calls a
:class:`ClassifierEngine`. Two engines implement the interface:

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
"""

from __future__ import annotations

import importlib.util
import logging
import re
import threading
from collections import OrderedDict
from typing import Any, Protocol, runtime_checkable

_log = logging.getLogger("double_touch.classify")

# Zero-shot inputs are truncated to the model's context by the pipeline; this is
# a coarse pre-truncation guard so we never tokenize a huge string.
_MAX_INPUT_CHARS = 10_000
_DEFAULT_TASK = "zero-shot-classification"


@runtime_checkable
class ClassifierEngine(Protocol):
    name: str

    def classify(
        self,
        text: str,
        labels: list[str],
        *,
        model: str = "",
        task: str = _DEFAULT_TASK,
    ) -> dict[str, float]:
        """Score ``text`` against each candidate label; values sum to ~1.0."""
        ...


class StubClassifierEngine:
    """Deterministic placeholder engine — no model weights.

    Scores are lexical-overlap based (how often a label's words occur in the
    text), with a base weight so no label collapses to zero, then normalised.
    Content-aware and plausible, but *not* a real model; ``model``/``task`` are
    ignored.
    """

    name = "stub"

    def classify(
        self,
        text: str,
        labels: list[str],
        *,
        model: str = "",
        task: str = _DEFAULT_TASK,
    ) -> dict[str, float]:
        if not labels:
            return {}
        text_l = text.lower()
        raw: list[float] = []
        for label in labels:
            words = [w for w in re.split(r"\W+", label.lower()) if w]
            hits = sum(text_l.count(w) for w in words) if words else 0
            raw.append(1.0 + float(hits))
        total = sum(raw) or 1.0
        return {label: round(r / total, 6) for label, r in zip(labels, raw)}


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
    """Real, offline zero-shot classification via ``transformers`` + ``torch``.

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

    def classify(
        self,
        text: str,
        labels: list[str],
        *,
        model: str = "",
        task: str = _DEFAULT_TASK,
    ) -> dict[str, float]:
        if not labels:
            return {}
        if not model:
            # No weights specified — nothing to load; use the placeholder.
            return self._fallback.classify(text, labels, model=model, task=task)
        try:
            pipe = self._manager.get(model, task or _DEFAULT_TASK)
            # Coarse pre-truncation; the zero-shot pipeline also truncates the
            # sequence to the model's context window (ONLY_FIRST) so long inputs
            # never raise a context-length error.
            clipped = text[: self._max_chars]
            out = pipe(clipped, candidate_labels=labels)
            result = out[0] if isinstance(out, list) else out
            scored = {
                label: float(score)
                for label, score in zip(result["labels"], result["scores"])
            }
            # Return in the caller's label order; unseen labels default to 0.
            return {label: scored.get(label, 0.0) for label in labels}
        except Exception as exc:
            # Missing deps / bad model / download / device / OOM — never crash.
            # Log loudly so a silent stub fallback is never a mystery.
            _log.warning(
                "local classify fell back to stub for model %r: %s: %s",
                model,
                type(exc).__name__,
                exc,
            )
            return self._fallback.classify(text, labels, model=model, task=task)


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
