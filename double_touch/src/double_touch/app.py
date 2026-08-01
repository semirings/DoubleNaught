"""DoubleTouch FastAPI application.

Clean re-implementation of the SAM3 interaction surface for DoubleNaught.
Three modalities — text, box, point — plus session bootstrap and health. All
responses are camelCase (see :mod:`double_touch.models`). Inference is delegated
to a pluggable :class:`InferenceEngine` (default: the deterministic stub).
"""

from __future__ import annotations

import json
import re
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional
from uuid import uuid4

import httpx
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.concurrency import run_in_threadpool
from fastapi.middleware.cors import CORSMiddleware

from .aa_utils import aa_rows, pick_text_column
from .chunking import (
    available_strategies,
    chunk_to_aa,
    count_tokens,
    extract_work,
    get_strategy,
    normalize_units,
)
from .classify import (
    ClassifierEngine,
    default_classifier,
    parse_categories_aa,
    transformers_available,
)
from .inference import InferenceEngine, SegmentOutcome, StubInferenceEngine, _cxcywh_to_xyxy
from . import review as review_logic
from .inventory import InventoryStore, select_aa
from .models import (
    D4mRequest,
    D4mResponse,
    REVIEW_STATUSES,
    URL_AUTHORS,
    Aa2JsonlRequest,
    Aa2JsonlResponse,
    Aa2JsonlStats,
    AssocArray,
    BoxPromptRequest,
    ChunkRequest,
    ChunkResponse,
    ChunkStats,
    ClassifyRequest,
    ClassifyResponse,
    CreateSessionResponse,
    FetchRequest,
    FetchResponse,
    HealthResponse,
    InferenceMetrics,
    InventoryEntryRequest,
    InventoryResponse,
    InventorySelectResponse,
    PointPromptRequest,
    PromptedRegion,
    ReviewDecisionRequest,
    ReviewOutputResponse,
    ReviewSessionResponse,
    ReviewStartRequest,
    SegmentResponse,
    SegmentResults,
    TextHealthResponse,
    TextInferRequest,
    TextInferResponse,
    TextInferenceMetrics,
    TextLoadRequest,
    TextLoadResponse,
    TextLoadStats,
    TextPromptRequest,
    UrlPayloadRequest,
    UrlPayloadResponse,
    UrlValidateRequest,
    UrlValidateResponse,
)
from .text_engine import (
    default_text_engine,
    messages_from_prompt_aa,
    mlx_available,
)
from .review import ReviewStore
from .sessions import PromptRecord, Session, SessionStore
from .d4m_ops import eval_expression

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
# Local transformers engine when torch/transformers are installed, else the
# deterministic stub (see double_touch.classify.default_classifier).
classifier: ClassifierEngine = default_classifier()

# Generative text engine — mlx-lm when available, else the deterministic stub
# (see double_touch.text_engine.default_text_engine).
text_engine = default_text_engine()

# Disk-backed review sessions (survive interruption; resumable). Tests point
# `review_store.base_dir` at a temp directory.
review_store = ReviewStore()

# Disk-backed, seed-on-first-run URL inventory. Tests point `inventory_store` at
# a temp directory.
inventory_store = InventoryStore()


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
        status="healthy",
        engine=engine.name,
        active_sessions=len(store),
        classifier=classifier.name,
        classifier_local_available=transformers_available(),
    )


@app.get("/text/health", response_model=TextHealthResponse)
async def text_health() -> TextHealthResponse:
    """Health snapshot for the text-inference subsystem."""
    return TextHealthResponse(
        backend=text_engine.name,
        mlx_available=mlx_available(),
        loaded_model_id=text_engine.loaded_model_id(),
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


# --- Inventory node (InventoryNode) -----------------------------------------


def _derive_work_title(url: str) -> str:
    """Best-effort title from a location: its final path segment, else its host.

    A bare URL captured from a URL Source node carries no curated title, so one
    is derived rather than rejecting the entry.
    """
    cleaned = url.strip().rstrip("/")
    if not cleaned:
        return "Untitled"
    tail = cleaned.rsplit("/", 1)[-1]
    tail = tail.split("?", 1)[0].split("#", 1)[0]
    stem = tail.rsplit(".", 1)[0] if "." in tail else tail
    return stem or "Untitled"


def _validate_inventory_fields(request: InventoryEntryRequest) -> None:
    """A location is the only hard requirement.

    `author` stays constrained to URL_AUTHORS *when supplied*, preserving the
    curated-corpus contract, but may be empty for an uncurated capture.
    `work_title` is derived when omitted.
    """
    if not request.url.strip():
        raise HTTPException(status_code=422, detail="url must not be empty")
    if request.author and request.author not in URL_AUTHORS:
        raise HTTPException(
            status_code=422,
            detail=f"author must be one of {URL_AUTHORS}, got {request.author!r}",
        )


def _entry_fields(request: InventoryEntryRequest) -> dict:
    title = request.work_title.strip() or _derive_work_title(request.url)
    return {
        "url": request.url.strip(),
        "author": request.author,
        "work_title": title,
        "work_selector": request.work_selector,
        "description": request.description,
    }


@app.get("/inventory", response_model=InventoryResponse)
async def inventory_list() -> InventoryResponse:
    """Read the full inventory AA (seeded on first run)."""
    return InventoryResponse(aa=inventory_store.load())


@app.post("/inventory", response_model=InventoryResponse)
async def inventory_create(request: InventoryEntryRequest) -> InventoryResponse:
    """Create an entry; returns the updated inventory AA."""
    _validate_inventory_fields(request)
    return InventoryResponse(aa=inventory_store.create(_entry_fields(request)))


@app.put("/inventory/{entry_id}", response_model=InventoryResponse)
async def inventory_update(entry_id: str, request: InventoryEntryRequest) -> InventoryResponse:
    """Update an existing entry; returns the updated inventory AA."""
    _validate_inventory_fields(request)
    aa = inventory_store.update(entry_id, _entry_fields(request))
    if aa is None:
        raise HTTPException(status_code=404, detail=f"inventory entry not found: {entry_id}")
    return InventoryResponse(aa=aa)


@app.delete("/inventory/{entry_id}", response_model=InventoryResponse)
async def inventory_delete(entry_id: str) -> InventoryResponse:
    """Delete an entry; returns the updated inventory AA."""
    aa = inventory_store.delete(entry_id)
    if aa is None:
        raise HTTPException(status_code=404, detail=f"inventory entry not found: {entry_id}")
    return InventoryResponse(aa=aa)


@app.post("/inventory/{entry_id}/select", response_model=InventorySelectResponse)
async def inventory_select(entry_id: str) -> InventorySelectResponse:
    """Emit the selected entry as an AA payload (with a selection timestamp)."""
    entry = inventory_store.get(entry_id)
    if entry is None:
        raise HTTPException(status_code=404, detail=f"inventory entry not found: {entry_id}")
    return InventorySelectResponse(aa=select_aa(entry))


# --- URL source node (URLNode) ----------------------------------------------

# HEAD-probe budget. Kept short so the frontend Validate button stays snappy;
# redirects are followed so a 301/302 to a reachable target still reads as OK.
_URL_PROBE_TIMEOUT_S = 10.0


@app.post("/url/validate", response_model=UrlValidateResponse)
async def validate_url(request: UrlValidateRequest) -> UrlValidateResponse:
    """Probe [url] with an HTTP HEAD request to confirm it is reachable.

    Never raises on an unreachable target — a failed probe is a normal result,
    returned as ``reachable=false`` with a ``detail`` the node surfaces inline.
    """
    url = request.url.strip()
    if not url:
        raise HTTPException(status_code=422, detail="url must not be empty")
    try:
        async with httpx.AsyncClient(
            follow_redirects=True, timeout=_URL_PROBE_TIMEOUT_S
        ) as client:
            resp = await client.head(url)
        reachable = resp.status_code < 400
        return UrlValidateResponse(
            url=url,
            reachable=reachable,
            status_code=resp.status_code,
            detail=None if reachable else f"HEAD returned {resp.status_code}",
        )
    except (httpx.HTTPError, httpx.InvalidURL) as exc:
        # Bad scheme, DNS failure, connection refused, timeout, etc.
        return UrlValidateResponse(
            url=url, reachable=False, status_code=None, detail=str(exc) or type(exc).__name__
        )


@app.post("/url/payload", response_model=UrlPayloadResponse)
async def url_payload(request: UrlPayloadRequest) -> UrlPayloadResponse:
    """Emit the URLNode's D4M/AA payload.

    A 1-row associative array keyed by ``nodeId`` with one column per metadata
    field. Every value is a string (``validated`` -> "true"/"false"; the
    server stamps ``timestamp`` as ISO-8601 UTC) per the AA output contract.
    """
    if request.author not in URL_AUTHORS:
        raise HTTPException(
            status_code=422,
            detail=f"author must be one of {URL_AUTHORS}, got {request.author!r}",
        )
    timestamp = datetime.now(timezone.utc).isoformat()
    cols = ["url", "author", "work_title", "work_selector", "validated", "timestamp"]
    vals = [
        request.url,
        request.author,
        request.work_title,
        request.work_selector,
        "true" if request.validated else "false",
        timestamp,
    ]
    aa = AssocArray(rows=[request.node_id] * len(cols), cols=cols, vals=vals)
    return UrlPayloadResponse(node_id=request.node_id, aa=aa)


# --- Fetch node (FetchNode) -------------------------------------------------

# GET budget for a full document body — longer than the HEAD probe since we pull
# the whole text.
_FETCH_TIMEOUT_S = 30.0

# Project Gutenberg boilerplate markers. Real files use both "THE" and "THIS"
# ("*** START OF THE/THIS PROJECT GUTENBERG EBOOK <title> ***"); the title
# between "EBOOK" and the closing "***" is matched non-greedily. Case-insensitive
# for robustness.
_GUTENBERG_START = re.compile(
    r"\*\*\*\s*START OF TH(?:E|IS) PROJECT GUTENBERG EBOOK.*?\*\*\*", re.IGNORECASE
)
_GUTENBERG_END = re.compile(
    r"\*\*\*\s*END OF TH(?:E|IS) PROJECT GUTENBERG EBOOK.*?\*\*\*", re.IGNORECASE
)


def _aa_value(aa: AssocArray, col: str) -> Optional[str]:
    """Look up the value stored under column [col] in a (single-row) AA."""
    try:
        idx = aa.cols.index(col)
    except ValueError:
        return None
    return aa.vals[idx] if idx < len(aa.vals) else None


def _chunk_id(index: int) -> str:
    """Sequential AA row key for a text chunk (zero-padded for stable sort)."""
    return f"chunk:{index:05d}"


def _strip_gutenberg(text: str) -> str:
    """Return only the body between the Gutenberg START/END markers.

    Stripping triggers **only** when both markers are present, so the node stays
    general-purpose: any non-Gutenberg URL returns its text unchanged. When the
    markers are found, everything outside them (the license header/footer) is
    discarded.
    """
    start = _GUTENBERG_START.search(text)
    if not start:
        return text
    end = _GUTENBERG_END.search(text, start.end())
    if not end:
        return text
    return text[start.end() : end.start()].strip()


@app.post("/classify", response_model=ClassifyResponse)
async def classify_documents(request: ClassifyRequest) -> ClassifyResponse:
    """Zero-shot classify each incoming document against the candidate labels.

    AA-in (``documents``: rows = doc id, col ``text``) -> AA-out (rows = doc id,
    cols = label names, vals = scores). The model identifier is passed to the engine
    verbatim — a Hugging Face repo id, or a resolved URL/path.

    Candidate labels come from the ``categories`` AA when supplied (its ``label``
    column, plus per-category ``hypothesis_template`` and ``threshold``); otherwise
    from the flat ``labels`` list.
    """
    templates: list | None = None
    thresholds: list | None = None
    if request.categories is not None and request.categories.rows:
        categories_dict = {
            "row": request.categories.rows,
            "col": request.categories.cols,
            "val": request.categories.vals,
        }
        labels, templates, thresholds = parse_categories_aa(categories_dict)
    else:
        labels = [label.strip() for label in request.labels if label.strip()]
    if not labels:
        raise HTTPException(status_code=422, detail="no candidate labels provided")
    if not request.documents.rows:
        raise HTTPException(status_code=422, detail="documents AA is empty")

    def _run() -> dict:
        # Blocking: model load (cold start) + inference. Runs in a worker thread
        # so it never blocks the event loop.
        # Convert AssocArray to dict (row/col/val keys instead of rows/cols/vals)
        aa_in = {
            "row": request.documents.rows,
            "col": request.documents.cols,
            "val": request.documents.vals,
        }
        return classifier.classify_aa(
            aa_in,
            labels,
            model=request.model,
            task=request.task,
            templates=templates,
            thresholds=thresholds,
        )

    aa_out = await run_in_threadpool(_run)
    return ClassifyResponse(
        aa=AssocArray(
            rows=aa_out.get("row", []),
            cols=aa_out.get("col", []),
            vals=aa_out.get("val", []),
        )
    )


@app.post("/fetch", response_model=FetchResponse)
async def fetch_text(request: FetchRequest) -> FetchResponse:
    """Fetch the URL's text, strip Gutenberg boilerplate, emit a cleaned-text AA.

    AA-in (URLNode) -> AA-out (ChunkNode). Produces a single chunk row
    (``chunk:00000``) carrying the whole cleaned document; ChunkNode later splits
    it into many rows sharing this schema.
    """
    url = _aa_value(request.aa, "url")
    if not url:
        raise HTTPException(status_code=422, detail="AA payload missing a 'url' column")
    author = _aa_value(request.aa, "author") or ""
    work_title = _aa_value(request.aa, "work_title") or ""
    # Carried through unchanged so ChunkNode can locate the target work.
    work_selector = _aa_value(request.aa, "work_selector") or ""

    try:
        async with httpx.AsyncClient(
            follow_redirects=True, timeout=_FETCH_TIMEOUT_S
        ) as client:
            resp = await client.get(url)
        resp.raise_for_status()
    except httpx.HTTPError as exc:
        raise HTTPException(
            status_code=502, detail=f"fetch failed: {exc or type(exc).__name__}"
        ) from exc

    raw_text = _strip_gutenberg(resp.text)
    fetch_timestamp = datetime.now(timezone.utc).isoformat()

    cols = ["raw_text", "author", "work_title", "work_selector", "char_count", "fetch_timestamp"]
    vals = [raw_text, author, work_title, work_selector, str(len(raw_text)), fetch_timestamp]
    aa = AssocArray(rows=[_chunk_id(0)] * len(cols), cols=cols, vals=vals)
    return FetchResponse(aa=aa)


# --- Chunk node (ChunkNode) -------------------------------------------------


@app.post("/chunk", response_model=ChunkResponse)
async def chunk_text(request: ChunkRequest) -> ChunkResponse:
    """Apply author-aware chunking to the upstream cleaned text, emitting an AA
    of discrete passages.

    AA-in (FetchNode) -> AA-out (downstream). The author tag selects a chunking
    strategy from the registry (:mod:`double_touch.chunking`); the shared
    token-range contract (50-300) is enforced uniformly. Row keys are sequential
    and globally unique (a per-run id prefix + zero-padded index).
    """
    raw_text = _aa_value(request.aa, "raw_text")
    if not raw_text:
        raise HTTPException(status_code=422, detail="AA payload missing a 'raw_text' column")
    author = (_aa_value(request.aa, "author") or "").strip().lower()
    work_title = _aa_value(request.aa, "work_title") or ""
    # Optional: locate & extract the target work from a multi-work file before
    # chunking. Empty selector or single-work file -> the whole text is used.
    work_selector = _aa_value(request.aa, "work_selector") or ""

    try:
        run_id = uuid4().hex[:8]
        rows, cols, vals = chunk_to_aa(
            raw_text,
            author,
            work_title,
            work_selector=work_selector,
            run_id=f"chunk:{run_id}",
        )
    except KeyError:
        raise HTTPException(
            status_code=422,
            detail=f"no chunking strategy for author {author!r}; "
            f"known strategies: {available_strategies()}",
        )

    # Extract token_count values for stats (they're at indices where col == "token_count")
    token_counts = [vals[i] for i, col in enumerate(cols) if col == "token_count"]
    total_tokens = sum(token_counts)
    stats = ChunkStats(
        chunk_count=len(token_counts),
        total_tokens=total_tokens,
        min_tokens=min(token_counts) if token_counts else 0,
        max_tokens=max(token_counts) if token_counts else 0,
        mean_tokens=round(total_tokens / len(token_counts), 1) if token_counts else 0.0,
    )
    return ChunkResponse(aa=AssocArray(rows=rows, cols=cols, vals=vals), stats=stats)


# --- AA→JSONL node (AA2JSONLNode) -------------------------------------------

# Phi-4 fine-tuning line formatters, keyed by the selectable format id. Add a
# new entry here to support another format — the route needs no other change.
_JSONL_FORMATTERS = {
    "instruction-completion": lambda text: {
        "prompt": "Write in the GCC voice:",
        "completion": text,
    },
    "continuation": lambda text: {"text": text},
}

# Output AA columns, in order (all string-valued).
_AA2JSONL_COLUMNS = ["jsonl_line", "format", "output_file", "write_timestamp", "status"]


@app.post("/aa2jsonl", response_model=Aa2JsonlResponse)
async def aa_to_jsonl(request: Aa2JsonlRequest) -> Aa2JsonlResponse:
    """Write an AA of passages to a JSONL file formatted for Phi-4 fine-tuning.

    Iterates rows in ``position`` order, formats each chunk's text per the
    selected format, validates each line is valid JSON, and writes one object
    per line. Emits a provenance AA — one row per source chunk, keyed by the
    original chunkID — recording the line written and its status.
    """
    formatter = _JSONL_FORMATTERS.get(request.format)
    if formatter is None:
        raise HTTPException(
            status_code=422,
            detail=f"unknown format {request.format!r}; "
            f"known formats: {sorted(_JSONL_FORMATTERS)}",
        )
    output_file = request.output_file.strip()
    if not output_file:
        raise HTTPException(status_code=422, detail="outputFile must not be empty")

    text_col = pick_text_column(request.aa)
    if text_col is None:
        raise HTTPException(
            status_code=422, detail="AA payload has no 'text' or 'raw_text' column"
        )

    records = aa_rows(request.aa)
    # Order by the integer `position` column when present; rows without it keep
    # their first-appearance order (stable sort, missing positions sort last).
    records.sort(
        key=lambda rec: rec[1].get("position")
        if isinstance(rec[1].get("position"), int)
        else float("inf")
    )

    write_timestamp = datetime.now(timezone.utc).isoformat()
    resolved = str(Path(output_file).expanduser())

    out_rows: list[str] = []
    out_cols: list[str] = []
    out_vals: list = []
    lines: list[str] = []
    skipped = 0

    for chunk_id, record in records:
        text = record.get(text_col)
        jsonl_line = ""
        status = "written"
        if not isinstance(text, str) or not text.strip():
            status = "skipped"
            skipped += 1
        else:
            try:
                jsonl_line = json.dumps(formatter(text), ensure_ascii=False)
                json.loads(jsonl_line)  # validate before accepting the line
                lines.append(jsonl_line)
            except (TypeError, ValueError):
                jsonl_line = ""
                status = "skipped"
                skipped += 1
        for col, value in zip(
            _AA2JSONL_COLUMNS,
            [jsonl_line, request.format, resolved, write_timestamp, status],
        ):
            out_rows.append(chunk_id)
            out_cols.append(col)
            out_vals.append(value)

    try:
        path = Path(resolved)
        if path.parent and not path.parent.exists():
            path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("".join(f"{line}\n" for line in lines), encoding="utf-8")
        file_size = path.stat().st_size
    except OSError as exc:
        raise HTTPException(
            status_code=400, detail=f"could not write {resolved}: {exc}"
        ) from exc

    stats = Aa2JsonlStats(
        lines_written=len(lines),
        skipped=skipped,
        output_file=resolved,
        file_size_bytes=file_size,
    )
    return Aa2JsonlResponse(
        aa=AssocArray(rows=out_rows, cols=out_cols, vals=out_vals), stats=stats
    )


# --- Review node (ReviewNode) -----------------------------------------------


def _review_response(session) -> ReviewSessionResponse:
    return ReviewSessionResponse(
        review_id=session.review_id,
        passages=session.passages,
        counts=review_logic.counts(session),
        complete=review_logic.is_complete(session),
    )


@app.post("/review/start", response_model=ReviewSessionResponse)
async def review_start(request: ReviewStartRequest) -> ReviewSessionResponse:
    """Begin (or transparently resume) a review of the upstream AA.

    The session id is derived from the passage content, so re-starting a review
    of the same document returns the saved decisions instead of restarting.
    """
    fresh = review_logic.session_from_aa(request.aa)
    if fresh is None:
        raise HTTPException(
            status_code=422, detail="AA payload has no 'text' or 'raw_text' column"
        )
    existing = review_store.load(fresh.review_id)
    session = existing or fresh
    if existing is None:
        review_store.save(session)
    return _review_response(session)


@app.get("/review/session/{review_id}", response_model=ReviewSessionResponse)
async def review_session(review_id: str) -> ReviewSessionResponse:
    """Resume an interrupted review session by id."""
    session = review_store.load(review_id)
    if session is None:
        raise HTTPException(status_code=404, detail=f"review session not found: {review_id}")
    return _review_response(session)


@app.post("/review/decision", response_model=ReviewSessionResponse)
async def review_decision(request: ReviewDecisionRequest) -> ReviewSessionResponse:
    """Record an approve / edit / reject decision for one passage and persist."""
    session = review_store.load(request.review_id)
    if session is None:
        raise HTTPException(
            status_code=404, detail=f"review session not found: {request.review_id}"
        )
    try:
        review_logic.apply_decision(
            session, request.chunk_id, request.status, request.edited_text
        )
    except ValueError:
        raise HTTPException(
            status_code=422,
            detail=f"status must be one of {REVIEW_STATUSES}, got {request.status!r}",
        )
    except KeyError:
        raise HTTPException(
            status_code=404, detail=f"chunk not in session: {request.chunk_id}"
        )
    review_store.save(session)
    return _review_response(session)


@app.get("/review/output/{review_id}", response_model=ReviewOutputResponse)
async def review_output(review_id: str) -> ReviewOutputResponse:
    """The full audit AA (every decided passage, including rejected) + counts."""
    session = review_store.load(review_id)
    if session is None:
        raise HTTPException(status_code=404, detail=f"review session not found: {review_id}")
    return ReviewOutputResponse(
        aa=review_logic.output_aa(session), counts=review_logic.counts(session)
    )


# --- Text inference nodes ---------------------------------------------------
# Four-node pipeline:  TextModelLoaderNode → TextPromptNode
#                      → TextInferenceNode → TextPreviewNode
#
# POST /text/load   — warm the model into cache; return model-handle AA.
# POST /text/infer  — run mlx-lm.generate; return result AA + metrics.
#
# Both run in a thread-pool worker so they never block the event loop.  The
# model-handle AA emitted by /text/load is passed verbatim to /text/infer,
# which extracts the `model_id` column to look up (or reload) the cached model.


def _aa_value_by_col(aa: AssocArray, col: str) -> Optional[str]:
    """Return the first value in [aa] whose column matches [col]."""
    try:
        idx = aa.cols.index(col)
        return str(aa.vals[idx]) if idx < len(aa.vals) else None
    except ValueError:
        return None


@app.post("/text/load", response_model=TextLoadResponse)
async def text_load(request: TextLoadRequest) -> TextLoadResponse:
    """Load (or warm from cache) a generative text model.

    The response includes a model-handle AA (row ``model:<slug>``, attribute
    columns) that the Flutter canvas emits on the ``modelHandle`` output port,
    ready to wire into ``TextInferenceNode``.  If the model is already cached
    this is a near-instant metadata round-trip.
    """
    model_id = request.model_id.strip()
    if not model_id:
        raise HTTPException(status_code=422, detail="modelId must not be empty")

    def _run() -> dict:
        return text_engine.load_model(
            model_id, lora_path=request.lora_path.strip() or None
        )

    handle_dict = await run_in_threadpool(_run)
    handle_aa = AssocArray(
        rows=handle_dict["row"],
        cols=handle_dict["col"],
        vals=handle_dict["val"],
    )

    # Surface key stats directly in the response for the node's UI.
    ctx = int(_aa_value_by_col(handle_aa, "context_length") or "4096")
    loaded_at = _aa_value_by_col(handle_aa, "loaded_at") or ""
    stats = TextLoadStats(
        model_id=model_id,
        backend=text_engine.name,
        context_length=ctx,
        lora_path=request.lora_path.strip(),
        loaded_at=loaded_at,
    )
    return TextLoadResponse(handle=handle_aa, stats=stats)


@app.post("/text/infer", response_model=TextInferResponse)
async def text_infer(request: TextInferRequest) -> TextInferResponse:
    """Run generative inference and return the result AA + metrics.

    Consumes two upstream AAs:
    * ``model_handle`` — from TextModelLoaderNode (carries ``model_id``).
    * ``prompt``       — from TextPromptNode (carries ``system_prompt`` /
                         ``user_prompt`` / ``ext:image_prompt``).

    The result AA row (``result:<uuid12>``) carries ``response_text`` plus
    token-count / latency columns and the forward-compatibility ``ext:``
    slots that downstream nodes (Flux, AA-context injection) can consume.
    """
    model_id = _aa_value_by_col(request.model_handle, "model_id")
    if not model_id:
        raise HTTPException(
            status_code=422,
            detail="modelHandle AA is missing a 'model_id' column",
        )

    messages = messages_from_prompt_aa(
        request.prompt.rows,
        request.prompt.cols,
        request.prompt.vals,
    )
    if not any(m.get("role") == "user" for m in messages):
        raise HTTPException(
            status_code=422,
            detail="prompt AA must contain a non-empty 'user_prompt' column",
        )

    p = request.params
    t_start = time.perf_counter()

    def _run() -> dict:
        return text_engine.generate(
            model_id,
            messages,
            max_tokens=p.max_tokens,
            temperature=p.temperature,
            top_p=p.top_p,
            repetition_penalty=p.repetition_penalty,
        )

    result_dict = await run_in_threadpool(_run)
    elapsed_ms = (time.perf_counter() - t_start) * 1000

    result_aa = AssocArray(
        rows=result_dict["row"],
        cols=result_dict["col"],
        vals=result_dict["val"],
    )

    input_tokens = int(_aa_value_by_col(result_aa, "input_tokens") or "0")
    output_tokens = int(_aa_value_by_col(result_aa, "output_tokens") or "0")
    tps = float(_aa_value_by_col(result_aa, "tokens_per_sec") or "0")
    stop_reason = _aa_value_by_col(result_aa, "stop_reason") or "eos"

    metrics = TextInferenceMetrics(
        model_id=model_id,
        input_tokens=input_tokens,
        output_tokens=output_tokens,
        tokens_per_sec=round(tps, 2),
        stop_reason=stop_reason,
        generation_time_ms=round(elapsed_ms, 2),
    )
    return TextInferResponse(result=result_aa, metrics=metrics)


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


# ---------------------------------------------------------------------------
# D4M expression node (D4MNode)
# ---------------------------------------------------------------------------

@app.post("/d4m/eval", response_model=D4mResponse)
async def d4m_eval(request: D4mRequest) -> D4mResponse:
    """Evaluate a D4M expression over named input AAs and return the result AA.

    ``request.inputs`` is a mapping of variable name → AssocArray (e.g.
    ``{"A": ..., "B": ...}``); ``request.expression`` is a D4M expression
    string (``A + B``, ``A("chunk: ", "score: ")``, etc.).  The expression is
    evaluated by Python :func:`eval` in a namespace containing the named
    D4M :class:`Assoc` objects.  Returns HTTP 422 when the expression is
    invalid or the result is not an Assoc.
    """
    try:
        result_aa = await run_in_threadpool(
            eval_expression, request.inputs, request.expression
        )
        return D4mResponse(aa=result_aa)
    except Exception as exc:
        raise HTTPException(status_code=422, detail=str(exc))
