"""
build_all.py — Regenerates NodeUX.blend from every build_<node>.py script.

Run this INSIDE Blender (e.g. via the MCP connection, or Blender's own
Text Editor / `blender --background --python build_all.py`).

What it does:
  1. Runs every build_<node>.py script in this directory, in alphabetical
     order. Each script is self-contained and self-cleaning: it calls
     new_node_collection(name), which removes any existing collection of
     that name before rebuilding it. So re-running this script is always
     safe and idempotent — no separate "reset the whole file" step needed.
  2. Saves the result as NodeUX.blend in this same directory.

NOTE: we deliberately do NOT call bpy.ops.wm.read_homefile() here. Doing so
was tried and removed: (a) it's disruptive to an interactive/live Blender
session connected via MCP — it discards unrelated work-in-progress the user
may have open, and (b) immediately after a read_homefile reset, Blender's
context (selected_editable_objects etc.) does not reliably reflect reality
until a UI redraw cycle happens, which caused the Grease Pencil conversion
step to silently fail ("No editable objects to convert") on the very first
node built after a reset. Relying on each node script's own self-cleanup
avoids this entirely.

If you genuinely want a from-scratch file (e.g. for a true headless CI
regeneration), run this via `blender --background --python build_all.py`
instead — background mode already starts from an empty file, so no explicit
reset is needed there either.

This is the ONLY supported way NodeUX.blend should be produced. If you find
yourself about to edit NodeUX.blend directly in the Blender GUI, stop —
make the change in the relevant build_<node>.py (or in _template.py if it's
shared behavior) and re-run this script instead.
"""

import bpy
import os
import glob
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUTPUT_BLEND = os.path.join(HERE, "NodeUX.blend")

def main():
    if HERE not in sys.path:
        sys.path.insert(0, HERE)

    # Force a fresh import of _template every run. Blender's Python process
    # persists across sessions/tool calls, so a stale cached module (from an
    # earlier run) would otherwise silently shadow real edits made on disk.
    sys.modules.pop("_template", None)

    pattern = os.path.join(HERE, "build_*.py")
    node_scripts = sorted(
        p for p in glob.glob(pattern)
        if os.path.basename(p) != "build_all.py"
    )

    if not node_scripts:
        print("No build_<node>.py scripts found yet — saving NodeUX.blend as-is.")

    for script_path in node_scripts:
        name = os.path.basename(script_path)
        print(f"Running {name} ...")
        with open(script_path, "r") as f:
            code = f.read()
        exec(compile(code, script_path, "exec"), {"__file__": script_path, "__name__": "__main__"})
        print(f"  done: {name}")

    bpy.ops.wm.save_as_mainfile(filepath=OUTPUT_BLEND)
    print(f"Saved: {OUTPUT_BLEND}")


if __name__ == "__main__":
    main()
