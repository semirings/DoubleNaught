"""
_template.py — Shared Grease Pencil builder utilities for DoubleNaught node UX mockups.

USAGE (from a build_<node>.py script, run inside Blender via the MCP connection):

    import sys
    sys.path.insert(0, "/Users/gcr/populi.Wk/DoubleNaught/double_vision/UX_UI")
    from _template import *

    coll = new_node_collection("Function_Extraction")
    build_card(coll, "Function Extraction", w=4.2, h=2.6)
    ...
    finalize_node(coll, card_w=4.2, card_h=2.6)

This module is the single source of truth for:
  - the depth-tier convention (prevents z-order fights — see TIER_Z below)
  - the shared color palette (keeps every node visually consistent)
  - geometry helpers (rounded rects, circles)
  - element builders (filled shapes, outlines, text) that auto-apply the
    correct tier depth so callers never have to think about z-order
  - GP conversion + camera/background/world setup shared by every node

DO NOT hand-edit NodeUX.blend in the GUI and expect changes to persist.
The .blend file is a generated artifact. All durable changes belong in this
file or in a build_<node>.py script. See GP_LAYER_CONVENTION below.
"""

import bpy
import math

# ============================================================
# GP_LAYER_CONVENTION
#
# Every node is built from flat 2D shapes sharing the same XY plane. Without
# an explicit stacking rule, Blender has no reliable way to decide draw order
# for coincident geometry (z-fighting) — this bit us once already (a button
# label was invisible behind its own button fill).
#
# Fix: every element belongs to one of five depth tiers, back to front.
# Builder functions below (make_filled / make_outline / make_text) take a
# `tier` argument and apply the correct Z automatically — callers should
# never set Z by hand.
# ============================================================
TIER_Z = {
    "fill":         0.000,  # card background, pill fills, button fills
    "outline":      0.003,  # card outline, dividers
    "controls":     0.006,  # ports, icons, status dots (normal/idle state)
    "controls_fx":  0.009,  # "lit"/alternate-state glow variants
    "labels":       0.012,  # all text — always frontmost
}

# ============================================================
# Shared color palette — reuse across every node for visual consistency.
# (Ref: cross-node consistency requirement from the implementation-prompt
# template — these are the canonical values other nodes should match.)
# ============================================================
CARD_FILL_COL       = (0.098, 0.098, 0.118, 1)
OUTLINE_NORMAL_COL    = (0.58, 0.58, 0.62, 1)   # grey — default/idle border, all nodes
OUTLINE_EXECUTING_COL = (1.0, 1.0, 1.0, 1)      # pure white (#FFFFFF) — border while node is executing, all nodes
OUTLINE_THICKNESS     = 0.05                     # standard border thickness, all nodes
OUTLINE_STRENGTH_NORMAL    = 1.4
OUTLINE_STRENGTH_EXECUTING = 7.0
OUTLINE_STRENGTH_ERROR     = 6.0
TEXT_COL            = (0.88, 0.87, 0.92, 1)
TEXT_DIM_COL        = (0.55, 0.54, 0.60, 1)
PORT_NORMAL_COL     = (0.50, 0.42, 0.68, 1)
PORT_LIT_COL        = (0.78, 0.55, 1.0, 1)
PORT_READY_COL      = (0.60, 0.62, 0.42, 1)   # data arrived, node not yet run
CONTENT_NORMAL_COL  = (0.17, 0.16, 0.21, 1)
CONTENT_LIT_COL     = (0.42, 0.28, 0.62, 1)
BUTTON_NORMAL_COL   = (0.20, 0.19, 0.27, 1)
BUTTON_LIT_COL      = (0.58, 0.34, 0.98, 1)
BUTTON_DISABLED_COL = (0.13, 0.13, 0.15, 1)
BUTTON_CANCEL_COL   = (0.95, 0.55, 0.20, 1)  # amber/orange — deliberately
                                              # NOT the same red as the
                                              # error state, so "you can
                                              # cancel this" never reads as
                                              # "something failed"
STATUS_IDLE_COL     = (0.52, 0.52, 0.56, 1)
STATUS_RUNNING_COL  = (0.80, 0.58, 1.0, 1)
STATUS_SUCCESS_COL  = (0.35, 0.85, 0.48, 1)
STATUS_ERROR_COL    = (0.92, 0.28, 0.28, 1)

# ============================================================
# Material cache
# ============================================================
def get_mat(name, color, strength=0.6):
    """Emission material, cached by name so repeated calls reuse the same material."""
    if name in bpy.data.materials:
        return bpy.data.materials[name]
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.clear()
    out = nt.nodes.new('ShaderNodeOutputMaterial')
    emis = nt.nodes.new('ShaderNodeEmission')
    emis.inputs['Color'].default_value = color
    emis.inputs['Strength'].default_value = max(strength, 0.6)
    nt.links.new(emis.outputs['Emission'], out.inputs['Surface'])
    mat.diffuse_color = color
    return mat


# ============================================================
# Geometry helpers
# ============================================================
def _arc(cx, cy, r, a0, a1, n):
    return [(cx + r*math.cos(a0 + (a1-a0)*i/n), cy + r*math.sin(a0 + (a1-a0)*i/n)) for i in range(n+1)]

def rounded_rect_points(cx, cy, w, h, r, segs=8):
    x0, x1 = cx-w/2, cx+w/2
    y0, y1 = cy-h/2, cy+h/2
    pts = []
    pts += _arc(x1-r, y0+r, r, -math.pi/2, 0, segs)
    pts += _arc(x1-r, y1-r, r, 0, math.pi/2, segs)
    pts += _arc(x0+r, y1-r, r, math.pi/2, math.pi, segs)
    pts += _arc(x0+r, y0+r, r, math.pi, 1.5*math.pi, segs)
    return pts

def circle_points(cx, cy, r, segs=24):
    return [(cx + r*math.cos(2*math.pi*i/segs), cy + r*math.sin(2*math.pi*i/segs)) for i in range(segs)]


# ============================================================
# Element builders — each applies the correct tier Z automatically.
# All return the created object (a curve/font object; convert to GP via
# finalize_node() at the end of a node build).
# ============================================================
def make_filled(name, pts2d, matname, color, tier, strength=0.6, coll=None):
    curve = bpy.data.curves.new(name, 'CURVE')
    curve.dimensions = '2D'
    curve.fill_mode = 'BOTH'
    spline = curve.splines.new('POLY')
    spline.points.add(len(pts2d)-1)
    for i,(x,y) in enumerate(pts2d):
        spline.points[i].co = (x, y, 0, 1)
    spline.use_cyclic_u = True
    obj = bpy.data.objects.new(name, curve)
    obj.location.z = TIER_Z[tier]
    obj.data.materials.append(get_mat(matname, color, strength))
    (coll or bpy.context.collection).objects.link(obj)
    return obj

def make_outline(name, pts2d, matname, color, tier, thickness=0.035, strength=0.6, cyclic=True, coll=None):
    curve = bpy.data.curves.new(name, 'CURVE')
    curve.dimensions = '3D'
    curve.bevel_depth = thickness
    curve.bevel_resolution = 2
    spline = curve.splines.new('POLY')
    spline.points.add(len(pts2d)-1)
    for i,p in enumerate(pts2d):
        spline.points[i].co = (p[0], p[1], 0, 1)
    spline.use_cyclic_u = cyclic
    obj = bpy.data.objects.new(name, curve)
    obj.location.z = TIER_Z[tier]
    obj.data.materials.append(get_mat(matname, color, strength))
    (coll or bpy.context.collection).objects.link(obj)
    return obj

def make_text(name, body, loc, size, matname, color, tier="labels", align='LEFT', strength=1.0, coll=None):
    fc = bpy.data.curves.new(name, 'FONT')
    fc.body = body
    fc.size = size
    fc.align_x = align
    fc.align_y = 'CENTER'
    fc.extrude = 0.0
    obj = bpy.data.objects.new(name, fc)
    obj.location = (loc[0], loc[1], TIER_Z[tier])
    obj.data.materials.append(get_mat(matname, color, strength))
    (coll or bpy.context.collection).objects.link(obj)
    return obj


# ============================================================
# Standard card border — IDENTICAL across every node (per project convention:
# "all node borders are the same"). Always use this instead of hand-rolling
# outline calls in a build_<node>.py script.
#
#   normal    -> grey  (OUTLINE_NORMAL_COL)    — default/idle state
#   executing -> white (#FFFFFF)               — while the node is running
#   error     -> red   (STATUS_ERROR_COL)      — node failed
#
# Returns the three object names so the caller can wire up default
# visibility (normal shown, executing/error hidden until triggered).
# ============================================================
def build_card_border(coll, N, card_pts):
    make_outline(N("Outline_Normal"), card_pts, N("OutlineNormalMat"), OUTLINE_NORMAL_COL,
                 tier="outline", thickness=OUTLINE_THICKNESS, strength=OUTLINE_STRENGTH_NORMAL, coll=coll)
    make_outline(N("Outline_Executing"), card_pts, N("OutlineExecutingMat"), OUTLINE_EXECUTING_COL,
                 tier="outline", thickness=OUTLINE_THICKNESS, strength=OUTLINE_STRENGTH_EXECUTING, coll=coll)
    make_outline(N("Outline_Error"), card_pts, N("OutlineErrorMat"), STATUS_ERROR_COL,
                 tier="outline", thickness=OUTLINE_THICKNESS, strength=OUTLINE_STRENGTH_ERROR, coll=coll)
    return N("Outline_Normal"), N("Outline_Executing"), N("Outline_Error")


# ============================================================
# WIDGET VERTICAL ORDER CONVENTION (all nodes)
#
# For any node that has a Wait checkbox and/or an Execute button, the
# standing vertical order — top to bottom — is:
#
#     [ any other widgets: ports, fields, script boxes, etc. ]
#     Wait checkbox         <- above Execute, below everything else
#     Execute button         <- below Wait, above the status bar
#     [ status bar, if present ]
#
# This was decided after D4M and Function Extraction initially had these
# reversed (Execute above Wait); both were corrected and this ordering is
# now the standard for every future node. When laying out a new
# build_<node>.py, place the Wait checkbox's Y coordinate ABOVE (i.e. a
# smaller CARD_H-offset than) the Execute button's Y coordinate, and place
# the button just above the status row (or above the bottom margin, if the
# node has no status row).
# ============================================================

# ============================================================
# WAIT / EXECUTE / STATUS VERTICAL SPACING — computed, not hand-picked.
#
# Root cause of the inconsistency found across the first several nodes:
# each build_<node>.py picked its own raw Y offset for the Wait checkbox,
# copied from whatever the previous node happened to use. Because the
# widget directly above Wait has a different height on different nodes
# (a 0.5-tall field box vs. a bare port-label row vs. a 0.34-tall field),
# matching offset NUMBERS did not produce matching VISUAL gaps, and
# non-matching numbers made it worse.
#
# Fix: always compute Wait/Execute/status Y from the actual bottom edge of
# whatever precedes them, using these constants + helper functions. Never
# hand-pick a CHK_Y / BTN_Y / STATUS_Y offset again — this is what prevents
# future drift.
# ============================================================
GAP_BEFORE_WAIT      = 0.20  # clear space: last "other" widget -> Wait checkbox
GAP_WAIT_TO_EXECUTE  = 0.10  # clear space: Wait checkbox -> Execute button
GAP_EXECUTE_TO_STATUS = 0.15  # clear space: Execute button -> status row (if present)

WAIT_CHK_SIZE  = 0.22
EXECUTE_BTN_H  = 0.46
TEXT_ROW_HALF  = 0.13  # nominal half-height to use when the preceding widget
                        # is a bare text/port row rather than a boxed field
                        # (i.e. it has no explicit height of its own)

def wait_checkbox_y(prev_bottom_y):
    """prev_bottom_y = the Y of the BOTTOM edge of the last widget above
    Wait (box_center_y - box_height/2, or row_y - TEXT_ROW_HALF for a bare
    text/port row). Returns Wait checkbox's center Y."""
    return prev_bottom_y - GAP_BEFORE_WAIT - WAIT_CHK_SIZE/2

def execute_button_y(wait_chk_y):
    """Given Wait's center Y, returns Execute button's center Y directly
    below it, using the standard gap."""
    return wait_chk_y - WAIT_CHK_SIZE/2 - GAP_WAIT_TO_EXECUTE - EXECUTE_BTN_H/2

def status_row_y(execute_btn_y):
    """Given Execute's center Y, returns the status row's Y directly below
    it, using the standard gap. Only call this for nodes that have a
    status row (not all do — e.g. D4M does not)."""
    return execute_btn_y - EXECUTE_BTN_H/2 - GAP_EXECUTE_TO_STATUS


# ============================================================
# Standard Execute button — text + arrowhead (arrow ALWAYS to the right of
# the label). FOUR states: disabled / enabled / lit (brief press flash) /
# executing (the button becomes a CANCEL button for the full duration of
# execution — relabeled "Cancel", amber/orange, arrowhead replaced with a
# stop-square icon; clicking it immediately aborts the in-flight operation
# and the button reverts to its normal Execute state on completion or
# cancellation). Previously each node built its own Execute button by
# hand: D4M had a play-triangle icon on the LEFT, every other node had no
# icon at all. Standardized here: always use this function so every
# node's Execute/Cancel button matches exactly, with no per-node variation
# possible.
# ============================================================
def build_execute_button(coll, N, cx, y, w=3.6, h=None):
    h = h if h is not None else EXECUTE_BTN_H
    btn_pts = rounded_rect_points(cx, y, w, h, 0.18, 8)

    make_filled(N("Button_Disabled"), btn_pts, N("ButtonDisabledMat"), BUTTON_DISABLED_COL, tier="fill", strength=0.4, coll=coll)
    make_filled(N("Button_Enabled"), btn_pts, N("ButtonEnabledMat"), BUTTON_NORMAL_COL, tier="fill", strength=0.6, coll=coll)
    make_filled(N("Button_Lit"), btn_pts, N("ButtonLitMat"), BUTTON_LIT_COL, tier="fill", strength=4.0, coll=coll)
    make_filled(N("Button_Cancel"), btn_pts, N("ButtonCancelMat"), BUTTON_CANCEL_COL, tier="fill", strength=3.0, coll=coll)

    # Label shifted slightly left of button-center so the (label + icon)
    # group as a whole reads as centered, with the icon to the right.
    label_x = cx - 0.20
    make_text(N("Button_Label_Disabled"), "Execute", (label_x, y), 0.18, N("ButtonLabelDisabledMat"),
              TEXT_DIM_COL, tier="labels", align='CENTER', strength=0.5, coll=coll)
    make_text(N("Button_Label_Active"), "Execute", (label_x, y), 0.18, N("ButtonLabelActiveMat"),
              TEXT_COL, tier="labels", align='CENTER', strength=1.2, coll=coll)
    make_text(N("Button_Label_Cancel"), "Cancel", (label_x, y), 0.18, N("ButtonLabelCancelMat"),
              TEXT_COL, tier="labels", align='CENTER', strength=1.2, coll=coll)

    icon_x = cx + 0.62
    # arrowhead (Execute states)
    tri_pts = [(icon_x-0.065, y-0.09), (icon_x-0.065, y+0.09), (icon_x+0.075, y)]
    make_filled(N("Button_Arrow_Disabled"), tri_pts, N("ButtonArrowDisabledMat"), TEXT_DIM_COL, tier="labels", strength=0.5, coll=coll)
    make_filled(N("Button_Arrow_Active"), tri_pts, N("ButtonArrowActiveMat"), TEXT_COL, tier="labels", strength=1.2, coll=coll)
    # stop-square (Cancel state) — deliberately NOT an arrow shape, since
    # "point forward" makes no sense for a stop action
    sq_r = 0.07
    stop_pts = [(icon_x-sq_r, y-sq_r), (icon_x+sq_r, y-sq_r), (icon_x+sq_r, y+sq_r), (icon_x-sq_r, y+sq_r)]
    make_filled(N("Button_Stop_Icon"), stop_pts, N("ButtonStopIconMat"), TEXT_COL, tier="labels", strength=1.4, coll=coll)

    return {
        "disabled":  [N("Button_Disabled"), N("Button_Label_Disabled"), N("Button_Arrow_Disabled")],
        "enabled":   [N("Button_Enabled"),  N("Button_Label_Active"),   N("Button_Arrow_Active")],
        "lit":       [N("Button_Lit"),      N("Button_Label_Active"),   N("Button_Arrow_Active")],
        "executing": [N("Button_Cancel"),   N("Button_Label_Cancel"),   N("Button_Stop_Icon")],
    }


# ============================================================
# Standard status row — dot + label, four mutually-exclusive states.
# Shared so every node's idle/running/success/error indicator looks and
# behaves identically. Returns a dict of {state: (dot_name, text_name)}.
# ============================================================
def build_status_row(coll, N, x, y, dot_r=0.06):
    specs = [
        ("idle",    STATUS_IDLE_COL,    "idle",    0.5, 0.5),
        ("running", STATUS_RUNNING_COL, "running", 6.0, 1.0),
        ("success", STATUS_SUCCESS_COL, "done",    5.0, 1.0),
        ("error",   STATUS_ERROR_COL,   "error",   5.0, 1.0),
    ]
    result = {}
    for state, color, label, strength, text_strength in specs:
        dot_name = N(f"Status_{state.capitalize()}_Dot")
        text_name = N(f"Status_{state.capitalize()}_Text")
        make_filled(dot_name, circle_points(x, y, dot_r, 16), N(f"Status{state.capitalize()}DotMat"),
                    color, tier="controls", strength=strength, coll=coll)
        make_text(text_name, label, (x + dot_r + 0.14, y), 0.15, N(f"Status{state.capitalize()}TextMat"),
                  TEXT_DIM_COL, tier="labels", align='LEFT', strength=text_strength, coll=coll)
        result[state] = (dot_name, text_name)
    return result


# ============================================================
# Collection / scene setup
# ============================================================
def new_node_collection(node_name):
    """Create (or reset) the collection for one node, linked to the scene."""
    if node_name in bpy.data.collections:
        old = bpy.data.collections[node_name]
        for o in list(old.objects):
            bpy.data.objects.remove(o, do_unlink=True)
        bpy.data.collections.remove(old)
    coll = bpy.data.collections.new(node_name)
    bpy.context.scene.collection.children.link(coll)
    return coll

def convert_collection_to_gp(coll):
    """Convert every curve/font object in the collection to real Grease Pencil geometry.

    The convert operator needs a valid VIEW_3D area/region in its context to
    run reliably (this bit us once: after build_all.py resets to a clean
    file, no viewport context is guaranteed to be attached to the calling
    context, and the operator fails silently with "No editable objects to
    convert" even though objects are correctly selected). We find a real
    VIEW_3D area anywhere in any open window and explicitly override context
    with it; if none exists at all (e.g. true headless background mode with
    no screen), we fall back to calling it without an override.
    """
    bpy.ops.object.select_all(action='DESELECT')
    to_convert = [o for o in coll.objects if o.type in ('CURVE', 'FONT')]
    if not to_convert:
        return
    for o in to_convert:
        o.select_set(True)
    bpy.context.view_layer.objects.active = to_convert[0]

    window = area = region = None
    for win in bpy.context.window_manager.windows:
        for ar in win.screen.areas:
            if ar.type == 'VIEW_3D':
                window, area = win, ar
                for reg in ar.regions:
                    if reg.type == 'WINDOW':
                        region = reg
                        break
                break
        if area:
            break

    if area and region and window:
        with bpy.context.temp_override(window=window, area=area, region=region):
            bpy.ops.object.convert(target='GREASEPENCIL')
    else:
        bpy.ops.object.convert(target='GREASEPENCIL')

def setup_camera_and_background(coll, card_w, card_h, cam_name=None):
    """Create an orthographic front-facing camera framing the card, plus a
    dark background plane and world color. Call once per node collection."""
    cam_name = cam_name or f"{coll.name}_Cam"
    if cam_name in bpy.data.objects:
        cam = bpy.data.objects[cam_name]
    else:
        cam_data = bpy.data.cameras.new(cam_name)
        cam_data.type = 'ORTHO'
        cam = bpy.data.objects.new(cam_name, cam_data)
        coll.objects.link(cam)
    cam.data.ortho_scale = max(card_w, card_h) * 1.35
    cam.location = (card_w/2, card_h/2, 10)
    cam.rotation_euler = (0, 0, 0)
    bpy.context.scene.camera = cam

    bg_name = f"{coll.name}_BG"
    if bg_name not in bpy.data.objects:
        mesh = bpy.data.meshes.new(bg_name + "Mesh")
        m = max(card_w, card_h) * 2
        verts = [(-m,-m,-0.05), (card_w+m,-m,-0.05), (card_w+m,card_h+m,-0.05), (-m,card_h+m,-0.05)]
        mesh.from_pydata(verts, [], [[0,1,2,3]])
        mesh.update()
        bg = bpy.data.objects.new(bg_name, mesh)
        coll.objects.link(bg)
        mat = bpy.data.materials.new(bg_name + "_Mat")
        mat.use_nodes = True
        nt = mat.node_tree
        nt.nodes.clear()
        out = nt.nodes.new('ShaderNodeOutputMaterial')
        emis = nt.nodes.new('ShaderNodeEmission')
        emis.inputs['Color'].default_value = (0.045, 0.045, 0.055, 1)
        emis.inputs['Strength'].default_value = 1.0
        nt.links.new(emis.outputs['Emission'], out.inputs['Surface'])
        bg.data.materials.append(mat)

    world = bpy.context.scene.world
    if world is None:
        world = bpy.data.worlds.new("World")
        bpy.context.scene.world = world
    world.use_nodes = True
    bgn = world.node_tree.nodes.get("Background")
    if bgn:
        bgn.inputs[0].default_value = (0.02, 0.02, 0.025, 1)
        bgn.inputs[1].default_value = 0.2

def finalize_node(coll, card_w, card_h):
    """Call once at the end of a build_<node>.py script: converts all
    elements to real Grease Pencil geometry and sets up camera/background."""
    convert_collection_to_gp(coll)
    setup_camera_and_background(coll, card_w, card_h)


# ============================================================
# Port state convention (4 states) — established by Load File, canonical
# for all nodes going forward:
#   unfilled -> no connection at all (hollow ring only, no fill)
#   grey     -> connection exists (see open question in build_load_file.py
#               re: exact grey-vs-white transition semantics — TBD)
#   white    -> connection exists, idle (no data currently transmitting)
#   yellow   -> connection exists, data actively transmitting
# ============================================================
PORT_GREY_COL   = (0.55, 0.55, 0.58, 1)
PORT_WHITE_COL  = (0.92, 0.92, 0.95, 1)
PORT_YELLOW_COL = (0.95, 0.85, 0.25, 1)

def make_port_ring(name, cx, cy, r, matname, color, tier="controls", thickness=0.018, strength=1.0, coll=None):
    """Hollow ring (outline only, no fill) — used for the 'unfilled / no
    connection' port state. For filled port states, use make_filled with
    circle_points() instead."""
    return make_outline(name, circle_points(cx, cy, r, 24), matname, color, tier,
                         thickness=thickness, strength=strength, cyclic=True, coll=coll)
