# Global UX Contract — DoubleNaught Node UI

This document is the single source of truth for behavior and appearance
that is **shared across every node**, distilled from the Blender/Grease
Pencil UX design sessions in this folder (`NodeUX.blend`, `_template.py`,
and each `build_<node>.py`). VSClaude should read this document before
implementing ANY node, and every per-node implementation prompt should
reference it rather than restating these rules.

If a per-node mockup ever appears to contradict this document, the
contradiction should be flagged and resolved — not silently implemented
either way.

---

## 1. Card Border

Every node's card has exactly three border states, identical across all
nodes (see `build_card_border()` in `_template.py`):

| State | Color | When |
|---|---|---|
| Normal | Grey | Default / idle |
| Executing | Pure white (`#FFFFFF`) | While the node is actively running |
| Error | Red | The node failed |

There is no per-node variation on border color or meaning.

---

## 2. Execute Button

Every node that has a primary action button labels it **"Execute"** — no
exceptions, no node-specific verbs (earlier iterations had "Load,"
"Format," "Enrich with LLM," "Save / Export"; all were renamed to
"Execute" specifically so this is uniform).

- **Layout:** label text, then an arrowhead icon to the **right** of the
  label (never the left — an early D4M draft had a left-side play-triangle;
  corrected).
- **States:** `disabled` | `enabled` | `lit` (pressed/active).
- **Enabled condition:** the button becomes enabled the moment all of a
  node's *required* inputs are satisfied (and valid, where a field has
  validation — e.g. Load File's URL). It is NOT gated by the Wait checkbox
  — see §3.
- **Implementation:** built via one shared component
  (`build_execute_button()` in `_template.py`). VSClaude should implement
  this as one shared widget/component in the Flutter codebase, not
  reimplemented per node — the whole point of standardizing this in
  Blender was to prevent the same drift happening again in the app.

**Nodes without an Execute button:** Preview is the one exception — it has
no Execute button by design (see §3), only a Wait checkbox. This is an
intentional per-node variation, not a gap.

---

## 3. Wait Checkbox — Reactive vs. Gated Execution

Nodes that can either fire automatically or wait for an explicit command
have a checkbox labeled **"Wait"**.

### Mechanism (fully resolved — read carefully, this took several rounds
### of clarification and has real edge cases)

- **Unchecked = reactive.** The node fires automatically the instant all
  required inputs are satisfied. If inputs are already satisfied at the
  moment the box becomes unchecked, it fires immediately.
- **Checked = gated.** The node does NOT auto-fire even once its inputs
  are satisfied — it waits.
- **The Execute button (where present) is enabled based on input
  satisfaction alone — it is independent of Wait's checked state.**
  Clicking Execute fires the node immediately and, as a side effect,
  automatically unchecks Wait.
- **Manually unchecking Wait is equivalent to switching to reactive mode**,
  not a special one-shot trigger:
  - If required inputs are ALREADY satisfied at the moment of unchecking,
    the node fires immediately (same visible effect as clicking Execute).
  - If required inputs are NOT yet satisfied, nothing happens yet — the
    node simply becomes reactive and will fire automatically once its
    inputs become satisfied, same as if it had been unchecked all along.
- **Wait is locked/disabled during execution** — it cannot be toggled
  while the node is actively running, regardless of which path triggered
  execution.

### Nodes without an Execute button (Preview)

Preview has only a Wait checkbox, no Execute button. Its only trigger when
checked is manually unchecking it (per the mechanism above — fires
immediately if data has already arrived, otherwise waits and fires once it
does).

---

## 4. Port States

Every input and output port, on every node, has exactly three visual
states:

| State | Appearance | Meaning |
|---|---|---|
| Unfilled | Dim/hollow ring | No connection |
| Connected, idle | White fill | Wired, but no data currently transmitting |
| Transmitting | Yellow fill (brighter/larger) | Data actively flowing through this port right now |

A node that is waiting on data should be identifiable by which of its
input ports are still in the "unfilled" or "connected but not yet
transmitted" state — the user should never have to guess which specific
port is blocking a node from becoming ready.

---

## 5. Status Row

Where present, the status row is a colored dot + text label, one of four
mutually-exclusive states (`build_status_row()` in `_template.py`):

| State | Color | Label |
|---|---|---|
| idle | Grey | "idle" |
| running | Violet | "running" |
| success | Green | "done" |
| error | Red | "error" |

**This must reflect real backend state** — running means a request is
genuinely in flight, success/error reflect the actual outcome, never an
optimistic or hardcoded default. (This mirrors the same caution called out
in the D4M/AA dependency audit prompt: don't fake state cosmetically.)

**Nodes without a status row:** D4M originally had its status row removed,
then re-added later in the design process — current final state is that
D4M DOES have a status row, matching every other node. As of the final
Blender pass, every node in this project has one.

---

## 6. URL-Labeled Fields

Any field labeled "URL" starts **empty** by default — no placeholder or
example value baked in as the initial state (this was explicitly decided
after Load File and Save File were built inconsistently; Save File was
corrected to match Load File's precedent, and this is now the standing
rule for any future URL field).

---

## 7. Pick-List (Dropdown) Fields

Two nodes have a dropdown-style field: LLM Documenter's "Model" and JSONL
Formatter's "Format Mode." Both are built the same way: a box showing the
current value, plus a chevron (▾) indicating it's a picklist.

**Deliberately out of scope for the Blender mockups:** the open/expanded
list view (what appears when the user clicks the dropdown) was NOT
designed pixel-for-pixel in these mockups. This was a deliberate choice —
every node has exactly one card representation in this design system, and
adding a second "open" card layout for picklist nodes would break that
rule. **VSClaude should implement the open list using the platform's
standard dropdown/select widget**, not a custom widget attempting to match
this mockup's exact visual language.

- **JSONL Formatter's Format Mode** has a known, complete set of options:
  - Conversational Chat (renamed from "ChatML")
  - Instruction / Task (renamed from "Prompt / Completion")
  - Passthrough (renamed from "Row Passthrough")
- **LLM Documenter's Model** is, for now, a deliberate **single-item list**
  containing only `mlx-community/Phi-4-mini-instruct`. This is a scope
  decision, not a placeholder oversight — expanding this list requires a
  separate product decision (local model registry? API-sourced? user-
  added?) that has not yet been made. Do not invent additional model
  options.

---

## 8. Node Renames (for reference — already reflected in all mockups)

| Old name | New name |
|---|---|
| AST Extract | Function Extraction |
| Remote Service | LLM Documenter |
| Prompt Node | Prompt |
| SAM3 Control | SAM3 |
| Categories | Categorize |

---

## 9. Source of Truth

The authoritative visual/behavioral spec for each node is its
`build_<node>.py` script in this folder — not `NodeUX.blend` itself (which
is a generated, disposable artifact — see each script's own header comment
for the rule: never hand-edit the `.blend`, always regenerate via
`build_all.py`). When implementing a node, read that node's
`build_<node>.py` docstring in full — it documents every state, every
explicit spec instruction, every open question that was resolved, and any
deliberate deviations from a literal reading of the original reference
screenshot.
