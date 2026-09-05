Implement the Save File node per the finalized UX design. This is a build
task, not a design task — the interaction design is already decided; your
job is correct, working implementation that matches it exactly.

### Required reading, in order, before writing any code

1. `frontend/UX_UI/GLOBAL_UX_CONTRACT.md` — cross-node rules (border
   states, Execute button, Wait/Execute mechanism, port states, status row,
   URL-field convention including the concrete `file`/`http`/`https`
   validation rule in §6, dropdown scope). Save File follows the full
   standard pattern — no exceptions on this node.
2. `frontend/UX_UI/EXECUTION_MODEL.md` — Save File is a sink node (no
   output port) but otherwise participates in dependency detection like
   any node with a required input.
3. `frontend/UX_UI/build_save_file.py` — the actual UX spec for this
   node, including its revision history (three separate input ports were
   collapsed into one; the URL field briefly had a default example value,
   later removed to match Load File's precedent; a one-off green "Ready to
   save" line was replaced with the standard status row).
4. **URL handling MUST go through `IOSupport`** — a shared intermediate
   class between the base node class and the individual node
   implementation (see Global UX Contract, "Architecture: a shared
   intermediate class" note in §6). `SaveFileNode` should inherit from (or
   compose with) `IOSupport` on the backend, and Save File's Flutter widget
   should use the shared `IOSupport` URL-field widget/mixin on the
   frontend — the same one Load File uses.

   **Before writing any URL-related code, check whether `IOSupport`
   already exists** (Load File should have established it, per Global UX
   Contract §6 and its own implementation prompt). If it exists, extend/
   use it directly — do NOT write a second, separate implementation of URL
   validation, the URL field widget, or the file-dialog icon button, even
   if it would be logically identical to `IOSupport`'s. If `IOSupport`
   does NOT yet exist (e.g. Load File was implemented before this
   architecture was decided), CREATE it now by extracting Load File's
   existing URL logic into it, refactor `LoadFileNode` to use it, and then
   have `SaveFileNode` use it too — do not leave Load File on old inline
   logic while only Save File uses the new shared class.

   The same reuse-first principle (check for an existing shared
   component before writing a new one) applies to the Execute button
   component, the status row component, and the Wait/Execute mechanism
   logic — none of these are `IOSupport`'s concern specifically, but all
   of them are shared-by-design per the Global UX Contract.

Treat these documents as the specification. If something is ambiguous or
seems to conflict with how other parts of this codebase already work, stop
and ask before proceeding.

### This node's specific states (summary — the source of truth is
### build_save_file.py, read it in full)

- **Sink node**: ONE input port, `dataIn` (collapsed from three separate
  ports — `dataToSave`, `textIn`, `imageIn` — in the original reference
  screenshot; do not implement three ports). No output port.
- **URL field**: labeled "URL" (renamed from "File Path..."), starts EMPTY
  — no default/example value. Validated against the exact same rule as
  Load File: allowed schemes `file`, `http`, `https` only, scheme required,
  `Uri.tryParse` alone is not sufficient (see Global UX Contract §6 for
  the full rule and rationale). A small save/browse icon button sits
  beside the field (opens a native file/save dialog) — same pattern as
  Load File's icon button, reuse it rather than rebuilding.
- **Format dropdown**: labeled "Format," closed-list-only per the Global
  UX Contract §7 (no open-state design provided — use the platform's
  standard dropdown widget for the open state). CONFIRMED complete option
  set: **Parquet, CSV, JSON, JSONL, Text, PNG, JPEG.** Default selection:
  Parquet. This list is final — do not add, remove, or reorder options.
- **Wait checkbox**: standard mechanism per Global UX Contract §3.
  Unchecked (reactive) = fires automatically once `dataIn` has data.
  Checked (gated) = waits for Execute. Execute stays enabled based on
  `dataIn` + URL validity + Format selection all being satisfied,
  independent of Wait's state; clicking Execute fires and auto-unchecks
  Wait; manually unchecking Wait fires immediately if already satisfied,
  otherwise waits.
- **Execute button** (renamed from "Save / Export"): enabled once `dataIn`
  has data AND the URL field is valid (Format always has a value since
  it's a dropdown with a default, so it's not itself a blocking condition
  unless the app requires an explicit user selection — confirm this
  assumption if unsure).
- **Status row**: standard idle/running/success/error, shared component
  (replaces an earlier one-off green "Ready to save" text line — do not
  implement a special-cased readiness message for this node).
- **Card border**: normal/executing/error, per the Global UX Contract §1.
- **Input port** (`dataIn`): three states per the Global UX Contract §4 —
  unfilled, connected-idle (white), transmitting (yellow).

### Implementation requirements

1. **Backend (Python)** — implement/update this node in the catalog
   registry, following the established pattern from Load File (or
   whichever node was implemented first) for general node structure. This
   node's readiness condition is a compound one: `dataIn` wired with data
   AND URL valid (AND Format selected, if that's actually a blocking
   condition — confirm).

2. **D4M/AA compliance** — per CLAUDE.md: if writing `dataIn` to disk in
   the selected Format requires any AA-shaping/serialization logic (e.g.
   converting an associative array to Parquet), that must go through
   D4M.jl, not a hand-rolled implementation, per the dependency rules in
   CLAUDE.md. If the required serialization isn't available in D4M.jl,
   stop and ask before writing a new implementation.

3. **Frontend (Flutter/`double_vision`)** — implement the widget so it
   faithfully reflects backend-reported state. Reuse the shared Execute
   button, status row, and (critically, since this is the second
   URL-bearing node) the exact same URL validation and file-dialog icon
   button logic already built for Load File — do not write a second,
   possibly-slightly-different implementation of any of these.

4. **Wiring** — "executing" means a file write is genuinely in flight;
   "error" means the write genuinely failed (e.g. invalid path, disk
   full, permission denied) with a real error surfaced to the user, not a
   swallowed exception; "success" means the write is confirmed complete,
   not just "no exception was thrown."

**Execute/Cancel (added after this prompt was originally written — see
`GLOBAL_UX_CONTRACT.md` §2 for the full spec):** for the full duration of
execution, the Execute button becomes a Cancel button (relabeled "Cancel,"
amber/orange, stop-square icon instead of the arrowhead) via the same
shared `build_execute_button()` component's new `executing` state.
Clicking it while executing must IMMEDIATELY abort the in-flight
operation (hard abort, not a cooperative check-later flag). On completion
or cancellation, the button reverts to its normal Execute
enabled/disabled appearance. Cancellation reverts the node straight to
`idle` status — not a distinct "cancelled" state, not `error`. Wait
unlocks on cancel exactly as it does on normal completion.

**Save File specific requirement:** cancellation must include cleanup —
aborting mid-write can leave a partial/corrupted file on disk. The cancel
path must delete any partially-written output file, not merely stop
writing to it.

5. **Tests** — add/update tests covering: no data connected (Execute
   disabled), data connected but invalid URL (Execute disabled, error
   state), data connected + valid URL (Execute enabled), reactive mode,
   gated mode, Execute click firing + auto-unchecking Wait, manual
   uncheck-while-gated behavior (both the "already satisfied" and "not yet
   satisfied" cases), Wait locked during execution, successful save
   (executing → success), failed save (executing → error) — following
   this codebase's existing test conventions.

### What NOT to do

- Do not implement three separate input ports — confirmed collapsed to one
  (`dataIn`).
- Do not give this node a default/example URL value — confirmed empty by
  default, same as Load File.
- Do not write a second implementation of URL validation, the file-dialog
  icon button, the Execute button, or the status row — reuse what Load
  File (or whichever node came first) already built.
- Do not re-add a one-off "Ready to save" style message — use the
  standard status row.
- Do not invent Format dropdown options beyond "Parquet" without
  confirming the full option set first.

### Before you start

Confirm you've read all documents listed above. Then, specifically: search
the codebase for `IOSupport` (or equivalent), the Execute button
component, and the status row component, and report back EXACTLY what you
found — file paths, and whether `IOSupport` already exists as a proper
shared class both `LoadFileNode` and its Flutter widget use, or whether
Load File's URL logic is still inline and `IOSupport` needs to be created
now (extracting Load File's logic into it as part of this task). Don't
just say "I'll reuse it" — show me what you found. Also briefly summarize
this node's states, its one port, and its compound readiness condition.
Wait for my go-ahead before writing code.
