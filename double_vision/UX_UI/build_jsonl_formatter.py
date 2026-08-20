"""
build_jsonl_formatter.py — Grease Pencil UX mockup for "JSONL Formatter".

Spec (per user, 2026):
  - Output port "jsonlLines" -> "jsonl".
  - Add checkbox "Wait" (standard pattern: above Execute, below other
    widgets, per the widget-order convention in _template.py).
  - Button "Format" -> "Execute" (standard Execute button pattern).
  - Remove "Waiting for astIndex — wire a documented AST index" text
    entirely.
  - Pick list ("Format Mode" — a standard dropdown field, same kind of
    element as LLM Documenter's Model field, but independently populated
    with its own option set; not a shared component between the two)
    item renames — FINAL, resolved after a round of back-and-forth on the
    first item's exact label:
        ChatML (Code/Doc)   -> ChatML Doc   (final — NOT "Conversational
                                              Chat"; an earlier draft of
                                              this spec considered that
                                              rename and even a
                                              "Conversational Chat
                                              (Code/Doc)" hybrid; neither
                                              is correct, use "ChatML Doc")
        Prompt / Completion -> Instruction / Task
        Row Passthrough     -> Passthrough
    "Passthrough" MODE BEHAVIOR (confirmed): passes the input data into a
    JSON object WITHOUT modification — no reshaping, no AA-structure
    changes, purely a wrapping/serialization step. This distinguishes it
    from the other two modes, which do restructure the data into a
    specific chat/instruction format.
    RESOLVED: the open/expanded dropdown state (showing all three options
    at once) is DELIBERATELY not designed in Blender — same rule as LLM
    Documenter's Model field: every node has exactly one card
    representation, no separate "open" card layout. VSClaude implements the
    open list using the platform's standard dropdown/select widget.
  - "No index" text: REMOVED (later instruction superseded the earlier
    "keep as-is" note). Format Mode field moved up to close the resulting gap.
  - Execute button: now built via the shared build_execute_button() helper
    (text + right-side arrowhead) — see the "All Nodes" Execute-button
    standardization note in _template.py.

States exposed for VSClaude / implementation reference:
  Card border:       normal | executing | error       (shared convention)
  Input port:          unfilled | connected_idle | transmitting
  Output port:          unfilled | connected_idle | transmitting
  Format Mode picklist: closed only (options: Conversational Chat,
                        Instruction / Task, Passthrough)
  Execute button:      disabled | enabled | lit | executing (Cancel — see GLOBAL_UX_CONTRACT.md §2)
  Wait checkbox:       unchecked | checked | disabled (locked, mid-execution)
  Status row:          idle | running | success | error
"""

import sys, os
HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
from _template import *

NODE_KEY = "JSONLFormatter"
def N(suffix):
    return f"{NODE_KEY}_{suffix}"

CARD_W, CARD_H = 4.4, 3.6
cx = CARD_W / 2

coll = new_node_collection("JSONL_Formatter")

# ---------------- Card + standard border ----------------
card_pts = rounded_rect_points(cx, CARD_H/2, CARD_W, CARD_H, 0.16, 10)
make_filled(N("Card_Fill"), card_pts, N("CardFillMat"), CARD_FILL_COL, tier="fill", coll=coll)
outline_normal_name, outline_executing_name, outline_error_name = build_card_border(coll, N, card_pts)

make_outline(N("Header_Divider"), [(0.18, CARD_H-0.55), (CARD_W-0.18, CARD_H-0.55)],
             N("DividerMat"), OUTLINE_NORMAL_COL, tier="outline", thickness=0.02, strength=0.6, cyclic=False, coll=coll)

# header icon: "{}" glyph
make_text(N("Header_Icon"), "{}", (0.22, CARD_H-0.38), 0.26, N("IconMat"),
          (0.66,0.46,1.0,1), tier="controls", align='LEFT', strength=2.5, coll=coll)

make_text(N("Header_Title"), "JSONL Formatter", (0.55, CARD_H-0.38), 0.24, N("TitleMat"), TEXT_COL,
          tier="labels", align='LEFT', strength=1.0, coll=coll)

# ---------------- Ports: astIndex (in) / jsonl (out) ----------------
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
make_text(N("PortOut_Label"), "jsonl", (CARD_W-0.22, PORT_Y), 0.19, N("PortOutLabelMat"), TEXT_COL,
          tier="labels", align='RIGHT', coll=coll)

# ---------------- Format Mode pick list (reusing LLM Documenter's dropdown pattern) ----------------
# "No index" text removed — tightened up to sit directly below the ports
# (same label-below-port gap used on Load File's URL field: 0.30) rather
# than leaving a dead gap where the removed text used to be.
FM_LABEL_Y = CARD_H - 1.15
FM_BOX_Y = CARD_H - 1.55
FM_BOX_W = CARD_W - 0.4
FM_BOX_H = 0.5

make_text(N("FormatMode_Label"), "Format Mode", (0.20, FM_LABEL_Y), 0.15, N("FormatModeLabelMat"),
          TEXT_DIM_COL, tier="labels", align='LEFT', coll=coll)

fm_pts = rounded_rect_points(cx, FM_BOX_Y, FM_BOX_W, FM_BOX_H, 0.08, 8)
make_filled(N("FormatMode_Fill"), fm_pts, N("FormatModeFillMat"), CONTENT_NORMAL_COL, tier="fill", coll=coll)
make_outline(N("FormatMode_Outline"), fm_pts, N("FormatModeOutlineMat"), OUTLINE_NORMAL_COL,
             tier="outline", thickness=0.02, strength=0.7, coll=coll)
make_text(N("FormatMode_Value"), "ChatML Doc", (0.40, FM_BOX_Y), 0.19,
          N("FormatModeValueMat"), TEXT_COL, tier="labels", align='LEFT', coll=coll)
make_text(N("FormatMode_Chevron"), "\u25be", (CARD_W-0.35, FM_BOX_Y), 0.18, N("FormatModeChevronMat"),
          TEXT_DIM_COL, tier="controls", align='LEFT', strength=1.0, coll=coll)

# ---- Wait / Execute vertical positions — COMPUTED from the Format Mode
# box's actual bottom edge. Never hand-picked. See _template.py. ----
_formatmode_box_bottom = FM_BOX_Y - FM_BOX_H/2
CHK_Y = wait_checkbox_y(_formatmode_box_bottom)
BTN_Y = execute_button_y(CHK_Y)

# ---------------- Wait checkbox (above Execute, per standard order) ----------------
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
    N("Header_Icon"), N("Header_Title"),
    N("PortIn_Unfilled"), N("PortIn_Ring"), N("PortIn_Label"),
    N("PortOut_Unfilled"), N("PortOut_Ring"), N("PortOut_Label"),
    N("FormatMode_Label"), N("FormatMode_Fill"), N("FormatMode_Outline"),
    N("FormatMode_Value"), N("FormatMode_Chevron"),
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

print(f"Built node: JSONL Formatter  (collection: {coll.name}, {len(coll.objects)} objects)")
