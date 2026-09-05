"""Inference abstraction for DoubleTouch.

The route layer never talks to a model directly — it calls an
:class:`InferenceEngine`. This keeps the API stable while the real SAM3 model is
ported from ``mlx_sam3`` (its ``processor`` + ``serialize_state`` logic slots in
behind this interface).

:class:`StubInferenceEngine` is the default: it returns deterministic,
bounding-box placeholder "masks" derived from the prompt so the whole service —
and the Flutter front-end against it — works end-to-end without model weights.
Placeholder masks are tagged ``format == "bboxPlaceholder"`` so no consumer
mistakes them for real RLE.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Protocol, runtime_checkable

from .sessions import Session


@dataclass
class SegmentOutcome:
    segment_mask: list[dict] = field(default_factory=list)
    boxes: list[list[float]] = field(default_factory=list)
    scores: list[float] = field(default_factory=list)
    peak_memory_mb: float | None = None


@runtime_checkable
class InferenceEngine(Protocol):
    name: str

    def text_prompt(self, session: Session, prompt: str) -> SegmentOutcome: ...

    def box_prompt(
        self, session: Session, box: list[float], include: bool
    ) -> SegmentOutcome: ...

    def point_prompt(
        self, session: Session, point: list[float], include: bool
    ) -> SegmentOutcome: ...


def _placeholder_mask(xyxy: list[float], width: int, height: int) -> dict:
    """A bounding-box stand-in for a real segmentation mask."""
    return {
        "format": "bboxPlaceholder",
        "size": [height, width],
        "bbox": [round(v, 2) for v in xyxy],
    }


def _cxcywh_to_xyxy(box: list[float], width: int, height: int) -> list[float]:
    cx, cy, w, h = box
    return [
        (cx - w / 2) * width,
        (cy - h / 2) * height,
        (cx + w / 2) * width,
        (cy + h / 2) * height,
    ]


class StubInferenceEngine:
    """Deterministic placeholder engine. Replace with the real SAM3 adapter."""

    name = "stub"

    def text_prompt(self, session: Session, prompt: str) -> SegmentOutcome:
        w, h = session.original_width, session.original_height
        # No geometry from text alone: return a centered region covering 60%.
        xyxy = [w * 0.2, h * 0.2, w * 0.8, h * 0.8]
        return SegmentOutcome(
            segment_mask=[_placeholder_mask(xyxy, w, h)],
            boxes=[xyxy],
            scores=[0.5],
        )

    def box_prompt(
        self, session: Session, box: list[float], include: bool
    ) -> SegmentOutcome:
        w, h = session.original_width, session.original_height
        xyxy = _cxcywh_to_xyxy(box, w, h)
        # Exclusions contribute no positive mask.
        if not include:
            return SegmentOutcome(boxes=[xyxy], scores=[0.0])
        return SegmentOutcome(
            segment_mask=[_placeholder_mask(xyxy, w, h)],
            boxes=[xyxy],
            scores=[0.5],
        )

    def point_prompt(
        self, session: Session, point: list[float], include: bool
    ) -> SegmentOutcome:
        w, h = session.original_width, session.original_height
        x, y = point[0] * w, point[1] * h
        xyxy = [x, y, x, y]
        if not include:
            return SegmentOutcome(boxes=[xyxy], scores=[0.0])
        return SegmentOutcome(
            segment_mask=[_placeholder_mask(xyxy, w, h)],
            boxes=[xyxy],
            scores=[0.5],
        )
