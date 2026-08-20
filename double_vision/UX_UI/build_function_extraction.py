"""
build_function_extraction.py — Grease Pencil UX mockup for "Function Extraction"
(renamed from "AST Extract" — see the node rename mapping).

Spec (per user, 2026 — final state, supersedes several earlier drafts):
  - Remove the "File or Directory" text box entirely.
  - Button "Extract Definitions" -> "Execute" (standard shared component).
  - Add checkbox "Wait" (standard shared mechanism, capitalized "Wait" —
    the earlier lowercase/uppercase inconsistency across nodes was
    resolved project-wide; Preview's checkbox was also corrected to match).
  - Input port `codebasePath` -> `codebase`; output port `astIndex` ->
    `functions` (later rename, applied after the initial button/checkbox
    changes above).
  - Hint text "Wire a Load File node, or type a path" REMOVED entirely
    (a later instruction superseded the earlier "kept as-is, flag if it
    needs updating" note — it doesn't need updating, it's gone).
  - Wait/Execute vertical order: Wait sits ABOVE Execute, Execute sits
    directly above the status row — this is the standard project-wide
    widget order (documented in _template.py), and on this node it was
    corrected after an initial draft had them reversed.
  - "idle" status row (dot + text): kept, via the shared build_status_row()
    helper (idle/running/success/error), matching every other node.

States exposed for VSClaude / implementation reference:
  Card border:     normal | executing | error        (shared convention)
  Input port:       unfilled | connected_idle | transmitting
  Output port:       unfilled | connected_idle | transmitting
  Execute button:   disabled | enabled | lit | executing (Cancel — see GLOBAL_UX_CONTRACT.md §2)
  Wait checkbox:    unchecked | checked | disabled (locked, mid-execution)
  Status row:       idle | running | success | error
"""

import sys, os
HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
from _template import *

NODE_KEY = "FunctionExtraction"
def N(suffix):
    return f"{NODE_KEY}_{suffix}"

CARD_W, CARD_H = 4.4, 2.7
cx = CARD_W / 2

coll = new_node_collection("Function_Extraction")

# ---------------- Card + standard border ----------------
card_pts = rounded_rect_points(cx, CARD_H/2, CARD_W, CARD_H, 0.16, 10)
make_filled(N("Card_Fill"), card_pts, N("CardFillMat"), CARD_FILL_COL, tier="fill", coll=coll)
outline_normal_name, outline_executing_name, outline_error_name = build_card_border(coll, N, card_pts)

make_outline(N("Header_Divider"), [(0.18, CARD_H-0.55), (CARD_W-0.18, CARD_H-0.55)],
             N("DividerMat"), OUTLINE_NORMAL_COL, tier="outline", thickness=0.02, strength=0.6, cyclic=False, coll=coll)

# header icon: two connected nodes glyph (small squares + connector line)
make_filled(N("Header_Icon_A"), rounded_rect_points(0.22, CARD_H-0.34, 0.08, 0.08, 0.015, 4),
            N("IconAMat"), (0.66,0.46,1.0,1), tier="controls", strength=2.5, coll=coll)
make_filled(N("Header_Icon_B"), rounded_rect_points(0.38, CARD_H-0.42, 0.08, 0.08, 0.015, 4),
            N("IconBMat"), (0.66,0.46,1.0,1), tier="controls", strength=2.5, coll=coll)
make_outline(N("Header_Icon_Link"), [(0.26, CARD_H-0.34), (0.34, CARD_H-0.42)],
             N("IconLinkMat"), (0.66,0.46,1.0,1), tier="controls", thickness=0.012, strength=2.0, cyclic=False, coll=coll)

make_text(N("Header_Title"), "Function Extraction", (0.55, CARD_H-0.38), 0.24, N("TitleMat"), TEXT_COL,
          tier="labels", align='LEFT', strength=1.0, coll=coll)

# ---------------- Ports: codebasePath (in) / astIndex (out) ----------------
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

make_text(N("PortIn_Label"), "codebase", (0.22, PORT_Y), 0.19, N("PortInLabelMat"), TEXT_COL,
          tier="labels", align='LEFT', coll=coll)
make_text(N("PortOut_Label"), "functions", (CARD_W-0.22, PORT_Y), 0.19, N("PortOutLabelMat"), TEXT_COL,
          tier="labels", align='RIGHT', coll=coll)

# ---- Wait / Execute vertical positions — COMPUTED from the port row (a bare
# text row, so we use TEXT_ROW_HALF rather than a box height). Never
# hand-picked. See _template.py for the rule. ----
_port_row_bottom = PORT_Y - TEXT_ROW_HALF
CHK_Y = wait_checkbox_y(_port_row_bottom)
BTN_Y = execute_button_y(CHK_Y)

# ---------------- Execute button (shared, standardized: see _template.py) ----------------
btn_states = build_execute_button(coll, N, cx, BTN_Y, w=3.6)

# ---------------- Wait checkbox (same pattern as Preview / D4M) ----------------
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

# ---------------- Status row (idle / running / success / error) ----------------
STATUS_Y = status_row_y(BTN_Y)
status_objs = build_status_row(coll, N, 0.32, STATUS_Y)

# ---------------- Finalize ----------------
finalize_node(coll, CARD_W, CARD_H)

# ---------------- Default visible state ----------------
# Idle, no connections, Execute disabled, Wait unchecked, status = idle.
DEFAULT_VISIBLE = {
    N("Card_Fill"), outline_normal_name, N("Header_Divider"),
    N("Header_Icon_A"), N("Header_Icon_B"), N("Header_Icon_Link"), N("Header_Title"),
    N("PortIn_Unfilled"), N("PortIn_Ring"), N("PortIn_Label"),
    N("PortOut_Unfilled"), N("PortOut_Ring"), N("PortOut_Label"),
    *btn_states["disabled"],
    N("Checkbox_Unchecked_Fill"), N("Checkbox_Unchecked_Outline"), N("Checkbox_Label"),
    status_objs["idle"][0], status_objs["idle"][1],
}

for obj in coll.objects:
    if obj.type == 'CAMERA' or obj.name.endswith("_BG"):
        continue
    should_show = obj.name in DEFAULT_VISIBLE
    obj.hide_viewport = not should_show
    obj.hide_render = not should_show

print(f"Built node: Function Extraction  (collection: {coll.name}, {len(coll.objects)} objects)")
