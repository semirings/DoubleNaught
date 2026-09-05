"""Route + unit tests for the D4MNode backend (``/d4m/eval`` endpoint).

Run with: ``pip install -e '.[dev]' && pytest`` from ``backend/``.

Coverage:
  * ``_preprocess`` — MATLAB-style syntax translations to Julia
  * ``eval_expression`` — Julia D4M arithmetic, selection, and error cases
  * ``/d4m/eval`` — HTTP contract, wire format, and 422 error propagation

Expression language: Julia D4M.jl syntax.
  A + B               union/sum
  A & B               intersection
  A[sw"prefix", :]    StartsWith selector
  A["lo".."hi", :]    Between selector
  A[has"substr", :]   Contains selector
  A[ew"suffix", :]    EndsWith selector
"""

import pytest
from fastapi.testclient import TestClient

from double_touch.app import app
from double_touch.d4m_ops import _preprocess, eval_expression
from double_touch.models import AssocArray

client = TestClient(app)


# ── Fixture helpers ───────────────────────────────────────────────────────────

def _aa(rows, cols, vals) -> AssocArray:
    return AssocArray(rows=rows, cols=cols, vals=vals)


def _aa_dict(rows, cols, vals) -> dict:
    return {"rows": rows, "cols": cols, "vals": vals}


# Numeric Assoc A: r1→c1=1.0, r2→c2=2.0
_A = _aa(["r1", "r2"], ["c1", "c2"], [1.0, 2.0])
_A_dict = _aa_dict(["r1", "r2"], ["c1", "c2"], [1.0, 2.0])

# B shares r2/c2 with A; disjoint otherwise
_B = _aa(["r2", "r3"], ["c2", "c3"], [10.0, 3.0])
_B_dict = _aa_dict(["r2", "r3"], ["c2", "c3"], [10.0, 3.0])

# String-valued Assoc for selection tests
_S = _aa(
    ["chunk:001", "chunk:002", "doc:001"],
    ["score",     "score",     "label"],
    ["0.9",       "0.7",       "review"],
)
_S_dict = _aa_dict(
    ["chunk:001", "chunk:002", "doc:001"],
    ["score",     "score",     "label"],
    ["0.9",       "0.7",       "review"],
)


# ── _preprocess unit tests ────────────────────────────────────────────────────

class TestPreprocess:
    def test_matlab_all_elements(self):
        assert _preprocess("A(:)", {"A"}) == "A"

    def test_call_to_subscript(self):
        result = _preprocess('A("r1,", "c1,")', {"A"})
        assert result == 'A["r1,", "c1,"]'

    def test_colon_string_becomes_julia_colon(self):
        result = _preprocess('A("r1,", ":")', {"A"})
        assert result == 'A["r1,", :]'

    def test_only_rewrites_known_names(self):
        # 'startswith' is not a known input name — must not be rewritten
        expr = "startswith('prefix:')"
        assert _preprocess(expr, {"A"}) == expr

    def test_noop_on_plain_expression(self):
        assert _preprocess("A + B", {"A", "B"}) == "A + B"

    def test_multiple_inputs(self):
        result = _preprocess("A(:) + B(:)", {"A", "B"})
        assert result == "A + B"


# ── eval_expression unit tests ────────────────────────────────────────────────

class TestEvalExpression:
    def test_plus_disjoint(self):
        result = eval_expression({"A": _A, "B": _B}, "A + B")
        assert set(result.rows) == {"r1", "r2", "r3"}

    def test_plus_overlap_sums(self):
        result = eval_expression({"A": _A, "B": _B}, "A + B")
        # r2/c2: A=2.0 + B=10.0 = 12.0
        r2_idx = [i for i, r in enumerate(result.rows) if r == "r2"][0]
        assert result.vals[r2_idx] == pytest.approx(12.0)

    def test_and_intersection(self):
        result = eval_expression({"A": _A, "B": _B}, "A & B")
        assert set(result.rows) == {"r2"}
        assert set(result.cols) == {"c2"}

    def test_identity(self):
        result = eval_expression({"A": _A}, "A")
        assert set(result.rows) == {"r1", "r2"}

    def test_matlab_all_elements_preprocessed(self):
        result = eval_expression({"A": _A}, "A(:)")
        assert set(result.rows) == {"r1", "r2"}

    def test_call_to_subscript_preprocessed(self):
        # ":" string arg is converted to Julia Colon by _preprocess
        result = eval_expression({"S": _S}, 'S("chunk:001,", ":")')
        assert set(result.rows) == {"chunk:001"}

    def test_startswith_selector(self):
        result = eval_expression({"S": _S}, 'S[sw"chunk", :]')
        assert set(result.rows) == {"chunk:001", "chunk:002"}
        assert "doc:001" not in result.rows

    def test_between_selector(self):
        K = _aa(["apple","banana","cherry","date"],
                ["c1","c2","c3","c4"], [1.0,2.0,3.0,4.0])
        result = eval_expression({"K": K}, 'K["banana".."cherry", :]')
        assert set(result.rows) == {"banana", "cherry"}

    def test_contains_selector(self):
        result = eval_expression({"S": _S}, 'S[has"chunk", :]')
        assert set(result.rows) == {"chunk:001", "chunk:002"}

    def test_endswith_selector(self):
        E = _aa(["score_final","score_interim","label"],
                ["c1","c2","c3"], [1.0,2.0,3.0])
        result = eval_expression({"E": E}, 'E[ew"_interim", :]')
        assert set(result.rows) == {"score_interim"}

    def test_result_not_assoc_raises_type_error(self):
        with pytest.raises(TypeError, match="Assoc"):
            eval_expression({"A": _A}, "42")

    def test_syntax_error_propagates(self):
        with pytest.raises(Exception):
            eval_expression({"A": _A}, "A +")

    def test_undefined_name_raises(self):
        with pytest.raises(Exception):
            eval_expression({"A": _A}, "A + C")


# ── /d4m/eval HTTP tests ──────────────────────────────────────────────────────

class TestD4mEvalRoute:
    def test_plus_returns_200(self):
        res = client.post("/d4m/eval", json={
            "inputs": {"A": _A_dict, "B": _B_dict},
            "expression": "A + B",
        })
        assert res.status_code == 200
        body = res.json()
        assert "aa" in body
        assert set(body["aa"]["rows"]) == {"r1", "r2", "r3"}

    def test_and_returns_intersection(self):
        res = client.post("/d4m/eval", json={
            "inputs": {"A": _A_dict, "B": _B_dict},
            "expression": "A & B",
        })
        assert res.status_code == 200
        aa = res.json()["aa"]
        assert aa["rows"] == ["r2"]
        assert aa["cols"] == ["c2"]

    def test_wire_format_is_parallel_lists(self):
        res = client.post("/d4m/eval", json={
            "inputs": {"A": _A_dict},
            "expression": "A",
        })
        assert res.status_code == 200
        aa = res.json()["aa"]
        assert "rows" in aa and "cols" in aa and "vals" in aa
        assert len(aa["rows"]) == len(aa["cols"]) == len(aa["vals"])

    def test_string_valued_assoc_roundtrips(self):
        res = client.post("/d4m/eval", json={
            "inputs": {"S": _S_dict},
            "expression": "S",
        })
        assert res.status_code == 200
        aa = res.json()["aa"]
        assert "chunk:001" in aa["rows"]
        assert "score" in aa["cols"]

    def test_non_assoc_result_returns_422(self):
        res = client.post("/d4m/eval", json={
            "inputs": {"A": _A_dict},
            "expression": "42",
        })
        assert res.status_code == 422

    def test_bad_expression_returns_422(self):
        res = client.post("/d4m/eval", json={
            "inputs": {"A": _A_dict},
            "expression": "A +",
        })
        assert res.status_code == 422

    def test_missing_inputs_field_returns_422(self):
        res = client.post("/d4m/eval", json={"expression": "A"})
        assert res.status_code == 422

    def test_missing_expression_field_returns_422(self):
        res = client.post("/d4m/eval", json={"inputs": {"A": _A_dict}})
        assert res.status_code == 422

    def test_matlab_call_syntax_preprocessed_via_route(self):
        res = client.post("/d4m/eval", json={
            "inputs": {"A": _A_dict},
            "expression": "A(:)",
        })
        assert res.status_code == 200
        assert set(res.json()["aa"]["rows"]) == {"r1", "r2"}

    def test_startswith_selection_via_route(self):
        res = client.post("/d4m/eval", json={
            "inputs": {"S": _S_dict},
            "expression": 'S[sw"chunk", :]',
        })
        assert res.status_code == 200
        aa = res.json()["aa"]
        assert all(r.startswith("chunk:") for r in aa["rows"])
        assert "doc:001" not in aa["rows"]

    def test_between_selection_via_route(self):
        res = client.post("/d4m/eval", json={
            "inputs": {"S": _S_dict},
            "expression": 'S["chunk:001".."chunk:002", :]',
        })
        assert res.status_code == 200
        aa = res.json()["aa"]
        assert set(aa["rows"]) == {"chunk:001", "chunk:002"}
