"""Tests for LLM Documenter's prompt-building and D4M docstring merge.

`build_prompts` is pure Python (no D4M.jl involved) and runs everywhere.
`merge_better_docstrings` and `LlmBetterDocNode.enrich` go through D4M.jl and
are skip-guarded, same as the rest of this suite.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from conftest import d4m_jl_required
from double_touch.app import app
from double_touch.llm_better_doc import (
    LlmBetterDocError,
    LlmBetterDocNode,
    build_prompts,
    merge_better_docstrings,
)
from double_touch.models import AssocArray

client = TestClient(app)

_SCHEMA = [
    "symbol_name",
    "kind",
    "file_path",
    "line_range",
    "docstring",
    "raw_code",
    "better_docstring",
]


def _index(rows: list[dict[str, str]]) -> AssocArray:
    """A 7-column AST index from partial row dicts, keyed `def0`, `def1`, …

    Omits unset columns entirely rather than storing an explicit empty-string
    cell, matching `ast_extract.py::aa_from_table`'s convention. D4M.jl treats
    an empty string as its "absent" sentinel — storing one crashes `find()`
    (and anything built on it, like `combine`/`right_overwrite`) with a
    `BoundsError`, even on a well-formed operand.
    """
    triples_rows: list[str] = []
    triples_cols: list[str] = []
    triples_vals: list[str] = []
    for i, row in enumerate(rows):
        key = f"def{i}"
        for col in _SCHEMA:
            val = row.get(col, "")
            if not val:
                continue
            triples_rows.append(key)
            triples_cols.append(col)
            triples_vals.append(val)
    return AssocArray(rows=triples_rows, cols=triples_cols, vals=triples_vals)


# --- build_prompts -----------------------------------------------------------


def test_build_prompts_one_per_row_with_code():
    aa = _index([
        {"symbol_name": "f", "raw_code": "f(x) = x"},
        {"symbol_name": "g", "raw_code": "g(x) = x * 2"},
    ])
    prompts = build_prompts(aa)

    assert [p["rowKey"] for p in prompts] == ["def0", "def1"]
    assert [p["symbol"] for p in prompts] == ["f", "g"]
    assert "f(x) = x" in prompts[0]["prompt"]
    assert "g(x) = x * 2" in prompts[1]["prompt"]


def test_build_prompts_skips_rows_with_no_code():
    aa = _index([
        {"symbol_name": "f", "raw_code": "f(x) = x"},
        {"symbol_name": "empty", "raw_code": ""},
    ])
    prompts = build_prompts(aa)

    assert [p["rowKey"] for p in prompts] == ["def0"]


def test_build_prompts_includes_an_existing_docstring_when_present():
    aa = _index([
        {"symbol_name": "f", "raw_code": "f(x) = x", "docstring": "Old doc."},
    ])
    prompt = build_prompts(aa)[0]["prompt"]
    assert "Old doc." in prompt
    assert "Existing docstring" in prompt


def test_build_prompts_hint_is_additive_not_a_replacement():
    aa = _index([{"symbol_name": "f", "raw_code": "f(x) = x"}])

    without_hint = build_prompts(aa)[0]["prompt"]
    with_hint = build_prompts(aa, prompt_hint="Explain for a junior developer.")[0]["prompt"]

    # The hint adds instruction text...
    assert "Explain for a junior developer." in with_hint
    assert "Explain for a junior developer." not in without_hint
    # ...but the code is present in both — the hint never drops code context.
    assert "f(x) = x" in without_hint
    assert "f(x) = x" in with_hint


def test_build_prompts_blank_hint_behaves_like_no_hint():
    aa = _index([{"symbol_name": "f", "raw_code": "f(x) = x"}])
    assert build_prompts(aa) == build_prompts(aa, prompt_hint="   ")


# --- merge_better_docstrings ---------------------------------------------


@d4m_jl_required
def test_merge_adds_the_better_docstring_column_via_d4m():
    aa = _index([
        {"symbol_name": "f", "raw_code": "f(x) = x"},
        {"symbol_name": "g", "raw_code": "g(x) = x * 2"},
    ])

    merged = merge_better_docstrings(aa, {"def0": "Doc for f.", "def1": "Doc for g."})

    assert set(merged.cols) >= {"symbol_name", "raw_code", "better_docstring"}
    by_row = {}
    for r, c, v in zip(merged.rows, merged.cols, merged.vals):
        if c == "better_docstring":
            by_row[r] = v
    assert by_row == {"def0": "Doc for f.", "def1": "Doc for g."}


@d4m_jl_required
def test_merge_leaves_a_missing_row_without_a_better_docstring_cell():
    aa = _index([
        {"symbol_name": "f", "raw_code": "f(x) = x"},
        {"symbol_name": "g", "raw_code": "g(x) = x * 2"},
    ])

    # Only def0's docstring was generated (e.g. def1's remote call failed).
    # def1 gets no better_docstring cell at all — not an explicit empty
    # string, which would violate the AA no-empty-cell convention and is
    # exactly what D4M.jl's find()/combine() crash on.
    merged = merge_better_docstrings(aa, {"def0": "Doc for f."})

    by_row = {
        r: v for r, c, v in zip(merged.rows, merged.cols, merged.vals)
        if c == "better_docstring"
    }
    assert by_row == {"def0": "Doc for f."}


@d4m_jl_required
def test_merge_preserves_the_original_columns():
    aa = _index([{"symbol_name": "f", "kind": "function", "raw_code": "f(x) = x"}])
    merged = merge_better_docstrings(aa, {"def0": "Doc."})

    cells = {
        (r, c): v for r, c, v in zip(merged.rows, merged.cols, merged.vals)
    }
    assert cells[("def0", "symbol_name")] == "f"
    assert cells[("def0", "kind")] == "function"


# --- LlmBetterDocNode.enrich: still works, now via the shared helpers -----


@d4m_jl_required
def test_enrich_still_produces_the_merged_index(monkeypatch):
    monkeypatch.setattr(
        LlmBetterDocNode,
        "_generate_docstring",
        lambda self, prompt: "Generated doc.",
    )
    aa = _index([{"symbol_name": "f", "raw_code": "f(x) = x"}])

    enriched = LlmBetterDocNode().enrich(aa)

    cells = {
        (r, c): v for r, c, v in zip(enriched.rows, enriched.cols, enriched.vals)
    }
    assert cells[("def0", "better_docstring")] == "Generated doc."


def test_enrich_rejects_an_empty_index():
    with pytest.raises(LlmBetterDocError, match="Empty AST index"):
        LlmBetterDocNode().enrich(AssocArray(rows=[], cols=[], vals=[]))


@d4m_jl_required
def test_enrich_passes_the_hint_through_to_the_prompt(monkeypatch):
    seen_prompts = []

    def fake_generate(self, prompt):
        seen_prompts.append(prompt)
        return "doc"

    monkeypatch.setattr(LlmBetterDocNode, "_generate_docstring", fake_generate)
    aa = _index([{"symbol_name": "f", "raw_code": "f(x) = x"}])

    LlmBetterDocNode().enrich(aa, prompt_hint="Focus on edge cases.")

    assert "Focus on edge cases." in seen_prompts[0]


# --- /llm/build-prompts route -----------------------------------------------


def test_build_prompts_route_returns_one_entry_per_documentable_row():
    response = client.post(
        "/llm/build-prompts",
        json={
            "astIndex": {
                "rows": ["def0", "def0"],
                "cols": ["symbol_name", "raw_code"],
                "vals": ["f", "f(x) = x"],
            },
        },
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert len(body["prompts"]) == 1
    assert body["prompts"][0]["rowKey"] == "def0"
    assert body["prompts"][0]["symbol"] == "f"
    assert "f(x) = x" in body["prompts"][0]["prompt"]


def test_build_prompts_route_applies_the_hint():
    response = client.post(
        "/llm/build-prompts",
        json={
            "astIndex": {
                "rows": ["def0", "def0"],
                "cols": ["symbol_name", "raw_code"],
                "vals": ["f", "f(x) = x"],
            },
            "promptHint": "Explain like I'm five.",
        },
    )
    assert response.status_code == 200, response.text
    assert "Explain like I'm five." in response.json()["prompts"][0]["prompt"]


# --- /llm/merge-docstrings route ---------------------------------------------


@d4m_jl_required
def test_merge_docstrings_route_returns_the_enriched_index():
    response = client.post(
        "/llm/merge-docstrings",
        json={
            "astIndex": {
                "rows": ["def0", "def0"],
                "cols": ["symbol_name", "raw_code"],
                "vals": ["f", "f(x) = x"],
            },
            "docstrings": {"def0": "Docs for f."},
        },
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["rowsProcessed"] == 1
    aa = body["enrichedIndex"]
    cells = dict(zip(aa["cols"], aa["vals"]))
    assert cells["better_docstring"] == "Docs for f."
