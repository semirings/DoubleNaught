"""
build_llm_documenter.py — Grease Pencil UX mockup for "LLM Documenter"
(renamed from "Remote Service" — see the node rename mapping).

Spec (per user, 2026):
  - Output port "enrichedIndex" -> "documented".
  - "Model ID" text field -> relabeled "Model", changed to a PICK LIST
    (dropdown) rather than free text — shows a chevron indicator and a
    (truncated) currently-selected value, matching the dropdown pattern
    used elsewhere in this app (cf. the original Load File screenshot's
    now-removed Schema Mode dropdown).
  - "Waiting for astIndex — wire a Function Extraction node" text REMOVED
    entirely.
  - Button "Enrich with LLM" -> "Execute" (standard Execute button pattern).
  - Add checkbox "Wait" — placed per the now-standard widget order
    convention (documented in _template.py): Wait above Execute, Execute
    above the status bar, both below all other widgets. Built correctly in
    this order from the start (no fix-up needed, unlike D4M/Function
    Extraction where the order had to be corrected after the fact).
  - Max Tokens / Temperature fields: unchanged, kept as plain text inputs
    (not instructed to become pick lists).
  - "idle" status row: kept (not instructed to remove), via shared
    build_status_row() helper.

RESOLVED (was previously open questions):
  - Model picklist: for now, a SINGLE-ITEM list containing only
    "mlx-community/Phi-4-mini-instruct". Not a design gap — a deliberate
    scope decision pending a real model-source decision (local registry?
    API? user-added?) before more items are added.
  - Open/expanded dropdown state: DELIBERATELY not designed in Blender, for
    either this node or JSONL Formatter's Format Mode. Every node has
    exactly one card representation in these mockups; adding a second
    "open" card layout would break that rule. VSClaude implements the open
    list using the platform's standard dropdown/select widget, not a custom
    widget matching this mockup's exact visual style.

States exposed for VSClaude / implementation reference:
  Card border:      normal | executing | error        (shared convention)
  Input port:        unfilled | connected_idle | transmitting
  Output port:        unfilled | connected_idle | transmitting
  Model picklist:    closed only (single item: mlx-community/Phi-4-mini-instruct)
  Execute button:    disabled | enabled | lit
  Wait checkbox:     unchecked | checked | disabled (locked, mid-execution)
  Status row:        idle | running | success | error
"""

import sys, os
HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
from _template import *

NODE_KEY = "LLMDocumenter"
def N(suffix):
    return f"{NODE_KEY}_{suffix}"

CARD_W, CARD_H = 4.6, 4.0
cx = CARD_W / 2

coll = new_node_collection("LLM_Documenter")

# ---------------- Card + standard border ----------------
card_pts = rounded_rect_points(cx, CARD_H/2, CARD_W, CARD_H, 0.16, 10)
make_filled(N("Card_Fill"), card_pts, N("CardFillMat"), CARD_FILL_COL, tier="fill", coll=coll)
outline_normal_name, outline_executing_name, outline_error_name = build_card_border(coll, N, card_pts)

make_outline(N("Header_Divider"), [(0.18, CARD_H-0.55), (CARD_W-0.18, CARD_H-0.55)],
             N("DividerMat"), OUTLINE_NORMAL_COL, tier="outline", thickness=0.02, strength=0.6, cyclic=False, coll=coll)

# header icon: two curved arrows (enrich/transform glyph), approximated with two arcs
import math as _m
def _arc_pts(cx_, cy_, r_, a0, a1, n=8):
    return [(cx_ + r_*_m.cos(a0+(a1-a0)*i/n), cy_ + r_*_m.sin(a0+(a1-a0)*i/n)) for i in range(n+1)]
make_outline(N("Header_Icon_Arc1"), _arc_pts(0.30, CARD_H-0.38, 0.09, 0.5, 3.6),
             N("IconArc1Mat"), (0.66,0.46,1.0,1), tier="controls", thickness=0.02, strength=2.5, cyclic=False, coll=coll)
make_outline(N("Header_Icon_Arc2"), _arc_pts(0.30, CARD_H-0.38, 0.09, 3.6, 6.7),
             N("IconArc2Mat"), (0.66,0.46,1.0,1), tier="controls", thickness=0.02, strength=2.5, cyclic=False, coll=coll)

make_text(N("Header_Title"), "LLM Documenter", (0.55, CARD_H-0.38), 0.24, N("TitleMat"), TEXT_COL,
          tier="labels", align='LEFT', strength=1.0, coll=coll)

# ---------------- Ports: astIndex (in) / documented (out) ----------------
PORT_Y = CARD_H - 0.85
PORT_R = 0.075

def build_port(prefix, x):
    make_filled(N(f"{prefix}_Unfilled"), circle_points(x, PORT_Y, PORT_R, 20), N(f"{prefix}UnfilledMat"),
                (0.28,0.27,0.32,1), tier="controls", strength=0.5, coll=coll)
    make_outline(N(f"{prefix}_Ring"), circle_points(x, PORT_Y, PORT_R, 20), N(f"{prefix}RingMat"),
                 OUTLINE_NORMAL_COL, tier="controls", thickness=0.012, strength=0.8, coll=coll)
    make_filled(N(f"{prefix}_White"), circle_points(x, PORT_Y, PORT_R, 20), N(f"{prefix}WhiteMat"),
                (0.92,0.92,0.95,1), tier="controls_fx", strength=1.5, coll=coll)
    make_filled(N(f"{prefix}_Yellow"), circle_points(x, PORT_Y, PORT_R*1.15, 20), N(f"{prefix}YellowMat"),
                (1.0,0.85,0.25,1), tier="controls_fx", strength=8.0, coll=coll)

build_port("PortIn", 0)
build_port("PortOut", CARD_W)

make_text(N("PortIn_Label"), "astIndex", (0.22, PORT_Y), 0.19, N("PortInLabelMat"), TEXT_COL,
          tier="labels", align='LEFT', coll=coll)
make_text(N("PortOut_Label"), "documented", (CARD_W-0.22, PORT_Y), 0.19, N("PortOutLabelMat"), TEXT_COL,
          tier="labels", align='RIGHT', coll=coll)

# ---------------- Model pick list (dropdown) ----------------
MODEL_LABEL_Y = CARD_H - 1.15
MODEL_BOX_Y = CARD_H - 1.55
MODEL_BOX_W = CARD_W - 0.4
MODEL_BOX_H = 0.5

make_text(N("Model_Label"), "Model", (0.20, MODEL_LABEL_Y), 0.15, N("ModelLabelMat"), TEXT_DIM_COL,
          tier="labels", align='LEFT', coll=coll)

model_pts = rounded_rect_points(cx, MODEL_BOX_Y, MODEL_BOX_W, MODEL_BOX_H, 0.08, 8)
make_filled(N("Model_Fill"), model_pts, N("ModelFillMat"), CONTENT_NORMAL_COL, tier="fill", coll=coll)
make_outline(N("Model_Outline"), model_pts, N("ModelOutlineMat"), OUTLINE_NORMAL_COL,
             tier="outline", thickness=0.02, strength=0.7, coll=coll)
make_text(N("Model_Value"), "mlx-community/Phi-4-mini-instruct", (0.40, MODEL_BOX_Y), 0.17,
          N("ModelValueMat"), TEXT_COL, tier="labels", align='LEFT', coll=coll)
# dropdown chevron indicator (marks this as a pick list, not free text)
make_text(N("Model_Chevron"), "\u25be", (CARD_W-0.35, MODEL_BOX_Y), 0.18, N("ModelChevronMat"),
          TEXT_DIM_COL, tier="controls", align='LEFT', strength=1.0, coll=coll)

# ---------------- Max Tokens / Temperature (unchanged: plain text fields) ----------------
MT_LABEL_Y = CARD_H - 2.10
MT_BOX_Y = CARD_H - 2.50
FIELD_GAP = 0.20
FIELD_W = (MODEL_BOX_W - FIELD_GAP) / 2
FIELD_H = 0.5
left_cx = 0.20 + FIELD_W/2
right_cx = left_cx + FIELD_W + FIELD_GAP

make_text(N("MaxTokens_Label"), "Max Tokens", (0.20, MT_LABEL_Y), 0.15, N("MaxTokensLabelMat"),
          TEXT_DIM_COL, tier="labels", align='LEFT', coll=coll)
mt_pts = rounded_rect_points(left_cx, MT_BOX_Y, FIELD_W, FIELD_H, 0.08, 8)
make_filled(N("MaxTokens_Fill"), mt_pts, N("MaxTokensFillMat"), CONTENT_NORMAL_COL, tier="fill", coll=coll)
make_outline(N("MaxTokens_Outline"), mt_pts, N("MaxTokensOutlineMat"), OUTLINE_NORMAL_COL,
             tier="outline", thickness=0.02, strength=0.7, coll=coll)
make_text(N("MaxTokens_Value"), "256", (0.20 + 0.15, MT_BOX_Y), 0.18, N("MaxTokensValueMat"),
          TEXT_COL, tier="labels", align='LEFT', coll=coll)

make_text(N("Temperature_Label"), "Temperature", (right_cx - FIELD_W/2, MT_LABEL_Y), 0.15,
          N("TemperatureLabelMat"), TEXT_DIM_COL, tier="labels", align='LEFT', coll=coll)
temp_pts = rounded_rect_points(right_cx, MT_BOX_Y, FIELD_W, FIELD_H, 0.08, 8)
make_filled(N("Temperature_Fill"), temp_pts, N("TemperatureFillMat"), CONTENT_NORMAL_COL, tier="fill", coll=coll)
make_outline(N("Temperature_Outline"), temp_pts, N("TemperatureOutlineMat"), OUTLINE_NORMAL_COL,
             tier="outline", thickness=0.02, strength=0.7, coll=coll)
make_text(N("Temperature_Value"), "0.7", (right_cx - FIELD_W/2 + 0.15, MT_BOX_Y), 0.18,
          N("TemperatureValueMat"), TEXT_COL, tier="labels", align='LEFT', coll=coll)

# ---- Wait / Execute vertical positions — COMPUTED from the Max
# Tokens / Temperature row's actual bottom edge. Never hand-picked. ----
_mt_box_bottom = MT_BOX_Y - FIELD_H/2
CHK_Y = wait_checkbox_y(_mt_box_bottom)
BTN_Y = execute_button_y(CHK_Y)

# ---------------- Wait checkbox (ABOVE Execute — correct from the start) ----------------
CHK_X = 0.32
CHK_SIZE = WAIT_CHK_SIZE
chk_pts = [
    (CHK_X - CHK_SIZE/2, CHK_Y - CHK_SIZE/2),
    (CHK_X + CHK_SIZE/2, CHK_Y - CHK_SIZE/2),
    (CHK_X + CHK_SIZE/2, CHK_Y + CHK_SIZE/2),
    (CHK_X - CHK_SIZE/2, CHK_Y + CHK_SIZE/2),
]

make_filled(N("Checkbox_Unchecked_Fill"), chk_pts, N("ChkUncheckedFillMat"), CONTENT_NORMAL_COL, tier="fill", strength=0.5, coll=coll)
make_outline(N("Checkbox_Unchecked_Outline"), chk_pts, N("ChkUncheckedOutlineMat"), OUTLINE_NORMAL_COL,
             tier="outline", thickness=0.016, strength=1.2, coll=coll)

make_filled(N("Checkbox_Checked_Fill"), chk_pts, N("ChkCheckedFillMat"), CONTENT_LIT_COL, tier="controls_fx", strength=3.0, coll=coll)
make_outline(N("Checkbox_Checked_Outline"), chk_pts, N("ChkCheckedOutlineMat"), (0.78,0.55,1.0,1),
             tier="controls_fx", thickness=0.016, strength=3.0, coll=coll)
make_outline(N("Checkbox_Checkmark"),
             [(CHK_X-0.06, CHK_Y-0.005), (CHK_X-0.015, CHK_Y-0.06), (CHK_X+0.075, CHK_Y+0.07)],
             N("ChkCheckmarkMat"), TEXT_COL, tier="labels", thickness=0.012, strength=1.5, cyclic=False, coll=coll)

make_filled(N("Checkbox_Disabled_Fill"), chk_pts, N("ChkDisabledFillMat"), (0.10,0.10,0.12,1), tier="fill", strength=0.3, coll=coll)
make_outline(N("Checkbox_Disabled_Outline"), chk_pts, N("ChkDisabledOutlineMat"), (0.32,0.32,0.35,1),
             tier="outline", thickness=0.016, strength=0.5, coll=coll)

make_text(N("Checkbox_Label"), "Wait", (CHK_X + CHK_SIZE/2 + 0.14, CHK_Y), 0.18, N("ChkLabelMat"),
          TEXT_COL, tier="labels", align='LEFT', coll=coll)

# ---------------- Execute button (shared, standardized: see _template.py) ----------------
btn_states = build_execute_button(coll, N, cx, BTN_Y, w=3.6)

# ---------------- Status row ----------------
STATUS_Y = status_row_y(BTN_Y)
status_objs = build_status_row(coll, N, 0.32, STATUS_Y)

# ---------------- Finalize ----------------
finalize_node(coll, CARD_W, CARD_H)

# ---------------- Default visible state ----------------
DEFAULT_VISIBLE = {
    N("Card_Fill"), outline_normal_name, N("Header_Divider"),
    N("Header_Icon_Arc1"), N("Header_Icon_Arc2"), N("Header_Title"),
    N("PortIn_Unfilled"), N("PortIn_Ring"), N("PortIn_Label"),
    N("PortOut_Unfilled"), N("PortOut_Ring"), N("PortOut_Label"),
    N("Model_Label"), N("Model_Fill"), N("Model_Outline"), N("Model_Value"), N("Model_Chevron"),
    N("MaxTokens_Label"), N("MaxTokens_Fill"), N("MaxTokens_Outline"), N("MaxTokens_Value"),
    N("Temperature_Label"), N("Temperature_Fill"), N("Temperature_Outline"), N("Temperature_Value"),
    N("Checkbox_Unchecked_Fill"), N("Checkbox_Unchecked_Outline"), N("Checkbox_Label"),
    *btn_states["disabled"],
    status_objs["idle"][0], status_objs["idle"][1],
}

for obj in coll.objects:
    if obj.type == 'CAMERA' or obj.name.endswith("_BG"):
        continue
    should_show = obj.name in DEFAULT_VISIBLE
    obj.hide_viewport = not should_show
    obj.hide_render = not should_show

print(f"Built node: LLM Documenter  (collection: {coll.name}, {len(coll.objects)} objects)")
