"""DoubleTouch FastAPI application.

Clean re-implementation of the SAM3 interaction surface for DoubleNaught.
Three modalities — text, box, point — plus session bootstrap and health. All
responses are camelCase (see :mod:`double_touch.models`). Inference is delegated
to a pluggable :class:`InferenceEngine` (default: the deterministic stub).
"""

from __future__ import annotations

import time
from typing import Optional

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware

from .inference import InferenceEngine, SegmentOutcome, StubInferenceEngine, _cxcywh_to_xyxy
from .models import (
    BoxPromptRequest,
    CreateSessionResponse,
    HealthResponse,
    InferenceMetrics,
    PointPromptRequest,
    PromptedRegion,
    SegmentResponse,
    SegmentResults,
    TextPromptRequest,
)
from .sessions import PromptRecord, Session, SessionStore

DEFAULT_WIDTH = 1024
DEFAULT_HEIGHT = 1024

app = FastAPI(
    title="DoubleTouch — SAM3 Segmentation API",
    description="Text / box / point segmentation for DoubleNaught. camelCase JSON.",
    version="0.1.0",
)

# Allow the Flutter dev front-ends (web on :3000, plus any localhost port used
# by `flutter run`). Tighten for production.
app.add_middleware(
    CORSMiddleware,
    allow_origin_regex=r"http://(localhost|127\.0\.0\.1)(:\d+)?",
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

store = SessionStore()
engine: InferenceEngine = StubInferenceEngine()


def _require_session(session_id: str) -> Session:
    session = store.get(session_id)
    if session is None:
        raise HTTPException(status_code=404, detail=f"Session not found: {session_id}")
    return session


def _build_results(session: Session, outcome: SegmentOutcome) -> SegmentResults:
    """Assemble the camelCase results map, echoing all prompts as overlays."""
    regions: list[PromptedRegion] = []
    for p in session.prompts:
        if p.coordinates is None:
            continue
        if p.kind == "box":
            regions.append(
                PromptedRegion(
                    box=_cxcywh_to_xyxy(
                        p.coordinates, session.original_width, session.original_height
                    ),
                    include=p.include,
                )
            )
        elif p.kind == "point":
            x = p.coordinates[0] * session.original_width
            y = p.coordinates[1] * session.original_height
            regions.append(
                PromptedRegion(box=[x, y, x, y], include=p.include, is_point=True)
            )

    return SegmentResults(
        original_width=session.original_width,
        original_height=session.original_height,
        segment_mask=outcome.segment_mask,
        boxes=outcome.boxes,
        scores=outcome.scores,
        prompted_regions=regions,
    )


def _respond(
    session: Session, kind: str, outcome: SegmentOutcome, elapsed_ms: float
) -> SegmentResponse:
    results = _build_results(session, outcome)
    return SegmentResponse(
        session_id=session.session_id,
        prompt_kind=kind,
        results=results,
        inference_metrics=InferenceMetrics(
            processing_time_ms=round(elapsed_ms, 2),
            peak_memory_mb=outcome.peak_memory_mb,
            mask_count=len(outcome.segment_mask),
        ),
    )


@app.get("/health", response_model=HealthResponse)
async def health() -> HealthResponse:
    return HealthResponse(
        status="healthy", engine=engine.name, active_sessions=len(store)
    )


@app.post("/session", response_model=CreateSessionResponse)
async def create_session(
    width: int = DEFAULT_WIDTH, height: int = DEFAULT_HEIGHT
) -> CreateSessionResponse:
    """Mint a session without an upload — handy for testing/wiring."""
    session = store.create(width, height)
    return CreateSessionResponse(
        session_id=session.session_id,
        original_width=session.original_width,
        original_height=session.original_height,
    )


@app.post("/upload", response_model=CreateSessionResponse)
async def upload_image(
    file: UploadFile = File(...),
    width: Optional[int] = Form(None),
    height: Optional[int] = Form(None),
) -> CreateSessionResponse:
    """Create a session from an uploaded image.

    The clean service stores no pixels; it records the image dimensions so
    normalized prompts can be mapped back to pixel space. Supply `width`/
    `height` form fields, or the defaults are used. The real engine will decode
    the bytes and set the model image here.
    """
    await file.read()
    session = store.create(width or DEFAULT_WIDTH, height or DEFAULT_HEIGHT)
    return CreateSessionResponse(
        session_id=session.session_id,
        original_width=session.original_width,
        original_height=session.original_height,
    )


@app.post("/segment/text", response_model=SegmentResponse)
async def segment_with_text(request: TextPromptRequest) -> SegmentResponse:
    session = _require_session(request.session_id)
    session.prompts.append(PromptRecord(kind="text", prompt=request.prompt))
    start = time.perf_counter()
    outcome = engine.text_prompt(session, request.prompt)
    elapsed_ms = (time.perf_counter() - start) * 1000
    return _respond(session, "text", outcome, elapsed_ms)


@app.post("/segment/box", response_model=SegmentResponse)
async def segment_with_box(request: BoxPromptRequest) -> SegmentResponse:
    session = _require_session(request.session_id)
    session.prompts.append(
        PromptRecord(kind="box", include=request.include, coordinates=request.box)
    )
    start = time.perf_counter()
    outcome = engine.box_prompt(session, request.box, request.include)
    elapsed_ms = (time.perf_counter() - start) * 1000
    return _respond(session, "box", outcome, elapsed_ms)


@app.post("/segment/point", response_model=SegmentResponse)
async def segment_with_point(request: PointPromptRequest) -> SegmentResponse:
    session = _require_session(request.session_id)
    session.prompts.append(
        PromptRecord(kind="point", include=request.include, coordinates=request.point)
    )
    start = time.perf_counter()
    outcome = engine.point_prompt(session, request.point, request.include)
    elapsed_ms = (time.perf_counter() - start) * 1000
    return _respond(session, "point", outcome, elapsed_ms)
