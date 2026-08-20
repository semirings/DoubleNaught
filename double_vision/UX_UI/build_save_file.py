"""
build_save_file.py — Grease Pencil UX mockup for "Save File".

Spec (per user, 2026):
  - Three input ports (dataToSave, textIn, imageIn) -> ONE input port,
    named "dataIn". No output port (sink node — writes to disk).
  - "File Path (storage/out/ or ...)" label -> "URL" (same rename pattern
    as Load File). UNLIKE Load File, this field's value was NOT instructed
    to be cleared — kept showing "storage/out/export" as the default/
    example value. Flag if "URL field = empty" should be a standing rule
    for every URL-labeled field rather than a Load-File-specific choice.
  - Button "Save / Export" -> "Execute" (standard Execute button pattern).
  - Add checkbox "Wait" (standard: above Execute, below other widgets).
  - "Format" dropdown ("Parquet"): unchanged, kept as the standard pick-list
    pattern (reused from LLM Documenter / JSONL Formatter).
  - "Ready to save" -> replaced with the STANDARD idle/running/success/error
    status row (build_status_row), matching every other node — no longer a
    one-off green line.
  - URL field value ("storage/out/export") REMOVED — field starts empty,
    matching Load File's precedent. This is now the standing rule for every
    URL-labeled field going forward, not a Load-File-specific exception.
  - Small save/browse icon button beside the URL field: kept (not
    instructed to remove), drawn as a simple floppy-disk-style glyph.

States exposed for VSClaude / implementation reference:
  Card border:     normal | executing | error         (shared convention)
  Input port:        unfilled | connected_idle | transmitting
  Format picklist:  closed only (value: Parquet)
  Execute button:   disabled | enabled | lit | executing (Cancel — see GLOBAL_UX_CONTRACT.md §2)
  Wait checkbox:    unchecked | checked | disabled (locked, mid-execution)
  Status row:       idle | running | success | error (standard, shared)
"""

import sys, os
HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
from _template import *

NODE_KEY = "SaveFile"
def N(suffix):
    return f"{NODE_KEY}_{suffix}"

CARD_W, CARD_H = 4.4, 3.9
cx = CARD_W / 2

coll = new_node_collection("Save_File")

# ---------------- Card + standard border ----------------
card_pts = rounded_rect_points(cx, CARD_H/2, CARD_W, CARD_H, 0.16, 10)
make_filled(N("Card_Fill"), card_pts, N("CardFillMat"), CARD_FILL_COL, tier="fill", coll=coll)
outline_normal_name, outline_executing_name, outline_error_name = build_card_border(coll, N, card_pts)

make_outline(N("Header_Divider"), [(0.18, CARD_H-0.55), (CARD_W-0.18, CARD_H-0.55)],
             N("DividerMat"), OUTLINE_NORMAL_COL, tier="outline", thickness=0.02, strength=0.6, cyclic=False, coll=coll)

# header icon: floppy-disk glyph (small rounded square + notch)
make_filled(N("Header_Icon_Body"), rounded_rect_points(0.30, CARD_H-0.38, 0.20, 0.20, 0.03, 6),
            N("IconBodyMat"), (0.66,0.46,1.0,1), tier="controls", strength=2.5, coll=coll)
make_filled(N("Header_Icon_Notch"), rounded_rect_points(0.30, CARD_H-0.30, 0.10, 0.06, 0.01, 4),
            N("IconNotchMat"), CARD_FILL_COL, tier="controls_fx", strength=0.5, coll=coll)

make_text(N("Header_Title"), "Save File", (0.55, CARD_H-0.38), 0.24, N("TitleMat"), TEXT_COL,
          tier="labels", align='LEFT', strength=1.0, coll=coll)

# ---------------- Single input port: dataIn ----------------
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

make_text(N("Port_Label"), "dataIn", (0.22, PORT_Y), 0.19, N("PortLabelMat"), TEXT_COL,
          tier="labels", align='LEFT', coll=coll)

# ---------------- URL field (renamed from "File Path ...") ----------------
URL_LABEL_Y = CARD_H - 1.15
URL_BOX_Y = CARD_H - 1.55
URL_BOX_W = CARD_W - 0.4 - 0.5  # leave room for the icon button beside it
URL_BOX_H = 0.5

make_text(N("URL_Label"), "URL", (0.20, URL_LABEL_Y), 0.15, N("URLLabelMat"), TEXT_DIM_COL,
          tier="labels", align='LEFT', coll=coll)

url_box_cx = 0.20 + URL_BOX_W/2
url_pts = rounded_rect_points(url_box_cx, URL_BOX_Y, URL_BOX_W, URL_BOX_H, 0.08, 8)
make_filled(N("URL_Fill"), url_pts, N("URLFillMat"), CONTENT_NORMAL_COL, tier="fill", coll=coll)
make_outline(N("URL_Outline"), url_pts, N("URLOutlineMat"), OUTLINE_NORMAL_COL,
             tier="outline", thickness=0.02, strength=0.7, coll=coll)
# small save/browse icon button beside the field
icon_x = CARD_W - 0.20 - 0.20
make_filled(N("URL_IconBtn_Body"), rounded_rect_points(icon_x, URL_BOX_Y, 0.34, URL_BOX_H, 0.08, 8),
            N("URLIconBtnBodyMat"), CONTENT_NORMAL_COL, tier="fill", coll=coll)
make_outline(N("URL_IconBtn_Outline"), rounded_rect_points(icon_x, URL_BOX_Y, 0.34, URL_BOX_H, 0.08, 8),
             N("URLIconBtnOutlineMat"), OUTLINE_NORMAL_COL, tier="outline", thickness=0.015, strength=0.6, coll=coll)
make_filled(N("URL_IconBtn_Glyph"), rounded_rect_points(icon_x, URL_BOX_Y, 0.14, 0.14, 0.02, 6),
            N("URLIconBtnGlyphMat"), TEXT_DIM_COL, tier="controls", strength=1.0, coll=coll)

# ---------------- Format pick list (unchanged, reused dropdown pattern) ----------------
FMT_LABEL_Y = CARD_H - 1.95
FMT_BOX_Y = CARD_H - 2.35
FMT_BOX_W = CARD_W - 0.4
FMT_BOX_H = 0.5

make_text(N("Format_Label"), "Format", (0.20, FMT_LABEL_Y), 0.15, N("FormatLabelMat"), TEXT_DIM_COL,
          tier="labels", align='LEFT', coll=coll)
fmt_pts = rounded_rect_points(cx, FMT_BOX_Y, FMT_BOX_W, FMT_BOX_H, 0.08, 8)
make_filled(N("Format_Fill"), fmt_pts, N("FormatFillMat"), CONTENT_NORMAL_COL, tier="fill", coll=coll)
make_outline(N("Format_Outline"), fmt_pts, N("FormatOutlineMat"), OUTLINE_NORMAL_COL,
             tier="outline", thickness=0.02, strength=0.7, coll=coll)
make_text(N("Format_Value"), "Parquet", (0.40, FMT_BOX_Y), 0.19, N("FormatValueMat"),
          TEXT_COL, tier="labels", align='LEFT', coll=coll)
make_text(N("Format_Chevron"), "\u25be", (CARD_W-0.35, FMT_BOX_Y), 0.18, N("FormatChevronMat"),
          TEXT_DIM_COL, tier="controls", align='LEFT', strength=1.0, coll=coll)

# ---- Wait / Execute vertical positions — COMPUTED from the Format box's
# actual bottom edge. Never hand-picked. ----
_format_box_bottom = FMT_BOX_Y - FMT_BOX_H/2
CHK_Y = wait_checkbox_y(_format_box_bottom)
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

# ---------------- Status row (standard idle/running/success/error, same as other nodes) ----------------
STATUS_Y = status_row_y(BTN_Y)
status_objs = build_status_row(coll, N, 0.32, STATUS_Y)

# ---------------- Finalize ----------------
finalize_node(coll, CARD_W, CARD_H)

# ---------------- Default visible state ----------------
DEFAULT_VISIBLE = {
    N("Card_Fill"), outline_normal_name, N("Header_Divider"),
    N("Header_Icon_Body"), N("Header_Icon_Notch"), N("Header_Title"),
    N("Port_Unfilled"), N("Port_Ring"), N("Port_Label"),
    N("URL_Label"), N("URL_Fill"), N("URL_Outline"), N("URL_Value"),
    N("URL_IconBtn_Body"), N("URL_IconBtn_Outline"), N("URL_IconBtn_Glyph"),
    N("Format_Label"), N("Format_Fill"), N("Format_Outline"), N("Format_Value"), N("Format_Chevron"),
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

print(f"Built node: Save File  (collection: {coll.name}, {len(coll.objects)} objects)")
