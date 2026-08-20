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
- **States:** `disabled` | `enabled` | `lit` (brief press flash) |
  `executing` (see below).
- **Enabled condition:** the button becomes enabled the moment all of a
  node's *required* inputs are satisfied (and valid, where a field has
  validation — e.g. Load File's URL). It is NOT gated by the Wait checkbox
  — see §3.
- **Executing = Cancel.** For the FULL DURATION of execution, the Execute
  button becomes a **Cancel** button: relabeled "Cancel," amber/orange
  fill (deliberately NOT the same red as the error state — cancelling
  should never visually read as "something failed"), and the arrowhead
  icon replaced with a stop-square. Clicking it while in this state
  **immediately aborts the in-flight operation** (hard abort, not a
  cooperative/best-effort flag the operation checks later). On completion
  OR cancellation, the button reverts to its normal Execute
  appearance/label (`enabled` or `disabled`, per the node's current
  readiness).
  - **Wait unlocks on cancel**, exactly as it does on normal completion —
    the lock exists because execution is in flight; cancellation ends
    that condition the same way finishing does.
  - **Cancellation does not produce a distinct status.** It reverts
    straight to `idle` (§5) — not a fifth "cancelled" status, and not
    `error`. The user changed their mind; nothing failed.
  - **Save File specifically must treat cancellation as requiring
    cleanup**, not just a stop: aborting mid-write can leave a partial/
    corrupted file on disk. Save File's cancel path must delete any
    partially-written output file, not merely halt the write.
- **Implementation:** built via one shared component
  (`build_execute_button()` in `_template.py`, now returning `disabled` /
  `enabled` / `lit` / `executing` states). VSClaude should implement this
  as one shared widget/component in the Flutter codebase, not
  reimplemented per node — the whole point of standardizing this in
  Blender was to prevent the same drift happening again in the app.

**Nodes without an Execute button:** Load File is the one exception — it's
a root/source node with no upstream data to wait on, so it has an Execute
button but no Wait checkbox at all (the Wait/Execute distinction is about
reacting to upstream data, which doesn't apply to a node with nothing
upstream). Every other node, including Preview (see revision history in
`build_preview.py`), has both.

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

### No remaining exceptions — every node has Wait + Execute + status row

Earlier design drafts had two asymmetric nodes: Load File (Execute, no
Wait) and Preview (Wait, no Execute). Both were resolved — every node in
this project now has the identical Wait checkbox + Execute button + status
row, using the same shared mechanism and the same shared components.

For root/source nodes like Load File, which have no upstream port to
react to, the mechanism generalizes cleanly: "required inputs satisfied"
means the node's own readiness condition (e.g. "a valid URL has been
entered") rather than "an upstream port has data." The underlying
reactive/gated behavior, and the Execute-click / manual-uncheck triggers,
are otherwise identical to every other node. See `build_load_file.py` and
`build_preview.py` docstrings for the full resolution history of each.

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

### Validation rule (applies to every "URL" field — Load File, Save File,
### and any future node with a URL-labeled field)

**Allowed schemes: `file`, `http`, `https` — and only these three.**

- `git`, `ftp`, `ssh`, and any invented/non-standard scheme (an earlier
  draft of this spec incorrectly considered `storage://` — this is NOT a
  real registered URI scheme and must not be treated as one) are all
  INVALID.
- **A scheme is required.** A bare/schemeless relative path (e.g. the
  literal string `storage/out/export`, which appeared as example text in
  early reference screenshots before URL fields were changed to start
  empty) is INVALID input, not a fourth accepted case. If a value has no
  `scheme://` prefix at all, treat it the same as any other malformed
  input — show the field's error state.
- **Do not rely on a generic/permissive parser alone** (e.g. Dart's
  `Uri.tryParse`, which accepts almost any non-empty string, including
  ones with spaces or stray characters, as long as it's not egregiously
  malformed) to implement this. `Uri.tryParse` succeeding is NOT sufficient
  to mark the field valid — the scheme must additionally be checked against
  the `file`/`http`/`https` allow-list above. A value can pass
  `Uri.tryParse` and still be invalid per this rule if its scheme is
  missing or not in the allow-list.
- **Why no "resolve bare paths against an app storage root" exception:**
  this was considered and deliberately rejected. The file-dialog icon
  button beside every URL field (see §2 of each node's build script)
  always produces a proper absolute `file://` URL when the user picks a
  file — so there is never a legitimate path by which a bare/relative path
  needs to be accepted. The only way a bare path reaches this field is the
  user typing it directly, which is exactly the malformed-input case that
  should show the error state. Keep the rule simple: a valid URL with an
  allowed scheme is required, full stop.

### Architecture: a shared intermediate class, not just a shared function

Any node with a URL-labeled field (currently Load File and Save File; any
future URL-bearing node too) MUST implement URL handling via a shared
intermediate class — **`IOSupport`** — sitting between the base node class
and the individual node implementation, on BOTH the backend and the
frontend:

- **Backend (Python):** `LoadFileNode` and `SaveFileNode` inherit from (or
  compose with) `IOSupport`, which owns the scheme allow-list validation
  logic (§6 above) and, as the app grows, is the natural home for shared
  scheme-based read/write dispatch (`file://` → local filesystem,
  `http(s)://` → network) rather than each node reimplementing dispatch
  separately.
- **Frontend (Dart/`double_vision`):** the URL field itself — text input,
  the file-dialog icon button, the error display, the validation-triggered
  UI state — should be a shared widget/mixin used by both nodes' widgets,
  not two independently-built field implementations that happen to look
  the same.

This is a stronger guard than "write a shared function and remember to
call it from both places": a class in the hierarchy makes reuse the only
path, rather than something that has to be remembered and can silently
stop happening if a node is implemented in a separate session that doesn't
know to look for it. If `LoadFileNode` was already implemented without
`IOSupport` before this was decided, extract its URL logic into
`IOSupport` and have `LoadFileNode` use it too — do not leave one node on
the old pattern and only the new node on `IOSupport`.

**Naming is final: `IOSupport`.** Chosen over the narrower `URISupport`
since it leaves room for shared read/write dispatch, not just string
validation, given this app's Load/Save duality. Use `IOSupport`
consistently everywhere — class name, file name, import references. Do
not use `URISupport` anywhere in the codebase.

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
- **Save File's "Format"** has a known, complete set of options (confirmed
  against the actual running implementation, not just the original
  mockup): **Parquet, CSV, JSON, JSONL, Text, PNG, JPEG.** Default
  selection is Parquet.

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
