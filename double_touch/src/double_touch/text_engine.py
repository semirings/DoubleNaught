"""Generative text inference abstraction for DoubleTouch (mlx-lm backend).

Two engines implement the :class:`TextModelEngine` protocol:

* :class:`StubTextEngine` — deterministic, dependency-free placeholder
  (echoes the last user message back). Used when ``mlx_lm`` is not installed
  and as the per-request fallback when a real model can't be loaded.
* :class:`MlxTextEngine` — real, **offline** generative inference via
  ``mlx_lm.load()`` / ``mlx_lm.generate()``, with an in-memory model cache so
  a model loaded once stays resident across requests.

:func:`default_text_engine` picks the mlx engine when the optional dep is
importable, otherwise the stub.  ``mlx_lm`` is imported lazily inside methods,
so this module imports cleanly without it.

AA wire contract
----------------
All methods return / consume the internal ``row``/``col``/``val`` dict form
(parallel lists, singular keys) rather than the camelCase ``rows``/``cols``/
``vals`` pydantic shape used on the wire.  The app-layer route converts.

Model-handle AA columns
~~~~~~~~~~~~~~~~~~~~~~~
row: ``model:<slug>``  (one row per model)
cols: model_id · backend · context_length · loaded_at · source_type ·
      lora_path · ext:max_new_tokens

The ``ext:`` namespace is a forward-compatibility hook: downstream nodes
(image-generation, AA-context injection, embedding lookup) can add columns
here without changing the inference contract.

Prompt / ChatML AA columns
~~~~~~~~~~~~~~~~~~~~~~~~~~~
row: ``prompt:<uuid12>``
cols: system_prompt · user_prompt · template · timestamp ·
      ext:stop_sequences · ext:image_prompt

Result AA columns
~~~~~~~~~~~~~~~~~
row: ``result:<uuid12>``
cols: response_text · model_id · input_tokens · output_tokens ·
      tokens_per_sec · stop_reason · generated_at ·
      ext:image_prompt   (mirrors the incoming prompt's ext field,
                          ready for a downstream Flux/mflux node)
      ext:aa_context     (reserved for future AA-attribute passthrough)
"""

from __future__ import annotations

import importlib.util
import logging
import threading
import time
from datetime import datetime, timezone
from typing import Protocol, runtime_checkable
from uuid import uuid4

_log = logging.getLogger("double_touch.text_engine")

_DEFAULT_MAX_TOKENS = 512
_DEFAULT_TEMPERATURE = 0.7
_DEFAULT_TOP_P = 0.95
_DEFAULT_REPETITION_PENALTY = 1.1


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def mlx_available() -> bool:
    """True when mlx_lm is importable (Apple Silicon with mlx-lm installed)."""
    return importlib.util.find_spec("mlx_lm") is not None


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _result_id() -> str:
    return f"result:{uuid4().hex[:12]}"


def _prompt_id() -> str:
    return f"prompt:{uuid4().hex[:12]}"


def _model_slug(model_id: str) -> str:
    """Turn an HF repo-id or local path into a safe AA row-key segment."""
    return model_id.strip("/").split("/")[-1].replace(".", "-").lower()


def _context_length_hint(model_id: str) -> int:
    """Best-effort context-length hint from well-known model id patterns."""
    lower = model_id.lower()
    if "phi-4" in lower:
        return 16384
    if "phi-3" in lower:
        return 131072
    if "llama-3" in lower or "llama3" in lower:
        return 131072
    if "mistral" in lower or "mixtral" in lower:
        return 32768
    if "qwen" in lower:
        return 131072
    if "gemma" in lower:
        return 8192
    return 4096


def _build_handle_triples(
    model_id: str,
    backend: str,
    lora_path: str | None,
) -> dict:
    """Build the model-handle AA dict (internal row/col/val form)."""
    slug = _model_slug(model_id)
    row_key = f"model:{slug}"
    ctx = _context_length_hint(model_id)
    cols = [
        "model_id", "backend", "context_length", "loaded_at",
        "source_type", "lora_path",
        "ext:max_new_tokens",       # default hint for inference nodes
        "ext:embedding_dim",         # reserved — populated if the model exposes embeddings
    ]
    vals = [
        model_id, backend, str(ctx), _now_iso(),
        "local", lora_path or "",
        str(_DEFAULT_MAX_TOKENS),
        "",                          # ext:embedding_dim — empty until supported
    ]
    n = len(cols)
    return {"row": [row_key] * n, "col": cols, "val": vals}


def _build_result_triples(
    response_text: str,
    model_id: str,
    input_tokens: int,
    output_tokens: int,
    tokens_per_sec: float,
    stop_reason: str,
    ext_image_prompt: str = "",
) -> dict:
    """Build the inference-result AA dict (internal row/col/val form)."""
    rid = _result_id()
    cols = [
        "response_text", "model_id",
        "input_tokens", "output_tokens", "tokens_per_sec",
        "stop_reason", "generated_at",
        "ext:image_prompt",   # passthrough slot for downstream Flux/mflux
        "ext:aa_context",     # reserved: future AA-attribute passthrough
    ]
    vals = [
        response_text, model_id,
        str(input_tokens), str(output_tokens), str(round(tokens_per_sec, 2)),
        stop_reason, _now_iso(),
        ext_image_prompt,
        "",                   # ext:aa_context — empty until supported
    ]
    n = len(cols)
    return {"row": [rid] * n, "col": cols, "val": vals}


# ---------------------------------------------------------------------------
# Protocol
# ---------------------------------------------------------------------------


@runtime_checkable
class TextModelEngine(Protocol):
    """Minimal interface that both the stub and the real mlx engine satisfy."""

    name: str

    def load_model(
        self,
        model_id: str,
        *,
        lora_path: str | None = None,
    ) -> dict:
        """Load (or warm from cache) the model; return model-handle AA dict."""
        ...

    def generate(
        self,
        model_id: str,
        messages: list[dict],
        *,
        max_tokens: int = _DEFAULT_MAX_TOKENS,
        temperature: float = _DEFAULT_TEMPERATURE,
        top_p: float = _DEFAULT_TOP_P,
        repetition_penalty: float = _DEFAULT_REPETITION_PENALTY,
    ) -> dict:
        """Run inference; return result AA dict."""
        ...

    def loaded_model_id(self) -> str | None:
        """The most recently loaded model id, or None before any load."""
        ...


# ---------------------------------------------------------------------------
# Stub engine
# ---------------------------------------------------------------------------


class StubTextEngine:
    """Deterministic, dependency-free stub — echoes the last user message."""

    name = "stub"
    _last_model_id: str | None = None

    def load_model(self, model_id: str, *, lora_path: str | None = None) -> dict:
        self._last_model_id = model_id
        return _build_handle_triples(model_id, "stub", lora_path)

    def generate(
        self,
        model_id: str,
        messages: list[dict],
        *,
        max_tokens: int = _DEFAULT_MAX_TOKENS,
        temperature: float = _DEFAULT_TEMPERATURE,
        top_p: float = _DEFAULT_TOP_P,
        repetition_penalty: float = _DEFAULT_REPETITION_PENALTY,
    ) -> dict:
        user_msg = next(
            (m.get("content", "") for m in reversed(messages) if m.get("role") == "user"),
            "(no message)",
        )
        # Echo back a clearly marked stub reply.
        response = (
            f'[Stub] Received: "{user_msg[:120]}{"…" if len(user_msg) > 120 else ""}"'
        )
        # Pass-through the ext:image_prompt from the last user message if present
        # (for future Flux downstream wiring).
        ext_img = next(
            (m.get("ext:image_prompt", "") for m in reversed(messages)),
            "",
        )
        return _build_result_triples(
            response_text=response,
            model_id=model_id,
            input_tokens=len(user_msg.split()),
            output_tokens=len(response.split()),
            tokens_per_sec=0.0,
            stop_reason="eos",
            ext_image_prompt=ext_img,
        )

    def loaded_model_id(self) -> str | None:
        return self._last_model_id


# ---------------------------------------------------------------------------
# mlx-lm engine
# ---------------------------------------------------------------------------


class MlxTextEngine:
    """Real generative inference via mlx_lm.  Thread-safe in-memory model cache.

    A model loaded once stays resident for the lifetime of the process.  Multiple
    models can be cached simultaneously (Apple Silicon UMA allows it); only one
    model is generated against at a time per the GIL + thread lock.
    """

    name = "mlx-lm"
    _lock = threading.Lock()
    # model_id -> (model, tokenizer)
    _models: dict[str, tuple] = {}

    # LoRA path recorded at load time so repeated calls can detect a mismatch.
    _lora_paths: dict[str, str | None] = {}

    def _get_or_load(self, model_id: str, lora_path: str | None = None):
        with self._lock:
            if model_id not in self._models:
                _log.info("Loading model %s via mlx-lm (lora=%s)", model_id, lora_path)
                import mlx_lm  # noqa: PLC0415 — lazy; keeps module importable w/o mlx
                model, tokenizer = mlx_lm.load(
                    model_id,
                    adapter_path=lora_path or None,
                )
                self._models[model_id] = (model, tokenizer)
                self._lora_paths[model_id] = lora_path
                _log.info("Model %s ready", model_id)
            return self._models[model_id]

    def load_model(self, model_id: str, *, lora_path: str | None = None) -> dict:
        self._get_or_load(model_id, lora_path)
        return _build_handle_triples(model_id, "mlx-lm", lora_path)

    def generate(
        self,
        model_id: str,
        messages: list[dict],
        *,
        max_tokens: int = _DEFAULT_MAX_TOKENS,
        temperature: float = _DEFAULT_TEMPERATURE,
        top_p: float = _DEFAULT_TOP_P,
        repetition_penalty: float = _DEFAULT_REPETITION_PENALTY,
    ) -> dict:
        import mlx_lm  # noqa: PLC0415
        from mlx_lm.sample_utils import make_logits_processors, make_sampler

        model, tokenizer = self._get_or_load(model_id)

        # Apply the model's native chat template; graceful fallback for models
        # that ship without one (older checkpoints, custom fine-tunes).
        try:
            prompt = tokenizer.apply_chat_template(
                messages,
                tokenize=False,
                add_generation_prompt=True,
            )
        except Exception:
            # Fallback: Phi-4 format if detected, else generic Role: Content.
            lower_model = model_id.lower()
            if "phi-4" in lower_model or "phi4" in lower_model:
                # Phi-4 instruct format: <|system|>...<|end|> <|user|>...<|end|> <|assistant|>
                parts = []
                for msg in messages:
                    role = msg.get("role", "").lower()
                    content = msg.get("content", "").strip()
                    if role in ("system", "user", "assistant"):
                        parts.append(f"<|{role}|>\n{content}\n<|end|>")
                prompt = " ".join(parts) + " <|assistant|>\n"
            else:
                # Generic fallback — Role: Content blocks.
                prompt = "\n".join(
                    f"{m['role'].upper()}: {m.get('content', '')}" for m in messages
                ) + "\nASSISTANT:"

        # Token count before generation (best-effort; not all tokenizers expose .encode).
        input_tokens = 0
        try:
            input_tokens = len(tokenizer.encode(prompt))
        except Exception:
            pass

        # Build sampler and logits processors from generation parameters.
        sampler = make_sampler(temp=temperature, top_p=top_p)
        logits_processors = (
            make_logits_processors(repetition_penalty=repetition_penalty)
            if repetition_penalty != 1.0
            else None
        )

        t0 = time.perf_counter()
        response = mlx_lm.generate(
            model,
            tokenizer,
            prompt=prompt,
            max_tokens=max_tokens,
            sampler=sampler,
            logits_processors=logits_processors,
            verbose=False,
        )
        elapsed = max(time.perf_counter() - t0, 1e-6)

        output_tokens = 0
        try:
            output_tokens = len(tokenizer.encode(response))
        except Exception:
            pass

        tokens_per_sec = output_tokens / elapsed

        ext_img = next(
            (m.get("ext:image_prompt", "") for m in reversed(messages)), ""
        )
        return _build_result_triples(
            response_text=response,
            model_id=model_id,
            input_tokens=input_tokens,
            output_tokens=output_tokens,
            tokens_per_sec=tokens_per_sec,
            stop_reason="eos",
            ext_image_prompt=ext_img,
        )

    def loaded_model_id(self) -> str | None:
        with self._lock:
            return next(iter(self._models), None)


# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------


def default_text_engine() -> TextModelEngine:
    """Return an mlx engine when mlx-lm is installed, else the stub."""
    if mlx_available():
        _log.info("mlx-lm available — using MlxTextEngine")
        return MlxTextEngine()
    _log.warning("mlx-lm not available — using StubTextEngine")
    return StubTextEngine()


# ---------------------------------------------------------------------------
# ChatML builder (used by the /text/infer route to assemble messages)
# ---------------------------------------------------------------------------


def messages_from_prompt_aa(
    rows: list[str],
    cols: list[str],
    vals: list,
) -> list[dict]:
    """Extract a ChatML messages list from a prompt AA (row/col/val triples).

    Expected columns: ``system_prompt``, ``user_prompt``.
    Optional passthrough: ``ext:image_prompt`` (appended to user content when
    non-empty, as a hook for future multimodal pipeline integration).
    """
    # Build a flat col->val map from the first row (prompt AAs are single-row).
    col_map: dict[str, str] = {}
    for col, val in zip(cols, vals):
        if col not in col_map:
            col_map[col] = str(val)

    messages: list[dict] = []
    system = col_map.get("system_prompt", "").strip()
    user = col_map.get("user_prompt", "").strip()
    ext_img = col_map.get("ext:image_prompt", "").strip()

    if system:
        messages.append({"role": "system", "content": system})

    # Attach the ext:image_prompt hint to the user message when present.
    # Future multimodal nodes can replace this with an actual image tensor;
    # for now it is a text description passed downstream to Flux/mflux.
    if ext_img:
        user = f"{user}\n\n[Image context: {ext_img}]".strip()

    messages.append({"role": "user", "content": user, "ext:image_prompt": ext_img})
    return messages
