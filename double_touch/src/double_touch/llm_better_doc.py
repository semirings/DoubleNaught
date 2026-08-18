"""LLM-based documentation enrichment for AST index.

Takes a 7-column AST index (with raw_code), calls an LLM to generate
better_docstring for each row, and adds it as a new column using D4M.
"""

from __future__ import annotations

import logging
from typing import Optional

from .d4m_ops import eval_expression
from .models import AssocArray
from .text_engine import default_text_engine

_log = logging.getLogger("double_touch.llm_better_doc")


class LlmBetterDocError(Exception):
    """Raised when enrichment fails."""
    pass


class LlmBetterDocNode:
    """Enriches an AST index by generating better_docstring via LLM."""

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

    def enrich(self, ast_index: AssocArray) -> AssocArray:
        """Enrich an AST index with LLM-generated better_docstring.

        Args:
            ast_index: 7-column AST index from AstExtractNode.
                Expected columns: symbol_name, kind, file_path, line_range,
                docstring, raw_code, better_docstring.

        Returns:
            The input AA with an updated better_docstring column.

        Raises:
            LlmBetterDocError: If enrichment fails.
        """
        if not ast_index.rows:
            raise LlmBetterDocError("Empty AST index")

        _log.info(
            f"Enriching AA: {len(ast_index.rows)} rows, "
            f"{len(ast_index.cols)} cols, {len(ast_index.vals)} vals"
        )

        # Sparse AA format: parallel lists of (row_key, col_name, value) triples.
        # Group by row key to extract the data we need.
        rows_by_key = {}

        # Process each triple (rows[i], cols[i], vals[i])
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

        # Generate better_docstring for each unique row key.
        # Must include ALL rows to maintain alignment with input AA for + operation.
        new_rows = []
        new_vals = []

        seen_rows = set()
        for row_key in ast_index.rows:
            if row_key in seen_rows:
                continue
            seen_rows.add(row_key)

            new_rows.append(row_key)

            # If row doesn't have code data, emit empty string
            if row_key not in rows_by_key:
                new_vals.append("")
                continue

            row_data = rows_by_key[row_key]
            code = row_data.get("code", "").strip()
            existing_doc = row_data.get("docstring", "").strip()
            symbol = row_data.get("symbol", "")

            # If no code to document, emit empty string
            if not code:
                new_vals.append("")
                continue

            # Build a prompt for the LLM.
            prompt = self._build_prompt(symbol, code, existing_doc)

            try:
                # Call the LLM to generate a better docstring.
                better_doc = self._generate_docstring(prompt)
            except Exception as e:
                _log.warning(
                    f"Failed to generate docstring for {symbol}: {e}; "
                    "using empty string"
                )
                better_doc = ""

            new_vals.append(better_doc)

        # Create a single-column AA with the better_docstring values.
        # Sparse format requires parallel lists of (row, col, val) triples,
        # so cols must have the same length as vals.
        better_doc_aa = AssocArray(
            rows=new_rows,
            cols=["better_docstring"] * len(new_vals),
            vals=new_vals,
        )

        _log.info(
            f"Created better_doc_aa: {len(new_rows)} rows, "
            f"1 col (better_docstring), {len(new_vals)} vals"
        )

        # Use D4M's + operator to add the column to the original AA.
        try:
            _log.info("Merging AAs using D4M + operator")
            enriched = eval_expression(
                {"A": ast_index, "B": better_doc_aa},
                "A + B",
            )
            _log.info(
                f"Merge successful: {len(enriched.rows)} rows, "
                f"{len(enriched.cols)} cols, {len(enriched.vals)} vals"
            )
        except Exception as e:
            _log.error(f"Merge failed: {e}")
            raise LlmBetterDocError(
                f"Failed to merge better_docstring column: {e}"
            )

        return enriched

    def _build_prompt(
        self, symbol: str, code: str, existing_doc: str
    ) -> str:
        """Build a prompt for the LLM to generate documentation."""
        prompt = (
            f"Generate a concise, technical docstring for the following "
            f"Julia function:\n\n"
            f"Symbol: {symbol}\n"
            f"Code:\n{code}\n"
        )
        if existing_doc.strip():
            prompt += f"\nExisting docstring:\n{existing_doc}\n"
        prompt += (
            "\nWrite only the docstring content (no markdown, no code blocks). "
            "Be concise and technical."
        )
        return prompt

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
