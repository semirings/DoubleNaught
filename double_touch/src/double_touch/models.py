"""Request/response schemas for the DoubleTouch API.

Field names are snake_case in Python but serialise to camelCase on the wire
(``session_id`` -> ``sessionId``, ``segment_mask`` -> ``segmentMask``) so the
contract matches the Dart side. ``alias_generator`` produces the camelCase
aliases; ``populate_by_name`` lets the route layer build models with the
snake_case field names. FastAPI emits aliases via ``response_model``.
"""

from __future__ import annotations

from typing import Optional, Union

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
    # The active classification engine ("localTransformers" | "stub") and whether
    # the optional torch/transformers deps are importable. Lets a caller tell at a
    # glance whether real local inference is running or the placeholder stub is.
    classifier: str = "stub"
    classifier_local_available: bool = False


# --- URL source node (URLNode) ----------------------------------------------
# A source node: no upstream input. It validates a URL and emits a D4M/AA
# associative array describing the referenced work for downstream nodes
# (FetchNode). See DESIGN.md "Data-contract boundary".

# The three known authors the frontend dropdown offers.
URL_AUTHORS = ("gilbert", "chesterton", "churchill")


class UrlValidateRequest(CamelModel):
    url: str


class UrlValidateResponse(CamelModel):
    url: str
    # True when the HEAD probe returned an HTTP status < 400.
    reachable: bool
    # HTTP status from the HEAD probe, or null when the request never completed.
    status_code: Optional[int] = None
    # Human-readable reason when unreachable (bad scheme, timeout, 4xx/5xx).
    detail: Optional[str] = None


class UrlPayloadRequest(CamelModel):
    # Row key of the emitted AA — the workflow node's id, stringified.
    node_id: str
    url: str
    # One of URL_AUTHORS.
    author: str
    work_title: str
    # Optional marker used by ChunkNode to locate a specific work within a
    # multi-work file. Empty for single-work files.
    work_selector: str = ""
    # Reachability result carried in from a prior /url/validate call.
    validated: bool = False


class AssocArray(CamelModel):
    """A D4M/AA associative array in sparse triple form.

    ``rows``/``cols``/``vals`` are parallel lists: entry *k* is the triple
    ``(rows[k], cols[k], vals[k])``. Values are strings for most columns;
    inherently-numeric columns carry integers (e.g. ChunkNode's ``position`` /
    ``token_count``) or floats (e.g. ModelClassifierNode's category scores). This
    is the same ``(row, col, val)`` shape D4M's ``aa.find()`` yields, so it
    round-trips cleanly to/from a real AA (``AAschema/schemas/rcvs.json``).
    """

    rows: list[str]
    cols: list[str]
    vals: list[Union[str, int, float]]

    def to_dict(self) -> dict:
        """Convert AssocArray into a {column: [values]} lookup dict."""
        from .aa_utils import aa_rows
        records = aa_rows(self)
        text_list = []
        for r_key, rec in records:
            if "text" in rec:
                text_list.append(rec["text"])
            elif "raw_text" in rec:
                text_list.append(rec["raw_text"])
        return {"text": text_list if text_list else [None]}


class UrlPayloadResponse(CamelModel):
    node_id: str
    aa: AssocArray


# --- Model Classifier node (ModelClassifierNode) ----------------------------
# A functional node: it runs zero-shot classification over incoming documents
# against a set of candidate labels and emits a documents×labels score AA.


class ClassifyRequest(CamelModel):
    # Model identifier passed to the runner verbatim: a Hugging Face repo id
    # (e.g. "MoritzLaurer/ModernBERT-large-zeroshot-v2.0"), or a resolved web
    # URL / local path.
    model: str
    # "huggingface" | "remote_url" | "local".
    source_type: str = ""
    task: str = "zero-shot-classification"
    # Candidate labels to score each document against. Optional when
    # ``categories`` is supplied (its ``label`` column supersedes this list).
    labels: list[str] = []
    # Optional categories AA (rows = category, cols = ``label`` +
    # ``hypothesis_template`` + ``threshold``). When present it supersedes
    # ``labels`` and drives per-category hypothesis templates and thresholds.
    categories: AssocArray | None = None
    # Documents to classify: rows = document id, col ``text``, val = the text.
    documents: AssocArray


class ClassifyResponse(CamelModel):
    # Result AA: rows = document id, cols = labels, vals = scores (0..1). When
    # categories carry thresholds, each document also gains a ``passed`` column
    # listing the categories that met their threshold.
    classification_scores: AssocArray


# --- Inventory node (InventoryNode) -----------------------------------------
# A source node that maintains a persistent, editable list of URL entries and
# outputs a single selected entry as a D4M/AA payload to URLNode downstream.


class InventoryEntryRequest(CamelModel):
    url: str
    # One of URL_AUTHORS when curated; empty means unassigned, which is what a
    # bare location captured from a URL Source node has.
    author: str = ""
    # Derived from the URL's final path segment when omitted.
    work_title: str = ""
    # Optional marker for locating a work within a multi-work file.
    work_selector: str = ""
    # Human-readable label.
    description: str = ""


class InventoryResponse(CamelModel):
    # The full inventory as an AA (rows == entryID; one row per entry).
    aa: AssocArray


class InventorySelectResponse(CamelModel):
    # A single selected entry as an AA payload for URLNode (adds selected_timestamp).
    aa: AssocArray


# --- Fetch node (FetchNode) -------------------------------------------------
# A processing node (AA-in -> AA-out, per DESIGN.md): it consumes the URLNode
# AA, fetches the URL's text, strips Project Gutenberg boilerplate when present,
# and emits a new AA of cleaned text for ChunkNode downstream.


class FetchRequest(CamelModel):
    # The upstream URLNode associative array (carries url/author/work_title).
    work_metadata: AssocArray


class FetchResponse(CamelModel):
    work_metadata: AssocArray


# --- Chunk node (ChunkNode) -------------------------------------------------
# A processing node (AA-in -> AA-out): it consumes the FetchNode AA of cleaned
# text, applies author-aware chunking, and emits an AA of discrete passages for
# downstream processing.


class ChunkRequest(CamelModel):
    # The upstream FetchNode AA (carries raw_text/author/work_title).
    aa: AssocArray
    # "author" (default — existing author-registry path),
    # "paragraph_sentence", or "character_count".
    chunk_strategy: str = "author"
    # paragraph_sentence: max tokens per chunk before flushing (default 300).
    max_tokens: int = 300
    # character_count: max characters per window.
    max_chars: int = 1000
    # Overlap carried into the next chunk (tokens for paragraph_sentence,
    # chars for character_count).
    stride: int = 0
    # Append <|endoftext|> to each chunk (paragraph_sentence only).
    inject_eot: bool = False


class ChunkStats(CamelModel):
    """Summary statistics for a chunking run, for the node's UI + auditability."""

    chunk_count: int
    total_tokens: int
    min_tokens: int
    max_tokens: int
    mean_tokens: float


class ChunkResponse(CamelModel):
    aa: AssocArray
    stats: ChunkStats


# --- AA→JSONL node (AA2JSONLNode) -------------------------------------------
# A terminal processing node: it consumes the ChunkNode AA of passages and
# writes them as a JSONL file formatted for Phi-4 fine-tuning, emitting a
# provenance AA (one row per source chunk) that records what was written.


class Aa2JsonlRequest(CamelModel):
    # The upstream AA (ChunkNode passages, or any AA with a text column).
    aa: AssocArray
    # Destination path for the JSONL file.
    output_file: str
    # One of the registered formats: "instruction-completion" | "continuation".
    format: str


class Aa2JsonlStats(CamelModel):
    """Summary of a write run, for the node's UI + auditability."""

    lines_written: int
    skipped: int
    output_file: str
    file_size_bytes: int


class Aa2JsonlResponse(CamelModel):
    aa: AssocArray
    stats: Aa2JsonlStats


# --- Review node (ReviewNode) -----------------------------------------------
# A human-in-the-loop curation node between ChunkNode and AA2JSONLNode. Review
# state is persisted server-side so a session survives interruption and can be
# resumed. Passages are approved / edited / rejected; only approved + edited
# flow downstream, but all decided passages are retained in the output AA.

REVIEW_STATUSES = ("approved", "edited", "rejected")
# Statuses whose passages are forwarded to AA2JSONLNode.
REVIEW_FORWARDED = ("approved", "edited")


class ReviewPassage(CamelModel):
    """One candidate passage plus its (possibly still-pending) review decision.

    Doubles as the persisted record and the wire representation.
    """

    chunk_id: str
    # Original text as it arrived from ChunkNode.
    text: str
    author: str = ""
    work_title: str = ""
    position: int = 0
    token_count: int = 0
    chunk_strategy: str = ""
    # Decision state (None == still pending):
    status: Optional[str] = None  # approved | edited | rejected
    edited_text: Optional[str] = None  # the edited version when status == "edited"
    review_timestamp: Optional[str] = None


class ReviewSession(CamelModel):
    """A full review session — persisted to disk and returned on the wire."""

    review_id: str
    passages: list[ReviewPassage]
    created_at: str


class ReviewCounts(CamelModel):
    total: int
    approved: int
    edited: int
    rejected: int
    pending: int


class ReviewSessionResponse(CamelModel):
    review_id: str
    passages: list[ReviewPassage]
    counts: ReviewCounts
    complete: bool  # True when no passages remain pending


class ReviewStartRequest(CamelModel):
    # The upstream ChunkNode AA (any AA with a text column).
    aa: AssocArray


class ReviewDecisionRequest(CamelModel):
    review_id: str
    chunk_id: str
    status: str  # approved | edited | rejected
    edited_text: Optional[str] = None


class ReviewOutputResponse(CamelModel):
    # The full audit AA: every decided passage, including rejected ones.
    aa: AssocArray
    counts: ReviewCounts


# --- Text Inference nodes (TextModelLoaderNode / TextPromptNode /
#     TextInferenceNode / TextPreviewNode) ------------------------------------
#
# Four-node generative text pipeline: load → prompt → infer → preview.
#
# AA wire contract (internal row/col/val triples → camelCase rows/cols/vals):
#
#   Model-handle AA  (row: model:<slug>)
#     cols: model_id · backend · context_length · loaded_at ·
#           source_type · lora_path · ext:max_new_tokens · ext:embedding_dim
#
#   Prompt / ChatML AA  (row: prompt:<uuid12>)
#     cols: system_prompt · user_prompt · template · timestamp ·
#           ext:stop_sequences · ext:image_prompt
#     The ext:image_prompt slot is the extensibility hook for future
#     Flux/mflux image-generation nodes.
#
#   Result AA  (row: result:<uuid12>)
#     cols: response_text · model_id · input_tokens · output_tokens ·
#           tokens_per_sec · stop_reason · generated_at ·
#           ext:image_prompt · ext:aa_context


class TextLoadRequest(CamelModel):
    # HF repo id (e.g. "microsoft/phi-4-mini-instruct") or an absolute local
    # path to an mlx checkpoint directory.
    model_id: str
    # Optional path to a LoRA adapter directory. Empty = no adapter.
    lora_path: str = ""


class TextLoadStats(CamelModel):
    """Timing and version metadata returned alongside the model-handle AA."""

    model_id: str
    backend: str          # "mlx-lm" | "stub"
    context_length: int
    lora_path: str = ""
    loaded_at: str        # ISO-8601 UTC timestamp


class TextLoadResponse(CamelModel):
    # Model-handle AA (row: model:<slug>, one row, many attribute columns).
    # Emitted as the `modelHandle` port payload on the Flutter canvas.
    handle: AssocArray
    stats: TextLoadStats


class TextGenerationParams(CamelModel):
    """Generation hyper-parameters; all have sensible defaults."""

    max_tokens: int = 512
    temperature: float = 0.7
    top_p: float = 0.95
    repetition_penalty: float = 1.1


class TextInferRequest(CamelModel):
    # The model-handle AA emitted by TextModelLoaderNode (carries model_id).
    model_handle: AssocArray
    # The ChatML prompt AA emitted by TextPromptNode.
    prompt: AssocArray
    # Generation hyper-parameters (all optional; defaults apply).
    params: TextGenerationParams = TextGenerationParams()


class TextInferenceMetrics(CamelModel):
    """Latency and throughput counters returned alongside the result AA."""

    model_id: str
    input_tokens: int
    output_tokens: int
    tokens_per_sec: float
    stop_reason: str       # "eos" | "length" | "stop_sequence"
    generation_time_ms: float


class TextInferResponse(CamelModel):
    # Result AA (row: result:<uuid12>, one row, many attribute columns).
    # Emitted as the `resultOut` port payload on the Flutter canvas.
    result: AssocArray
    metrics: TextInferenceMetrics


class TextHealthResponse(CamelModel):
    """Health snapshot for the text-inference subsystem."""

    backend: str            # "mlx-lm" | "stub"
    mlx_available: bool
    loaded_model_id: Optional[str] = None


# --- D4M expression node (D4MNode) ------------------------------------------
# A functional node: evaluates a user-supplied D4M expression over one or more
# named input AAs and emits the result AA. Variable names A–D map to the
# node's four input ports; the expression is evaluated by Python eval() in a
# namespace containing those Assoc objects.


class D4mRequest(CamelModel):
    # Named input AAs: variable-name → AssocArray. Keys are the slot names
    # (A, B, C, D) for only those inputs that are currently connected and
    # have received data.
    inputs: dict[str, AssocArray]
    # The D4M expression string, e.g. "A + B" or 'A("chunk: ", "score: ")'.
    expression: str


class D4mResponse(CamelModel):
    # The result AA emitted on the node's single output port.
    aa: AssocArray


# --- D4M handle-based script execution (new multi-line pipeline) -------------

class D4mIngestRequest(CamelModel):
    # The AA payload to ingest.
    aa: AssocArray


class D4mIngestResponse(CamelModel):
    # Opaque UUID that identifies the stored AA.
    handle_id: str
    # Number of triples stored.
    nnz: int


class D4mExecRequest(CamelModel):
    # Map of Julia variable name → handle id (from prior /d4m/ingest calls).
    inputs: dict[str, str]
    # Multi-line Julia D4M script.
    script: str
    # The Julia variable name whose value is returned as the output AA.
    output_symbol: str = "Out"


class D4mExecResponse(CamelModel):
    # Handle id of the output AA (stored server-side).
    handle_id: str
    # Number of unique rows in the result.
    num_rows: int
    # Number of unique columns in the result.
    num_cols: int
    # Number of non-zero triples.
    nnz: int


class D4mPreviewRequest(CamelModel):
    handle_id: str
    page: int = 0
    page_size: int = 200


class D4mPreviewResponse(CamelModel):
    handle_id: str
    page: int
    page_size: int
    total_nnz: int
    aa: AssocArray


class ModelBuildRequest(CamelModel):
    vocab_size: int = 50257
    n_layers: int = 12
    d_model: int = 768
    n_heads: int = 12
    d_ff: int = 3072
    dropout: float = 0.1
    max_seq_len: int = 1024
    use_gradient_checkpointing: bool = False


class ModelBuildResponse(CamelModel):
    handle_id: str
    param_count: int
    param_count_m: float
    estimated_vram_fp16_mb: float
    estimated_vram_fp32_mb: float
    architecture: dict


class TokenizeRequest(CamelModel):
    aa: AssocArray
    encoding: str = "gpt2"
    text_col: str = "text"


class TokenizeResponse(CamelModel):
    aa: AssocArray
    encoding: str
    vocab_size: int
    total_tokens: int
    chunk_count: int


class SplitRequest(CamelModel):
    aa: AssocArray
    ratio: float = 0.8
    strategy: str = "random"  # "sequential" | "random"
    seed: int = 42


class SplitResponse(CamelModel):
    train_aa: AssocArray
    val_aa: AssocArray
    train_count: int
    val_count: int
    total_count: int


# --- Load File node (LoadFileNode) -------------------------------------------
# A source node: loads files (.parquet, .arrow, .json, .csv, .txt) from disk
# and auto-detects Associative Arrays based on schema metadata or column patterns.


class LoadFileRequest(CamelModel):
    # Absolute path to the file to load.
    file_path: str
    # Schema handling mode: "auto" (default), "force_aa", or "raw_table".
    schema_mode: str = "auto"


class LoadFileResponse(CamelModel):
    # Feeds the node's `aa` output port: the AA for this file — reconstructed from
    # a tabular file, or the single-cell text AA for a source/prose file.
    parsed_payload: Optional[AssocArray] = None
    # Feeds the node's `contents` output port: the raw file string, when the file
    # has one. Named for the port so the two contracts line up.
    contents: Optional[str] = None
    # The raw data representation (dict/table). Retained for callers that predate
    # `contents`; for a text file it is `{"text": <contents>}`.
    data: dict = {}
    # Detected payload type: "associative_array", "table", "text", "unknown".
    payload_type: str = "unknown"
    # Status message for UI display.
    message: str = ""


# --- Save File node (SaveFileNode) -------------------------------------------
# A sink node: persists incoming data (AA, text, or image bytes) to the backend
# storage directory in Parquet (for AA) or native format (text/image).


class SaveFileRequest(CamelModel):
    # Data payload: AA for tabular data, text string, or base64-encoded image.
    data_to_save: Optional[AssocArray] = None
    text: Optional[str] = None
    # Image bytes as base64-encoded string.
    image_base64: Optional[str] = None
    # Output filename (without extension). Defaults to "export".
    filename: str = "export"
    # Output format: "parquet" (AA only), "csv", "json", "txt", "png", "jpg".
    # Ignored if auto-detected from incoming data. Default: "parquet".
    format: str = "parquet"


class SaveFileResponse(CamelModel):
    # Absolute path of the saved file on the backend.
    file_path: str
    # Byte size of the written file.
    bytes_written: int
    # Status message for UI display.
    message: str


# --- Polyglot Exec node (PolyglotExecNode) -----------------------------------
# A functional node: it runs the source code carried on an incoming AA under a
# local interpreter and emits stdout/stderr/exit-code/timing as an AA.


class PolyglotExecRequest(CamelModel):
    # The upstream payload, e.g. a Load File `contents` AA. Either this or `code`
    # must be present; explicit fields below win over anything read out of it.
    execution_payload: Optional[AssocArray] = None
    # Source to execute, when the caller has it in hand rather than on an AA.
    code: Optional[str] = None
    # Language override. "" or "auto" means infer (payload → extension → shebang).
    language: str = ""
    # Origin of the code. Sets the child's working directory when it resolves to
    # a real directory, so relative paths inside the snippet behave.
    file_path: Optional[str] = None
    # Command-line arguments for the snippet.
    args: list[str] = []
    # Wall-clock budget in seconds.
    timeout_s: float = 30.0
    # Where a script's stdout lands in the merged output AA:
    # "column" (default) -> `stdoutColumn`, "replace" -> the column the code came
    # from, "none" -> only the `stdout` metadata column.
    stdout_mode: str = "column"
    # Column for "column" mode.
    stdout_column: str = "transformed_text"


class PolyglotExecResponse(CamelModel):
    # The 1x8 result AA — the payload a downstream node consumes.
    execution_result: AssocArray
    # The same result as flat fields, for a caller that wants them directly.
    status: str
    language: str
    stdout: str
    stderr: str
    exit_code: int
    execution_time_ms: float
    code: str
    file_path: str


# --- AST Extract node (AstExtractNode) ---------------------------------------
# A source-indexing node: it runs julia/extract_ast.jl over a Julia source tree
# and returns the 7-column definition index as Arrow IPC bytes (never JSON).


class AstExtractAaResponse(CamelModel):
    # The 7-column index in wire (sparse triple) form — the canvas transport.
    ast_index: AssocArray
    # Definitions found.
    definition_count: int
    # `.jl` files walked.
    files_scanned: int
    # Files the walk skipped, one message each; never fatal.
    errors: list[str] = []
    # The root as the extractor resolved it.
    root: str = ""


class AstExtractRequest(CamelModel):
    # Directory to index recursively, or a single `.jl` file. Hidden directories
    # and `deps` are skipped when walking a tree.
    root_path: str
    # Keep the Arrow artifact at this path instead of a temporary file.
    out_path: Optional[str] = None
    # Optional multi-file payload from Load File
    parsed_payload: Optional[AssocArray] = None
    codebase_path: Optional[AssocArray] = None
    aa: Optional[AssocArray] = None
    # Wall-clock budget for the Julia run. Cold Julia plus Arrow.jl is a couple of
    # seconds before parsing begins, so this is generous by default.
    timeout_s: float = 180.0


# --- LLM Better Docstring node (LlmBetterDocNode) -----------------------------
# Enriches an AST index by generating better_docstring for each row via LLM.


class LlmBetterDocRequest(CamelModel):
    # The 7-column AST index from AstExtractNode.
    ast_index: AssocArray
    # HuggingFace model ID or local path. Defaults to Phi-4-mini-instruct.
    model_id: str = "mlx-community/Phi-4-mini-instruct-4bit"
    # Maximum tokens per generated docstring.
    max_tokens: int = 256
    # Sampling temperature.
    temperature: float = 0.7


class LlmBetterDocResponse(CamelModel):
    # The input AA with an enriched better_docstring column.
    enriched_index: AssocArray
    # Count of rows processed.
    rows_processed: int


# --- JSONL Formatter node (JsonlFormatterNode) --------------------------------
# A formatting node: it turns the documented 7-column index into ChatML training
# examples, one JSON object per line, and emits a 2-column AA.


class JsonlFormatRequest(CamelModel):
    # The source AA in wire (sparse triple) form: the documented index for
    # "chatml", passages for "prompt_completion", anything for "passthrough".
    ast_index: AssocArray
    # "chatml" (default) | "prompt_completion" | "passthrough" (alias "row_dict").
    format_mode: str = "chatml"


class JsonlFormatResponse(CamelModel):
    # 2-column result: `json_line` and `symbol_name`, one row per example.
    jsonl_lines: AssocArray
    # The mode that produced it, canonicalised.
    format_mode: str
    # Examples written.
    line_count: int
    # "chatml": rows dropped for having no generated docstring yet.
    skipped_no_doc: int
    # "chatml": rows dropped for having no source code to learn from.
    skipped_no_code: int
    # Other modes: rows dropped for lacking the fields the mode reads.
    skipped_incomplete: int = 0


# --- Workflow CRUD (workflows_router) ----------------------------------------
# Saved workflow definitions under storage/workflows/. `workflowId` is the file
# stem — the same value the Flutter WorkflowStore calls a `slug`.


class WorkflowDeleteResponse(CamelModel):
    # "SUCCESS" on a completed delete; failures are HTTP errors, not statuses.
    status: str
    # Echoed back so a caller batching deletes can match up responses.
    workflow_id: str
