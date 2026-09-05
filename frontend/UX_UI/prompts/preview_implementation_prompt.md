Implement the Preview node per the finalized UX design. This is a build
task, not a design task — the interaction design is already decided; your
job is correct, working implementation that matches it exactly.

### Required reading, in order, before writing any code

1. `frontend/UX_UI/GLOBAL_UX_CONTRACT.md` — cross-node rules (border
   states, Execute button, Wait/Execute mechanism, port states, status
   row). Preview now follows the standard pattern in full — it is NOT an
   exception (an earlier design draft had it as Wait-checkbox-only with no
   Execute button; this was revised, see build_preview.py's docstring for
   why).
2. `frontend/UX_UI/EXECUTION_MODEL.md` — Preview is a sink node (no
   output port) but otherwise participates in dependency detection like
   any node with a required input.
3. `frontend/UX_UI/build_preview.py` — the actual UX spec for this
   node, including its revision history (a "View" button and mode pills
   existed in v1/v2 and were removed; the checkbox-only v2 design was
   itself superseded by v3, the current final version with the standard
   Wait + Execute + status row).
4. If Load File and/or other nodes have already been implemented, reuse
   their established shared components directly: the Execute button
   component (per Global UX Contract §2) and the status row component (§5)
   should already exist — do not reimplement them for this node.

Treat these documents as the specification. If something is ambiguous or
seems to conflict with how other parts of this codebase already work, stop
and ask before proceeding.

### This node's specific states (summary — the source of truth is
### build_preview.py, read it in full)

- **Sink node**: one input port, `previewData`. No output port.
- **No content-area text at all** when unconnected — no "Connect an AA
  source" placeholder, do not re-add it in any form.
- **No View button, no mode pills** — both existed in earlier drafts and
  were removed; do not resurrect either.
- **Standard Wait checkbox** (label "Wait", capitalized — an earlier draft
  had lowercase "wait," corrected for consistency with every other node):
  unchecked = reactive (fires automatically once `previewData` arrives),
  checked = gated (waits for Execute). Full mechanism, including the
  "clicking Execute auto-unchecks Wait" and "manually unchecking fires
  immediately if data already present, otherwise waits" behavior, is
  specified in the Global UX Contract §3 — this is now identical to every
  other node with a Wait checkbox, no special case.
- **Standard Execute button**: disabled until `previewData` has arrived;
  enabled once it has, regardless of Wait's state. Use the shared Execute
  button component. Clicking it is what actually triggers the preview to
  render/update — this resolves what was previously an open design
  question (with no button, it was unclear what triggered rendering when
  gated; now it's the same mechanism as any other node).
- **Standard status row**: idle/running/success/error, shared component.
- **Input port** (`previewData`): three states per the Global UX Contract
  §4 — unfilled, connected-idle (white), transmitting (yellow).
- **Card border**: normal/executing/error, per the Global UX Contract §1.

### Implementation requirements

1. **Backend (Python)** — implement/update this node in the catalog
   registry, following whatever pattern was established by Load File (or
   other already-implemented nodes) for the general node structure. This
   node's "ready" condition is "previewData is wired and has data,"
   parallel to how any other single-required-input node determines
   readiness.

2. **D4M/AA compliance** — per CLAUDE.md: if rendering the preview requires
   formatting/serializing an associative array for display, that must go
   through D4M.jl, not a hand-rolled formatter. If unsure whether the
   display logic counts as "AA algebra" or is purely presentational, ask
   rather than guessing.

3. **Frontend (Flutter/`double_vision`)** — implement the widget so it
   faithfully reflects backend-reported state (port state, Wait state,
   Execute button state, status row, border state). Reuse the shared
   Execute button and status row components rather than reimplementing
   them for this node specifically.

4. **Panel behavior** — clicking Execute (or the equivalent Wait-uncheck
   path) should render/update the previewed data in whatever display
   surface this app uses for that purpose (e.g. the right-hand panel
   concept established elsewhere, such as in the D4M node's script
   editor — see D4M's docstring in `build_d4m.py` if that's already
   implemented and reusable). If no such shared display surface exists
   yet, ask before building a new one from scratch for this node alone.

5. **Wiring** — "executing" means the preview is actively being generated;
   the input port's "transmitting" state should reflect actual data
   arriving from upstream.

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

6. **Tests** — add/update tests covering: no connection (port unfilled,
   Execute disabled), reactive mode firing on data arrival, gated mode NOT
   firing on arrival, Execute click firing + auto-unchecking Wait, manually
   unchecking Wait while gated (fires immediately if data already present,
   waits otherwise), Wait locked during execution — following this
   codebase's existing test conventions.

### What NOT to do

- Do not re-add the "View" button or the mode pills — both were explicitly
  removed during design.
- Do not treat this node as a special case requiring different
  Wait/Execute logic than any other node — it no longer is one.
- Do not add states beyond what `build_preview.py` and the two contract
  documents describe.
- Do not touch other nodes' code unless this node's change genuinely
  requires it (e.g. reusing a shared component that needs a minor
  extension) — and if so, explain why before making the edit.

### Before you start

Confirm you've read all documents listed above, and briefly summarize
back: this node's states, its one port, and which existing shared
components (Execute button, status row, and — if it exists — a right-hand
display panel) you plan to reuse rather than rebuild. Wait for my
go-ahead before writing code.
