"""
build_preview.py — Grease Pencil UX mockup for the "Preview" node.

Spec (per user, 2026 — v2, supersedes the button/mode-pill version):
  - Sink node: single input port ("previewData"), no output port.
  - No "Connect an AA source" text (removed in v1, stays removed).
  - REMOVED entirely: "View" button, "Data-Driven"/"Command-Driven" mode
    pills. Replaced by a single checkbox toggle labeled "wait":
      unchecked -> fire on receipt   (REACTIVE — auto-runs when data arrives)
      checked   -> fire on command   (GATED — waits for explicit trigger)
    Behavior: the checkbox can be checked to switch into wait mode. The act
    of UNCHECKING it (while it was checked) IS the command that fires
    execution. Once execution starts, the checkbox is LOCKED (cannot be
    checked again) until execution completes — you cannot switch into wait
    mode mid-flight.

States exposed for VSClaude / implementation reference:
  Card border:  normal | executing | error          (shared convention)
  Input port:   unfilled | connected_idle | transmitting
  Wait checkbox: unchecked | checked | disabled (locked, mid-execution)
"""

import sys, os
HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
from _template import *

NODE_KEY = "Preview"
def N(suffix):
    return f"{NODE_KEY}_{suffix}"

CARD_W, CARD_H = 4.4, 1.9
cx = CARD_W / 2

coll = new_node_collection("Preview")

# ---------------- Card + standard border (shared convention) ----------------
card_pts = rounded_rect_points(cx, CARD_H/2, CARD_W, CARD_H, 0.16, 10)
make_filled(N("Card_Fill"), card_pts, N("CardFillMat"), CARD_FILL_COL, tier="fill", coll=coll)
outline_normal_name, outline_executing_name, outline_error_name = build_card_border(coll, N, card_pts)

make_outline(N("Header_Divider"), [(0.18, CARD_H-0.55), (CARD_W-0.18, CARD_H-0.55)],
             N("DividerMat"), OUTLINE_NORMAL_COL, tier="outline", thickness=0.02, strength=0.6, cyclic=False, coll=coll)

# header icon (simple "eye" glyph: outer lens ring + pupil dot)
make_outline(N("Header_Icon_Ring"), circle_points(0.30, CARD_H-0.38, 0.10, 20), N("IconRingMat"),
             (0.66,0.46,1.0,1), tier="controls", thickness=0.018, strength=2.5, cyclic=True, coll=coll)
make_filled(N("Header_Icon_Pupil"), circle_points(0.30, CARD_H-0.38, 0.035, 12), N("IconPupilMat"),
            (0.66,0.46,1.0,1), tier="controls", strength=3.0, coll=coll)

make_text(N("Header_Title"), "Preview", (0.55, CARD_H-0.38), 0.24, N("TitleMat"), TEXT_COL,
          tier="labels", align='LEFT', strength=1.0, coll=coll)

# ---------------- Input port (sink node: input only) ----------------
PORT_Y = CARD_H - 0.85
PORT_R = 0.075

make_filled(N("Port_Unfilled"), circle_points(0, PORT_Y, PORT_R, 20), N("PortUnfilledMat"),
            (0.28,0.27,0.32,1), tier="controls", strength=0.5, coll=coll)
make_outline(N("Port_Ring"), circle_points(0, PORT_Y, PORT_R, 20), N("PortRingMat"),
             OUTLINE_NORMAL_COL, tier="controls", thickness=0.012, strength=0.8, coll=coll)
make_filled(N("Port_White"), circle_points(0, PORT_Y, PORT_R, 20), N("PortWhiteMat"),
            (0.92,0.92,0.95,1), tier="controls_fx", strength=1.5, coll=coll)
make_filled(N("Port_Yellow"), circle_points(0, PORT_Y, PORT_R*1.15, 20), N("PortYellowMat"),
            (1.0,0.85,0.25,1), tier="controls_fx", strength=8.0, coll=coll)

make_text(N("Port_Label"), "previewData", (0.22, PORT_Y), 0.19, N("PortLabelMat"),
          TEXT_COL, tier="labels", align='LEFT', coll=coll)

# ---------------- "wait" checkbox ----------------
CHK_Y = CARD_H - 1.35
CHK_X = 0.32
CHK_SIZE = 0.22

chk_pts = [
    (CHK_X - CHK_SIZE/2, CHK_Y - CHK_SIZE/2),
    (CHK_X + CHK_SIZE/2, CHK_Y - CHK_SIZE/2),
    (CHK_X + CHK_SIZE/2, CHK_Y + CHK_SIZE/2),
    (CHK_X - CHK_SIZE/2, CHK_Y + CHK_SIZE/2),
]

# Unchecked: hollow box (outline only)
make_filled(N("Checkbox_Unchecked_Fill"), chk_pts, N("ChkUncheckedFillMat"), CONTENT_NORMAL_COL, tier="fill", strength=0.5, coll=coll)
make_outline(N("Checkbox_Unchecked_Outline"), chk_pts, N("ChkUncheckedOutlineMat"), OUTLINE_NORMAL_COL,
             tier="outline", thickness=0.016, strength=1.2, coll=coll)

# Checked: filled accent box (+ outline)
make_filled(N("Checkbox_Checked_Fill"), chk_pts, N("ChkCheckedFillMat"), CONTENT_LIT_COL, tier="controls_fx", strength=3.0, coll=coll)
make_outline(N("Checkbox_Checked_Outline"), chk_pts, N("ChkCheckedOutlineMat"), (0.78,0.55,1.0,1),
             tier="controls_fx", thickness=0.016, strength=3.0, coll=coll)
# simple checkmark tick inside (two short strokes)
make_outline(N("Checkbox_Checkmark"),
             [(CHK_X-0.06, CHK_Y-0.005), (CHK_X-0.015, CHK_Y-0.06), (CHK_X+0.075, CHK_Y+0.07)],
             N("ChkCheckmarkMat"), TEXT_COL, tier="labels", thickness=0.012, strength=1.5, cyclic=False, coll=coll)

# Disabled/locked: dim box, shown during execution (checkbox cannot be toggled)
make_filled(N("Checkbox_Disabled_Fill"), chk_pts, N("ChkDisabledFillMat"), (0.10,0.10,0.12,1), tier="fill", strength=0.3, coll=coll)
make_outline(N("Checkbox_Disabled_Outline"), chk_pts, N("ChkDisabledOutlineMat"), (0.32,0.32,0.35,1),
             tier="outline", thickness=0.016, strength=0.5, coll=coll)

make_text(N("Checkbox_Label"), "wait", (CHK_X + CHK_SIZE/2 + 0.14, CHK_Y), 0.18, N("ChkLabelMat"),
          TEXT_COL, tier="labels", align='LEFT', coll=coll)

# ---------------- Finalize ----------------
finalize_node(coll, CARD_W, CARD_H)

# ---------------- Default visible state ----------------
# Idle, no connection, checkbox unchecked (fire-on-receipt, the default mode).
DEFAULT_VISIBLE = {
    N("Card_Fill"), outline_normal_name, N("Header_Divider"),
    N("Header_Icon_Ring"), N("Header_Icon_Pupil"), N("Header_Title"),
    N("Port_Unfilled"), N("Port_Ring"), N("Port_Label"),
    N("Checkbox_Unchecked_Fill"), N("Checkbox_Unchecked_Outline"), N("Checkbox_Label"),
}

for obj in coll.objects:
    if obj.type == 'CAMERA' or obj.name.endswith("_BG"):
        continue
    should_show = obj.name in DEFAULT_VISIBLE
    obj.hide_viewport = not should_show
    obj.hide_render = not should_show

print(f"Built node: Preview  (collection: {coll.name}, {len(coll.objects)} objects)")
