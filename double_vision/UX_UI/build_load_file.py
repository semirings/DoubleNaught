"""
build_load_file.py — Grease Pencil UX mockup for the "Load File" node.

Spec (per user, 2026):
  - Root node (no input ports) — confirmed.
  - Text field relabeled from "File Path" to "URL"; starts EMPTY (no default
    value / placeholder text baked into the box itself).
  - "Load" button is DISABLED until a URL is entered and validated.
  - Invalid URL shows an explicit error state (red outline + error message).
  - Card border highlights (glows) while the node is executing.
  - Output port ("parsedPayload") has three states:
      unfilled -> no connection
      white    -> connected, idle (no data currently transmitting)
      yellow   -> connected, data actively transmitting
  - "Schema Mode" (Auto-Detect) dropdown REMOVED per this iteration.

States exposed for VSClaude / implementation reference:
  Card outline:   normal | executing | error
  URL field:      normal | error
  Load button:    disabled | enabled | lit (pressed/active)
  Output port:    unfilled | connected_idle | transmitting
"""

import sys, os
HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
from _template import *

NODE_KEY = "LoadFile"
def N(suffix):
    return f"{NODE_KEY}_{suffix}"

CARD_W, CARD_H = 4.4, 3.0
cx = CARD_W / 2

coll = new_node_collection("Load_File")

# ---------------- Card ----------------
card_pts = rounded_rect_points(cx, CARD_H/2, CARD_W, CARD_H, 0.16, 10)
make_filled(N("Card_Fill"), card_pts, N("CardFillMat"), CARD_FILL_COL, tier="fill", coll=coll)

outline_normal_name, outline_executing_name, outline_error_name = build_card_border(coll, N, card_pts)

make_outline(N("Header_Divider"), [(0.18, CARD_H-0.55), (CARD_W-0.18, CARD_H-0.55)],
             N("DividerMat"), OUTLINE_NORMAL_COL, tier="outline", thickness=0.02, strength=0.6, cyclic=False, coll=coll)

# header icon (simple "load" glyph: upward arrow into a tray)
icon_pts = [(0.30,CARD_H-0.28),(0.40,CARD_H-0.38),(0.30,CARD_H-0.48),(0.20,CARD_H-0.38)]
make_filled(N("Header_Icon"), icon_pts, N("IconMat"), (0.66,0.46,1.0,1), tier="controls", strength=3.0, coll=coll)

make_text(N("Header_Title"), "Load File", (0.55, CARD_H-0.38), 0.24, N("TitleMat"), TEXT_COL,
          tier="labels", align='LEFT', strength=1.0, coll=coll)

# ---------------- Output port (root node: output only) ----------------
PORT_Y = CARD_H - 0.85
PORT_R = 0.075

make_filled(N("Port_Unfilled"), circle_points(CARD_W, PORT_Y, PORT_R, 20), N("PortUnfilledMat"),
            (0.28,0.27,0.32,1), tier="controls", strength=0.5, coll=coll)
make_outline(N("Port_Ring"), circle_points(CARD_W, PORT_Y, PORT_R, 20), N("PortRingMat"),
             OUTLINE_NORMAL_COL, tier="controls", thickness=0.012, strength=0.8, coll=coll)
make_filled(N("Port_White"), circle_points(CARD_W, PORT_Y, PORT_R, 20), N("PortWhiteMat"),
            (0.92,0.92,0.95,1), tier="controls_fx", strength=1.5, coll=coll)
make_filled(N("Port_Yellow"), circle_points(CARD_W, PORT_Y, PORT_R*1.15, 20), N("PortYellowMat"),
            (1.0,0.85,0.25,1), tier="controls_fx", strength=8.0, coll=coll)

make_text(N("Port_Label"), "parsedPayload", (CARD_W-0.22, PORT_Y), 0.16, N("PortLabelMat"),
          TEXT_DIM_COL, tier="labels", align='RIGHT', coll=coll)

# ---------------- URL field ----------------
FIELD_LABEL_Y = CARD_H - 1.15
FIELD_Y = CARD_H - 1.55
FIELD_W, FIELD_H = 3.9, 0.5

make_text(N("Field_Label"), "URL", (0.25, FIELD_LABEL_Y), 0.15, N("FieldLabelMat"), TEXT_DIM_COL,
          tier="labels", align='LEFT', coll=coll)

field_pts = rounded_rect_points(cx, FIELD_Y, FIELD_W, FIELD_H, 0.08, 8)
make_filled(N("Field_Fill"), field_pts, N("FieldFillMat"), CONTENT_NORMAL_COL, tier="fill", coll=coll)
make_outline(N("Field_Outline_Normal"), field_pts, N("FieldOutlineNormalMat"), OUTLINE_NORMAL_COL,
             tier="outline", thickness=0.02, strength=0.7, coll=coll)
make_outline(N("Field_Outline_Error"), field_pts, N("FieldOutlineErrorMat"), STATUS_ERROR_COL,
             tier="outline", thickness=0.025, strength=3.5, coll=coll)

# field starts EMPTY per spec — no placeholder text baked in as a permanent
# label; error message only, shown in the error state.
make_text(N("Field_Error_Text"), "Invalid URL", (0.25, CARD_H-1.85), 0.13, N("FieldErrorTextMat"),
          STATUS_ERROR_COL, tier="labels", align='LEFT', strength=2.0, coll=coll)

# ---------------- Load button ----------------
BTN_W, BTN_H = 2.2, 0.46
BTN_Y = CARD_H - 2.45
btn_pts = rounded_rect_points(cx, BTN_Y, BTN_W, BTN_H, 0.18, 8)

make_filled(N("Button_Disabled"), btn_pts, N("ButtonDisabledMat"), BUTTON_DISABLED_COL, tier="fill", strength=0.4, coll=coll)
make_filled(N("Button_Enabled"), btn_pts, N("ButtonEnabledMat"), BUTTON_NORMAL_COL, tier="fill", strength=0.6, coll=coll)
make_filled(N("Button_Lit"), btn_pts, N("ButtonLitMat"), BUTTON_LIT_COL, tier="fill", strength=4.0, coll=coll)

make_text(N("Button_Label_Disabled"), "Load", (cx, BTN_Y), 0.18, N("ButtonLabelDisabledMat"),
          TEXT_DIM_COL, tier="labels", align='CENTER', strength=0.5, coll=coll)
make_text(N("Button_Label_Active"), "Load", (cx, BTN_Y), 0.18, N("ButtonLabelActiveMat"),
          TEXT_COL, tier="labels", align='CENTER', strength=1.2, coll=coll)

# ---------------- Finalize: convert to real GP + camera/background ----------------
finalize_node(coll, CARD_W, CARD_H)

# ---------------- Default visible state on load: idle, no connection, disabled button ----------------
DEFAULT_VISIBLE = {
    N("Card_Fill"), outline_normal_name, N("Header_Divider"), N("Header_Icon"), N("Header_Title"),
    N("Port_Unfilled"), N("Port_Ring"), N("Port_Label"),
    N("Field_Label"), N("Field_Fill"), N("Field_Outline_Normal"),
    N("Button_Disabled"), N("Button_Label_Disabled"),
    N(f"{NODE_KEY}_BG") if False else None,  # placeholder no-op, BG handled by finalize_node
}
DEFAULT_VISIBLE.discard(None)

for obj in coll.objects:
    if obj.type == 'CAMERA' or obj.name.endswith("_BG"):
        continue
    should_show = obj.name in DEFAULT_VISIBLE
    obj.hide_viewport = not should_show
    obj.hide_render = not should_show

print(f"Built node: Load File  (collection: {coll.name}, {len(coll.objects)} objects)")
