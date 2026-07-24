"""Zero-shot classification abstraction for DoubleTouch.

The route layer never talks to a model directly — it calls a
:class:`ClassifierEngine`. This keeps the API stable while a real runner is
wired in: a local ``transformers`` zero-shot pipeline, or a Hugging Face
Inference API call (``httpx`` is already a dependency), slots in behind this
interface without touching the route or the wire contract.

:class:`StubClassifierEngine` is the default — matching :mod:`inference`'s
segmentation stub — so the whole service, and the Flutter front-end against it,
works end-to-end without model weights. It produces deterministic, content-aware
placeholder scores from lexical overlap between each candidate label and the
document text, normalised to a distribution over the labels. Swap in the real
engine by assigning ``classifier`` in :mod:`app`.
"""

from __future__ import annotations

import re
from typing import Protocol, runtime_checkable


@runtime_checkable
class ClassifierEngine(Protocol):
    name: str

    def classify(self, text: str, labels: list[str]) -> dict[str, float]:
        """Score ``text`` against each candidate label; values sum to ~1.0."""
        ...


class StubClassifierEngine:
    """Deterministic placeholder engine. Replace with the real zero-shot runner.

    Scores are lexical-overlap based (how often a label's words occur in the
    text), with a base weight so no label collapses to zero, then normalised.
    A document that mentions a label's terms scores higher on that label, so the
    output is plausible and reacts to content — but it is *not* a real model.
    """

    name = "stub"

    def classify(self, text: str, labels: list[str]) -> dict[str, float]:
        if not labels:
            return {}
        text_l = text.lower()
        raw: list[float] = []
        for label in labels:
            words = [w for w in re.split(r"\W+", label.lower()) if w]
            hits = sum(text_l.count(w) for w in words) if words else 0
            # Base 1.0 keeps every label non-zero; hits tilt the distribution.
            raw.append(1.0 + float(hits))
        total = sum(raw) or 1.0
        return {label: round(r / total, 6) for label, r in zip(labels, raw)}
