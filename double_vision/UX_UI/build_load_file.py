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
  Card outline:    normal | executing | error
  URL field:       normal | error
  Wait checkbox:   unchecked | checked | disabled (locked, mid-execution)
  Execute button:  disabled | enabled | lit | executing (Cancel — see GLOBAL_UX_CONTRACT.md §2) (pressed/active)
  Status row:      idle | running | success | error
  Output port:     unfilled | connected_idle | transmitting
"""

import sys, os
HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
from _template import *

NODE_KEY = "LoadFile"
def N(suffix):
    return f"{NODE_KEY}_{suffix}"

CARD_W, CARD_H = 4.4, 3.9  # grown to fit the newly-added Wait checkbox + status row
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

# ---------------- URL field (with file-dialog icon button, matching Save File) ----------------
FIELD_LABEL_Y = CARD_H - 1.15
FIELD_Y = CARD_H - 1.55
FIELD_H = 0.5
FIELD_W = CARD_W - 0.4 - 0.5  # leave room for the icon button beside it
field_cx = 0.25 + FIELD_W/2

make_text(N("Field_Label"), "URL", (0.25, FIELD_LABEL_Y), 0.15, N("FieldLabelMat"), TEXT_DIM_COL,
          tier="labels", align='LEFT', coll=coll)

field_pts = rounded_rect_points(field_cx, FIELD_Y, FIELD_W, FIELD_H, 0.08, 8)
make_filled(N("Field_Fill"), field_pts, N("FieldFillMat"), CONTENT_NORMAL_COL, tier="fill", coll=coll)
make_outline(N("Field_Outline_Normal"), field_pts, N("FieldOutlineNormalMat"), OUTLINE_NORMAL_COL,
             tier="outline", thickness=0.02, strength=0.7, coll=coll)
make_outline(N("Field_Outline_Error"), field_pts, N("FieldOutlineErrorMat"), STATUS_ERROR_COL,
             tier="outline", thickness=0.025, strength=3.5, coll=coll)

# file-dialog icon button beside the field
icon_x = CARD_W - 0.20 - 0.20
make_filled(N("Field_IconBtn_Body"), rounded_rect_points(icon_x, FIELD_Y, 0.34, FIELD_H, 0.08, 8),
            N("FieldIconBtnBodyMat"), CONTENT_NORMAL_COL, tier="fill", coll=coll)
make_outline(N("Field_IconBtn_Outline"), rounded_rect_points(icon_x, FIELD_Y, 0.34, FIELD_H, 0.08, 8),
             N("FieldIconBtnOutlineMat"), OUTLINE_NORMAL_COL, tier="outline", thickness=0.015, strength=0.6, coll=coll)
make_filled(N("Field_IconBtn_Glyph"), rounded_rect_points(icon_x, FIELD_Y, 0.14, 0.14, 0.02, 6),
            N("FieldIconBtnGlyphMat"), TEXT_DIM_COL, tier="controls", strength=1.0, coll=coll)

# field starts EMPTY per spec — no placeholder text baked in as a permanent
# label; error message only, shown in the error state.
make_text(N("Field_Error_Text"), "Invalid URL", (0.25, CARD_H-1.85), 0.13, N("FieldErrorTextMat"),
          STATUS_ERROR_COL, tier="labels", align='LEFT', strength=2.0, coll=coll)

# ---- Wait / Execute / Status vertical positions — COMPUTED from the
# lowest content above them (the URL field's error-text row, which is the
# lowest thing that can appear there, even conditionally). Never
# hand-picked. ----
_field_area_bottom = (CARD_H - 1.85) - TEXT_ROW_HALF
CHK_Y = wait_checkbox_y(_field_area_bottom)
BTN_Y = execute_button_y(CHK_Y)
STATUS_Y = status_row_y(BTN_Y)

# ---------------- "Wait" checkbox ----------------
# Root nodes generalize the same reactive/gated mechanism as any other
# node: "required inputs satisfied" here means "a valid URL has been
# entered" rather than "an upstream port has data" — same underlying
# behavior, different readiness condition. Added for full consistency
# with every other node (previously Load File was the one Execute-only
# exception; see GLOBAL_UX_CONTRACT.md for the resolution).
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

# ---------------- Execute button (renamed from "Load" — every node says
# Execute now, no exceptions) — shared, standardized: see _template.py ----
btn_states = build_execute_button(coll, N, cx, BTN_Y, w=2.6)

# ---------------- Status row (idle / running / success / error) ----------------
status_objs = build_status_row(coll, N, 0.32, STATUS_Y)

# ---------------- Finalize: convert to real GP + camera/background ----------------
finalize_node(coll, CARD_W, CARD_H)

# ---------------- Default visible state on load: idle, no connection, disabled button ----------------
DEFAULT_VISIBLE = {
    N("Card_Fill"), outline_normal_name, N("Header_Divider"), N("Header_Icon"), N("Header_Title"),
    N("Port_Unfilled"), N("Port_Ring"), N("Port_Label"),
    N("Field_Label"), N("Field_Fill"), N("Field_Outline_Normal"),
    N("Field_IconBtn_Body"), N("Field_IconBtn_Outline"), N("Field_IconBtn_Glyph"),
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

print(f"Built node: Load File  (collection: {coll.name}, {len(coll.objects)} objects)")
