"""Request/response schemas for the DoubleTouch API.

Field names are snake_case in Python but serialise to camelCase on the wire
(``session_id`` -> ``sessionId``, ``segment_mask`` -> ``segmentMask``) so the
contract matches the Dart side. ``alias_generator`` produces the camelCase
aliases; ``populate_by_name`` lets the route layer build models with the
snake_case field names. FastAPI emits aliases via ``response_model``.
"""

from __future__ import annotations

from typing import Optional

from pydantic import BaseModel, ConfigDict


def to_camel(name: str) -> str:
    head, *tail = name.split("_")
    return head + "".join(word.capitalize() for word in tail)


class CamelModel(BaseModel):
    model_config = ConfigDict(alias_generator=to_camel, populate_by_name=True)


# --- Requests ---------------------------------------------------------------

class TextPromptRequest(CamelModel):
    session_id: str
    prompt: str


class BoxPromptRequest(CamelModel):
    # [centerX, centerY, width, height], each normalized to 0..1.
    session_id: str
    box: list[float]
    # True = include region, False = exclude region.
    include: bool = True


class PointPromptRequest(CamelModel):
    # [x, y], each normalized to 0..1.
    session_id: str
    point: list[float]
    include: bool = True


# --- Response pieces --------------------------------------------------------

class PromptedRegion(CamelModel):
    """A prompt the user has placed, echoed back for overlay rendering."""

    # Pixel-space [xMin, yMin, xMax, yMax]; a point is a zero-size box.
    box: list[float]
    include: bool
    is_point: bool = False


class SegmentResults(CamelModel):
    """The coordinate/mask map streamed to the viewport for rendering."""

    original_width: int
    original_height: int
    # One entry per detected instance. See InferenceEngine for the encoding;
    # the stub emits bounding-box placeholders (format == "bboxPlaceholder").
    segment_mask: list[dict] = []
    boxes: list[list[float]] = []
    scores: list[float] = []
    prompted_regions: list[PromptedRegion] = []


class InferenceMetrics(CamelModel):
    processing_time_ms: float
    peak_memory_mb: Optional[float] = None
    mask_count: int


class SegmentResponse(CamelModel):
    session_id: str
    # "text" | "box" | "point"
    prompt_kind: str
    results: SegmentResults
    inference_metrics: InferenceMetrics


class CreateSessionResponse(CamelModel):
    session_id: str
    original_width: int
    original_height: int


class HealthResponse(CamelModel):
    status: str
    engine: str
    active_sessions: int
