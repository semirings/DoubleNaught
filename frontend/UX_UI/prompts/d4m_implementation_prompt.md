Implement the D4M node per the finalized UX design. This is a build task,
not a design task — the interaction design is already decided; your job is
correct, working implementation that matches it exactly.

### Required reading, in order, before writing any code

1. `frontend/UX_UI/GLOBAL_UX_CONTRACT.md` — cross-node rules (border
   states, Execute button, Wait/Execute mechanism, port states, status
   row). D4M follows the full standard pattern — no exceptions.
2. `frontend/UX_UI/EXECUTION_MODEL.md` — read ALL of it for this node
   specifically, including §7 (node-specific structural patterns), which
   documents D4M's dynamic-port and chain-nav mechanics directly.
3. `frontend/UX_UI/build_d4m.py` — the actual UX spec for this node.
   Read the full docstring, including the REVISION notes — this node went
   through more design iterations than any other (status row was removed
   then re-added; the Execute button had a bespoke left-side icon that was
   replaced with the shared component; several redundant hint texts were
   added then removed). The revision notes tell you what NOT to
   reintroduce, not just what the current state is.
4. If other nodes (Load File, Preview, Save File, etc.) have already been
   implemented, reuse their established shared components directly: the
   Execute button component, the status row component, and — critically
   for this node — whatever shared right-hand display-panel mechanism
   exists (see item 4 in Implementation requirements below).

Treat these documents as the specification. If something is ambiguous or
seems to conflict with how other parts of this codebase already work, stop
and ask before proceeding.

### This node's specific states (summary — the source of truth is
### build_d4m.py, read it in full)

- **Multiple input ports, dynamically addable**: starts with one port
  (`A`). A single "+" affordance (NOT the confusing multi-affordance setup
  in the original reference screenshot, which had a stray duplicate "A"
  and a separate "+  +" row that were consolidated into ONE "+") appends
  the next lettered port below the existing list: A → B → C → ... All port
  names are user-editable after creation (the rename UI itself isn't
  specified here — implement a reasonable inline-rename affordance
  consistent with how port renaming works elsewhere in this app, if such a
  pattern already exists; ask if it doesn't).
- **One output port**, labeled `Out` (renamed from `evaluatedResult`).
- **Script text area**: a real code-editing surface, not a static text
  box. Must show scrollbar chrome when content overflows (do not omit
  scrolling just because the mockup shows a static scrollbar graphic — it
  needs to actually scroll). Double-clicking it opens the FULL editor in
  this app's right-hand display panel — see item 4 below, this is the
  node's most significant implementation requirement.
- **"Out:" field**: a text field where the user names the output binding
  (separate from the `Out` port label itself — this field lets the user
  choose what variable name inside their D4M script the port's value binds
  to). Default/placeholder value shown in the mockup is "Out."
- **Chain-nav arrows** (bottom of card, "← +" and "+ →"): clicking either
  inserts a NEW sibling D4M node immediately to the left/right of this one
  in the graph. This is NOT related to port management — do not wire these
  to the add-port "+" logic, they are a distinct feature (insert a new
  node into the graph, pre-populated as a fresh D4M node).
- **Wait checkbox, Execute button, status row**: all standard, shared
  components per the Global UX Contract §§2–3, 5. Execute is enabled once
  input port `A` (and any additional ports the user has added) are
  satisfied per this node's own readiness logic — ask if it's unclear
  whether ALL added ports must be satisfied or just the originally-present
  one(s) before Execute becomes enabled.
- **Card border, input/output ports**: standard three-state patterns per
  the Global UX Contract §§1, 4.

### Implementation requirements

1. **Backend (Python)** — implement/update this node in the catalog
   registry. Dynamic port addition needs real backend support (the node's
   schema/port list isn't fixed at definition time). Check whether an
   existing pattern for variable-arity/dynamic-port nodes already exists
   in this codebase and follow it if so; if this is genuinely the first
   node with dynamic ports, say so plainly and proceed with a clean
   implementation rather than treating it as blocked — this is a real but
   ordinary implementation task, not an open design question.

2. **D4M/AA compliance** — per CLAUDE.md: this node's entire purpose is
   running D4M scripts against associative arrays, so this is the most
   D4M/AA-relevant node in the whole set. ALL algebraic operations the
   script performs must go through D4M.jl / GraphBLAS — this node is
   essentially a UI wrapper around D4M.jl execution, not a place to
   reimplement any AA semantics. If the script execution sandbox/runtime
   doesn't already exist, ask before building one from scratch — this is
   a substantial piece of infrastructure, not a small implementation
   detail.

3. **Frontend (Flutter/`double_vision`)** — implement the widget so it
   faithfully reflects backend-reported state (port states — plural, for
   however many ports currently exist — Wait/Execute/status state, border
   state). The script text area needs real text-editing capability
   (selection, scrolling, syntax awareness if that's part of this app's
   existing editor conventions — check for one before deciding).

4. **Right-hand display panel** — this already exists in the app.
   Double-clicking the script box opens the full editor in it. Use the
   existing panel directly; do not build a new one.

5. **Bidirectional sync** — also already implemented. The inline script
   box and the full editor in the right-hand panel already stay in sync
   live. Use the existing mechanism; do not build a new one.

6. **Wiring** — "executing" means the D4M script is genuinely running;
   port "transmitting" states should reflect actual data flow, not just
   "the node finished."

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

7. **Tests** — add/update tests covering: dynamic port addition (adding a
   port, correct auto-naming A→B→C, port rename), the chain-nav arrows
   (inserting a sibling node, confirming it's genuinely independent of
   port logic), script execution success/failure, Wait/Execute mechanism
   (reactive, gated, manual uncheck, click-to-fire, locked during
   execution), bidirectional script sync — following this codebase's
   existing test conventions.

### What NOT to do

- Do not reintroduce anything the docstring's REVISION notes say was
  removed: the bespoke left-side play-icon Execute button, the "no status
  row" behavior, the redundant "add port" hint text, or the
  "double-click to expand..." caption line.
- Do not conflate the add-port "+" with the chain-nav arrows — they are
  unrelated features that happen to both use "+" glyphs.
- Do not write a second implementation of the Execute button, status row,
  right-hand display panel, or bidirectional sync mechanism — all of these
  already exist in this app; reuse them.

### Before you start

Confirm you've read all documents listed above, including the REVISION
notes in `build_d4m.py`'s docstring. Then report back: (1) whether an
existing pattern for variable-arity/dynamic-port nodes already exists in
this codebase (and if so, where), and (2) which existing shared components
you plan to reuse (Execute button, status row, the right-hand display
panel, the bidirectional sync mechanism — the last two already exist in
this app, use them directly). Wait for my go-ahead before writing code.
