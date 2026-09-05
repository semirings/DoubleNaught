"""LLM-based documentation enrichment for AST index.

Takes a 7-column AST index (with raw_code), calls an LLM to generate
better_docstring for each row, and adds it as a new column using D4M.

Split into three pieces so the same prompt template and D4M merge serve
both the local-model path (this module's own LlmBetterDocNode) and the
remote-provider path (dispatched client-side from Dart, via
/llm/build-prompts and /llm/merge-docstrings — see app.py): the prompt
wording and the AA merge must not be duplicated in Dart just because the
LLM call itself has to happen there for the remote case (the vault-
redeemed API key never reaches this backend).
"""

from __future__ import annotations

import logging

from .d4m_ops import eval_expression
from .models import AssocArray
from .text_engine import default_text_engine

_log = logging.getLogger("double_touch.llm_better_doc")


class LlmBetterDocError(Exception):
    """Raised when enrichment fails."""
    pass


def _group_rows(ast_index: AssocArray) -> dict[str, dict[str, str]]:
    """Group *ast_index*'s triples by row key into `{code, docstring, symbol}`."""
    rows_by_key: dict[str, dict[str, str]] = {}
    for i in range(len(ast_index.rows)):
        row_key = ast_index.rows[i]
        col_name = ast_index.cols[i] if i < len(ast_index.cols) else ""
        val = ast_index.vals[i] if i < len(ast_index.vals) else ""

        if row_key not in rows_by_key:
            rows_by_key[row_key] = {"code": "", "docstring": "", "symbol": ""}

        if col_name == "raw_code":
            rows_by_key[row_key]["code"] = str(val)
        elif col_name == "docstring":
            rows_by_key[row_key]["docstring"] = str(val)
        elif col_name == "symbol_name":
            rows_by_key[row_key]["symbol"] = str(val)
    return rows_by_key


def _build_prompt(symbol: str, code: str, existing_doc: str, hint: str = "") -> str:
    """Build a prompt for the LLM to generate documentation.

    *hint* is additive, never a replacement: it comes from an optional
    connected Prompt node and adds a style/instruction nudge (e.g. "explain
    for a junior developer"), but the function's own code always stays in
    the prompt — dropping code context would defeat the point of this node.
    """
    prompt = (
        f"Generate a concise, technical docstring for the following "
        f"Julia function:\n\n"
    )
    if symbol.strip():
        prompt += f"Symbol: {symbol}\n"
    prompt += f"Code:\n{code}\n"
    if existing_doc.strip():
        prompt += f"\nExisting docstring:\n{existing_doc}\n"
    if hint.strip():
        prompt += f"\nAdditional instructions: {hint.strip()}\n"
    prompt += (
        "\nWrite only the docstring content (no markdown, no code blocks). "
        "Be concise and technical."
    )
    return prompt


def build_prompts(
    ast_index: AssocArray, prompt_hint: str = ""
) -> list[dict[str, str]]:
    """One documentation-generation prompt per definition in *ast_index*.

    Rows with no code are skipped (there is nothing to document), matching
    the local path's existing behavior. Returns `[{"rowKey", "symbol",
    "prompt"}, ...]`, in the index's row order.
    """
    rows_by_key = _group_rows(ast_index)

    prompts: list[dict[str, str]] = []
    seen_rows: set[str] = set()
    for row_key in ast_index.rows:
        if row_key in seen_rows:
            continue
        seen_rows.add(row_key)

        row_data = rows_by_key.get(row_key)
        if row_data is None:
            continue
        code = row_data.get("code", "").strip()
        if not code:
            continue

        symbol = row_data.get("symbol", "")
        existing_doc = row_data.get("docstring", "").strip()
        prompts.append({
            "rowKey": row_key,
            "symbol": symbol,
            "prompt": _build_prompt(symbol, code, existing_doc, prompt_hint),
        })
    return prompts


def merge_better_docstrings(
    ast_index: AssocArray, docstrings: dict[str, str]
) -> AssocArray:
    """Add/overwrite `better_docstring` on *ast_index* via D4M.jl.

    Uses D4M.jl's `right_overwrite(A, B)` (`combine(A, B, (a,b) -> b)`), NOT
    the `+`/`plus` operator: `plus()` is matrix *addition* — it calls
    D4M.jl's own `logical()` on any non-numeric-sentinel operand first,
    discarding actual string values and replacing them with a bare 0/1
    presence pattern (confirmed empirically: `A + B` on two string-valued
    Assocs came back as all `1.0`s). `combine`/`right_overwrite` is D4M.jl's
    own documented tool for exactly this ("Unlike plus(), this function:
    Does NOT convert string-valued inputs to logical; actual values are
    preserved... works correctly for string AAs" — Assoc/operations.jl).
    `right_overwrite` also means re-running this on an already-documented
    index correctly replaces the prior docstring rather than colliding.

    Rows with no generated docstring (empty *docstrings* value, or omitted
    from *docstrings* entirely — e.g. a failed remote call) are left out of
    the temporary AA rather than given an explicit empty-string entry: an
    empty string is D4M.jl's internal "absent" sentinel, and a stored
    empty-string triple makes `find()` raise `BoundsError` on the result —
    the same quirk `ast_extract.aa_from_table` works around. Omitting those
    rows means they simply keep no `better_docstring` entry, which is the
    AA-spec-correct outcome anyway (no cell = no docstring yet).

    The temporary AA is plain wire triples; `eval_expression` is what
    constructs the real D4M.jl `Assoc` objects (for both operands) and
    performs the combine in Julia itself — see `d4m_ops.eval_expression`/
    `_to_julia_assoc`.
    """
    new_rows: list[str] = []
    new_vals: list[str] = []
    seen_rows: set[str] = set()
    for row_key in ast_index.rows:
        if row_key in seen_rows:
            continue
        seen_rows.add(row_key)
        doc = docstrings.get(row_key, "")
        if not doc:
            continue
        new_rows.append(row_key)
        new_vals.append(doc)

    better_doc_aa = AssocArray(
        rows=new_rows,
        cols=["better_docstring"] * len(new_vals),
        vals=new_vals,
    )

    try:
        return eval_expression(
            {"A": ast_index, "B": better_doc_aa}, "right_overwrite(A, B)"
        )
    except Exception as e:
        raise LlmBetterDocError(f"Failed to merge better_docstring column: {e}")


class LlmBetterDocNode:
    """Enriches an AST index by generating better_docstring via a local LLM."""

    def __init__(
        self,
        model_id: str = "mlx-community/Phi-4-mini-instruct-4bit",
        max_tokens: int = 256,
        temperature: float = 0.7,
    ):
        """Initialize the enrichment node.

        Args:
            model_id: HuggingFace model ID or local path for the LLM.
            max_tokens: Maximum tokens per generated docstring.
            temperature: Sampling temperature for generation.
        """
        self.model_id = model_id
        self.max_tokens = max_tokens
        self.temperature = temperature
        self.text_engine = default_text_engine()

    def generate_docstrings(
        self, ast_index: AssocArray, prompt_hint: str = ""
    ) -> dict[str, str]:
        """Generate a docstring for every documentable definition in
        *ast_index* — row key -> generated text.

        Touches only the local text engine, never D4M.jl/Julia — safe to run
        in a worker thread, unlike :func:`merge_better_docstrings`. This
        split exists specifically so `/llm/enrich-ast` can thread-pool the
        (potentially slow) generation step while still calling the merge
        step directly on the event-loop thread — see that route for why.

        Raises:
            LlmBetterDocError: *ast_index* is empty.
        """
        if not ast_index.rows:
            raise LlmBetterDocError("Empty AST index")

        _log.info(
            f"Enriching AA: {len(ast_index.rows)} rows, "
            f"{len(ast_index.cols)} cols, {len(ast_index.vals)} vals"
        )

        prompts = build_prompts(ast_index, prompt_hint)

        docstrings: dict[str, str] = {}
        for entry in prompts:
            try:
                docstrings[entry["rowKey"]] = self._generate_docstring(entry["prompt"])
            except Exception as e:
                _log.warning(
                    f"Failed to generate docstring for {entry['symbol']}: {e}; "
                    "using empty string"
                )
                docstrings[entry["rowKey"]] = ""
        return docstrings

    def enrich(self, ast_index: AssocArray, prompt_hint: str = "") -> AssocArray:
        """Generate and merge in one call.

        For direct (non-HTTP) callers only — e.g. tests, or a future
        non-async caller. `/llm/enrich-ast` does NOT use this: it calls
        [generate_docstrings] and [merge_better_docstrings] separately so
        only the Julia-free half can be thread-pooled.

        Raises:
            LlmBetterDocError: If enrichment fails.
        """
        docstrings = self.generate_docstrings(ast_index, prompt_hint)
        enriched = merge_better_docstrings(ast_index, docstrings)
        _log.info(
            f"Merge successful: {len(enriched.rows)} rows, "
            f"{len(enriched.cols)} cols, {len(enriched.vals)} vals"
        )
        return enriched

    def _generate_docstring(self, prompt: str) -> str:
        """Call the LLM to generate a docstring."""
        try:
            result_dict = self.text_engine.generate(
                self.model_id,
                [{"role": "user", "content": prompt}],
                max_tokens=self.max_tokens,
                temperature=self.temperature,
                top_p=0.95,
                repetition_penalty=1.1,
            )
            # Extract the response text from the result AA.
            if result_dict.get("val") and len(result_dict["val"]) > 0:
                return str(result_dict["val"][0])
            return ""
        except Exception as e:
            raise LlmBetterDocError(f"LLM generation failed: {e}")
