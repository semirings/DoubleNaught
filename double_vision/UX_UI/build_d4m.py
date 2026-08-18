"""
build_d4m.py — Grease Pencil UX mockup for the "D4M" node.

Spec (per user, 2026):
  - Remove "Preview" button entirely.
  - Add checkbox "Wait" (same convention as Preview node's checkbox:
    unchecked = fire on receipt, checked = fire on command, disabled/locked
    during execution).
  - The standalone "A" that sat below the first input port becomes a "+"
    meaning "add another port". Added ports are auto-named the next letter
    (A -> B -> C -> ...). Exactly ONE "+" for adding input ports (confirmed
    correct — do not add more).
  - CORRECTED: the bottom "<- + / + ->" nav arrows are NOT port controls —
    they add sibling D4M nodes to the left/right of this one (chaining
    multiple D4M script nodes side by side), a completely separate concept
    from port management. Restored at the bottom of the card.
  - Output port renamed from "evaluatedResult" -> "Out".
  - "Execute" button centered (previously paired side-by-side with Preview).
  - "idle" status indicator removed entirely — no status row on this node.
  - Script box is a real code editor surface:
      - Shows scrollbar chrome (track + thumb) since content can overflow.
      - Double-click opens the FULL editor in the app's right-hand display
        panel (outside this node card — not drawn here, since it's a
        different UI surface). Small expand-glyph hint drawn in the box's
        corner to signal this.
      - The inline box and the full editor are BIDIRECTIONAL — editing
        either updates the other. This is a data-binding/behavior spec for
        implementation, not something extra to draw in the mockup itself.

States exposed for VSClaude / implementation reference:
  Card border:    normal | executing | error         (shared convention)
  Input port A:   unfilled | connected_idle | transmitting
  Output port:    unfilled | connected_idle | transmitting
  Add-port (+):   default | hover                    (hover not yet modeled)
  Execute button: disabled | enabled | lit
  Wait checkbox:  unchecked | checked | disabled (locked, mid-execution)
"""

import sys, os
HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
from _template import *

NODE_KEY = "D4M"
def N(suffix):
    return f"{NODE_KEY}_{suffix}"

CARD_W, CARD_H = 4.6, 4.3
cx = CARD_W / 2

coll = new_node_collection("D4M")

# ---------------- Card + standard border ----------------
card_pts = rounded_rect_points(cx, CARD_H/2, CARD_W, CARD_H, 0.16, 10)
make_filled(N("Card_Fill"), card_pts, N("CardFillMat"), CARD_FILL_COL, tier="fill", coll=coll)
outline_normal_name, outline_executing_name, outline_error_name = build_card_border(coll, N, card_pts)

make_outline(N("Header_Divider"), [(0.18, CARD_H-0.55), (CARD_W-0.18, CARD_H-0.55)],
             N("DividerMat"), OUTLINE_NORMAL_COL, tier="outline", thickness=0.02, strength=0.6, cyclic=False, coll=coll)

# header icon: Sigma glyph (summation symbol) — matches reference image
make_text(N("Header_Icon"), "\u03a3", (0.24, CARD_H-0.38), 0.30, N("IconMat"),
          (0.66,0.46,1.0,1), tier="controls", align='LEFT', strength=2.5, coll=coll)

make_text(N("Header_Title"), "D4M", (0.55, CARD_H-0.38), 0.24, N("TitleMat"), TEXT_COL,
          tier="labels", align='LEFT', strength=1.0, coll=coll)

# ---------------- Ports: input A (left) + output Out (right) ----------------
PORT_Y = CARD_H - 0.85
PORT_R = 0.075

def build_port(prefix, x, align):
    make_filled(N(f"{prefix}_Unfilled"), circle_points(x, PORT_Y, PORT_R, 20), N(f"{prefix}UnfilledMat"),
                (0.28,0.27,0.32,1), tier="controls", strength=0.5, coll=coll)
    make_outline(N(f"{prefix}_Ring"), circle_points(x, PORT_Y, PORT_R, 20), N(f"{prefix}RingMat"),
                 OUTLINE_NORMAL_COL, tier="controls", thickness=0.012, strength=0.8, coll=coll)
    make_filled(N(f"{prefix}_White"), circle_points(x, PORT_Y, PORT_R, 20), N(f"{prefix}WhiteMat"),
                (0.92,0.92,0.95,1), tier="controls_fx", strength=1.5, coll=coll)
    make_filled(N(f"{prefix}_Yellow"), circle_points(x, PORT_Y, PORT_R*1.15, 20), N(f"{prefix}YellowMat"),
                (1.0,0.85,0.25,1), tier="controls_fx", strength=8.0, coll=coll)

build_port("PortA", 0, 'LEFT')
build_port("PortOut", CARD_W, 'RIGHT')

make_text(N("PortA_Label"), "A", (0.22, PORT_Y), 0.19, N("PortALabelMat"), TEXT_COL,
          tier="labels", align='LEFT', coll=coll)
make_text(N("PortOut_Label"), "Out", (CARD_W-0.22, PORT_Y), 0.19, N("PortOutLabelMat"), TEXT_COL,
          tier="labels", align='RIGHT', coll=coll)

# ---------------- Add-port "+" (replaces the old standalone "A") ----------------
ADDPORT_Y = CARD_H - 1.15
make_text(N("AddPort_Plus"), "+", (0.22, ADDPORT_Y), 0.22, N("AddPortPlusMat"),
          (0.78,0.55,1.0,1), tier="controls", align='LEFT', strength=2.0, coll=coll)
make_text(N("AddPort_Hint"), "add port", (0.50, ADDPORT_Y), 0.13, N("AddPortHintMat"),
          TEXT_DIM_COL, tier="labels", align='LEFT', coll=coll)

# ---------------- Script text area ----------------
SCRIPT_TOP = CARD_H - 1.30
SCRIPT_H = 1.05
SCRIPT_CY = SCRIPT_TOP - SCRIPT_H/2
SCRIPT_W = CARD_W - 0.4
script_pts = rounded_rect_points(cx, SCRIPT_CY, SCRIPT_W, SCRIPT_H, 0.06, 8)
make_filled(N("Script_Fill"), script_pts, N("ScriptFillMat"), CONTENT_NORMAL_COL, tier="fill", coll=coll)
make_outline(N("Script_Outline"), script_pts, N("ScriptOutlineMat"), OUTLINE_NORMAL_COL,
             tier="outline", thickness=0.018, strength=0.7, coll=coll)
make_text(N("Script_Placeholder"), "Julia D4M Script", (0.40, SCRIPT_TOP - 0.22), 0.19,
          N("ScriptPlaceholderMat"), TEXT_DIM_COL, tier="labels", align='LEFT', coll=coll)

# scrollbar chrome (vertical): track along the right inner edge, thumb near top
script_right = cx + SCRIPT_W/2
sb_x = script_right - 0.09
sb_track_pts = rounded_rect_points(sb_x, SCRIPT_CY, 0.05, SCRIPT_H - 0.10, 0.02, 4)
make_filled(N("Script_ScrollTrack"), sb_track_pts, N("ScriptScrollTrackMat"), (0.12,0.12,0.14,1),
            tier="controls", strength=0.4, coll=coll)
sb_thumb_h = (SCRIPT_H - 0.10) * 0.38
sb_thumb_cy = SCRIPT_CY + (SCRIPT_H - 0.10)/2 - sb_thumb_h/2 - 0.04
sb_thumb_pts = rounded_rect_points(sb_x, sb_thumb_cy, 0.05, sb_thumb_h, 0.02, 4)
make_filled(N("Script_ScrollThumb"), sb_thumb_pts, N("ScriptScrollThumbMat"), (0.40,0.39,0.46,1),
            tier="controls", strength=0.9, coll=coll)

# expand-to-editor hint icon (top-right corner of the box) + caption
make_text(N("Script_ExpandIcon"), "⤢", (script_right - 0.26, SCRIPT_TOP - 0.16), 0.16,
          N("ScriptExpandIconMat"), TEXT_DIM_COL, tier="controls", align='LEFT', strength=1.0, coll=coll)
make_text(N("Script_ExpandHint"), "double-click to expand → full editor", (0.40, SCRIPT_TOP - SCRIPT_H + 0.16), 0.105,
          N("ScriptExpandHintMat"), TEXT_DIM_COL, tier="labels", align='LEFT', strength=0.6, coll=coll)

# ---------------- Out: name field ----------------
OUTFIELD_Y = CARD_H - 2.65
OUTFIELD_LABEL_X = 0.20
OUTFIELD_LABEL_SIZE = 0.16
make_text(N("OutField_Label"), "Out:", (OUTFIELD_LABEL_X, OUTFIELD_Y), OUTFIELD_LABEL_SIZE,
          N("OutFieldLabelMat"), TEXT_COL, tier="labels", align='LEFT', coll=coll)

# Box starts AFTER the label with an explicit gap (previously hardcoded
# positions overlapped: the box began underneath the "Out:" text). Right
# edge matches the same right-margin convention used elsewhere (CARD_W - 0.2).
OUTFIELD_BOX_LEFT = OUTFIELD_LABEL_X + 0.55  # gap sized for "Out:" at this font size
OUTFIELD_BOX_RIGHT = CARD_W - 0.20
OUTFIELD_BOX_W = OUTFIELD_BOX_RIGHT - OUTFIELD_BOX_LEFT
outfield_box_cx = OUTFIELD_BOX_LEFT + OUTFIELD_BOX_W / 2

outfield_pts = rounded_rect_points(outfield_box_cx, OUTFIELD_Y, OUTFIELD_BOX_W, 0.34, 0.06, 8)
make_filled(N("OutField_Fill"), outfield_pts, N("OutFieldFillMat"), CONTENT_NORMAL_COL, tier="fill", coll=coll)
make_outline(N("OutField_Outline"), outfield_pts, N("OutFieldOutlineMat"), OUTLINE_NORMAL_COL,
             tier="outline", thickness=0.015, strength=0.6, coll=coll)
make_text(N("OutField_Value"), "Out", (OUTFIELD_BOX_LEFT + 0.15, OUTFIELD_Y), 0.15, N("OutFieldValueMat"),
          TEXT_COL, tier="labels", align='LEFT', coll=coll)

# ---------------- Execute button (centered, no longer paired with Preview) ----------------
BTN_W, BTN_H = 3.6, 0.42
BTN_Y = CARD_H - 3.15
btn_pts = rounded_rect_points(cx, BTN_Y, BTN_W, BTN_H, 0.18, 8)

make_filled(N("Button_Disabled"), btn_pts, N("ButtonDisabledMat"), BUTTON_DISABLED_COL, tier="fill", strength=0.4, coll=coll)
make_filled(N("Button_Enabled"), btn_pts, N("ButtonEnabledMat"), BUTTON_NORMAL_COL, tier="fill", strength=0.6, coll=coll)
make_filled(N("Button_Lit"), btn_pts, N("ButtonLitMat"), BUTTON_LIT_COL, tier="fill", strength=4.0, coll=coll)

# small play-triangle glyph + label, two brightness variants matching disabled/active
tri_pts_dim = [(cx-0.62, BTN_Y-0.08), (cx-0.62, BTN_Y+0.08), (cx-0.50, BTN_Y)]
make_filled(N("Button_Play_Disabled"), tri_pts_dim, N("ButtonPlayDisabledMat"), TEXT_DIM_COL, tier="labels", strength=0.5, coll=coll)
make_filled(N("Button_Play_Active"), tri_pts_dim, N("ButtonPlayActiveMat"), TEXT_COL, tier="labels", strength=1.2, coll=coll)

make_text(N("Button_Label_Disabled"), "Execute", (cx+0.10, BTN_Y), 0.18, N("ButtonLabelDisabledMat"),
          TEXT_DIM_COL, tier="labels", align='CENTER', strength=0.5, coll=coll)
make_text(N("Button_Label_Active"), "Execute", (cx+0.10, BTN_Y), 0.18, N("ButtonLabelActiveMat"),
          TEXT_COL, tier="labels", align='CENTER', strength=1.2, coll=coll)

# ---------------- Wait checkbox (same pattern as Preview node) ----------------
CHK_Y = CARD_H - 3.55
CHK_X = 0.32
CHK_SIZE = 0.22
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

# ---------------- Chain nav: add sibling D4M node left/right ----------------
# NOT port controls — these insert another D4M node before/after this one in
# the graph. Outer glyph = direction of insertion, inner glyph = "add".
NAV_Y = CARD_H - 3.95
make_text(N("Nav_Left_Arrow"), "←", (0.22, NAV_Y), 0.20, N("NavLeftArrowMat"),
          TEXT_DIM_COL, tier="controls", align='LEFT', strength=1.0, coll=coll)
make_text(N("Nav_Left_Plus"), "+", (0.46, NAV_Y), 0.20, N("NavLeftPlusMat"),
          TEXT_DIM_COL, tier="controls", align='LEFT', strength=1.0, coll=coll)
make_text(N("Nav_Right_Plus"), "+", (CARD_W-0.46, NAV_Y), 0.20, N("NavRightPlusMat"),
          TEXT_DIM_COL, tier="controls", align='RIGHT', strength=1.0, coll=coll)
make_text(N("Nav_Right_Arrow"), "→", (CARD_W-0.22, NAV_Y), 0.20, N("NavRightArrowMat"),
          TEXT_DIM_COL, tier="controls", align='RIGHT', strength=1.0, coll=coll)

# ---------------- Finalize ----------------
finalize_node(coll, CARD_W, CARD_H)

# ---------------- Default visible state ----------------
# Idle, no connections, Execute disabled (input A not yet wired), Wait unchecked.
DEFAULT_VISIBLE = {
    N("Card_Fill"), outline_normal_name, N("Header_Divider"),
    N("Header_Icon"), N("Header_Title"),
    N("PortA_Unfilled"), N("PortA_Ring"), N("PortA_Label"),
    N("PortOut_Unfilled"), N("PortOut_Ring"), N("PortOut_Label"),
    N("AddPort_Plus"), N("AddPort_Hint"),
    N("Script_Fill"), N("Script_Outline"), N("Script_Placeholder"),
    N("OutField_Label"), N("OutField_Fill"), N("OutField_Outline"), N("OutField_Value"),
    N("Button_Disabled"), N("Button_Play_Disabled"), N("Button_Label_Disabled"),
    N("Checkbox_Unchecked_Fill"), N("Checkbox_Unchecked_Outline"), N("Checkbox_Label"),
    N("Script_ScrollTrack"), N("Script_ScrollThumb"), N("Script_ExpandIcon"), N("Script_ExpandHint"),
    N("Nav_Left_Arrow"), N("Nav_Left_Plus"), N("Nav_Right_Plus"), N("Nav_Right_Arrow"),
}

for obj in coll.objects:
    if obj.type == 'CAMERA' or obj.name.endswith("_BG"):
        continue
    should_show = obj.name in DEFAULT_VISIBLE
    obj.hide_viewport = not should_show
    obj.hide_render = not should_show

print(f"Built node: D4M  (collection: {coll.name}, {len(coll.objects)} objects)")
