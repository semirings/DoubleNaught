Implement the LLM Documenter node per the finalized UX design. This is a
build task, not a design task — the interaction design is already decided;
your job is correct, working implementation that matches it exactly.

### Required reading, in order, before writing any code

1. `double_vision/UX_UI/GLOBAL_UX_CONTRACT.md` — cross-node rules (border
   states, Execute button, Wait/Execute mechanism, port states, status row,
   §7 specifically for this node's Model dropdown scope decision).
   LLM Documenter follows the full standard pattern — no exceptions.
2. `double_vision/UX_UI/EXECUTION_MODEL.md` — standard dependency/execution
   rules apply; nothing node-specific here.
3. `double_vision/UX_UI/build_llm_documenter.py` — the actual UX spec for
   this node, including the resolved-open-questions section (Model
   dropdown scope, why the open dropdown state isn't designed in Blender).
4. Check what's already implemented in other nodes (Load File, Save File,
   D4M, etc.) and reuse directly: the Execute button component, the status
   row component, and the Wait/Execute mechanism logic. Do not write new
   implementations of any of these — they already exist.

Treat these documents as the specification. If something is ambiguous or
seems to conflict with how other parts of this codebase already work, stop
and ask before proceeding.

### This node's specific states (summary — the source of truth is
### build_llm_documenter.py, read it in full)

- **Input port** `astIndex`, **output port** `documented` (renamed from
  `enrichedIndex`).
- **No "Waiting for astIndex..." text** — removed entirely, do not re-add.
- **Model field**: relabeled from "Model ID" to "Model", changed from free
  text to a PICK LIST (dropdown, chevron indicator). CONFIRMED complete
  option set for now: a single item, `mlx-community/Phi-4-mini-instruct`.
  This is a deliberate scope decision, not a placeholder — do not add
  additional model options; if a broader model-source mechanism (local
  registry, API-populated list, user-added models) is wanted, that's a
  separate future decision, not part of this task.
- **Open dropdown state**: use Flutter's standard dropdown widget (e.g.
  `DropdownButton`/`DropdownButtonFormField`, whichever fits this
  codebase's existing form-field conventions) for the open-list
  interaction — this is an ordinary widget, not a bespoke shared
  component. This mockup deliberately did not design a custom open-state
  visual (see Global UX Contract §7); no custom dropdown widget needs to
  be built or found. Simply populate the standard widget with this node's
  specific option list (the single confirmed model ID, below).
- **Max Tokens / Temperature fields**: plain text inputs, unchanged from
  the original reference — not pick lists, no relabeling.
- **Wait checkbox, Execute button, status row**: all standard, shared
  components per the Global UX Contract §§2–3, 5, positioned in the
  standard order (Wait above Execute, Execute above status row, both
  below all other widgets). Execute is enabled once `astIndex` has data
  and the Model/Max Tokens/Temperature fields are all in a valid state.
- **Card border, ports**: standard three-state patterns per the Global UX
  Contract §§1, 4.

### Implementation requirements

1. **Backend (Python)** — implement/update this node in the catalog
   registry, following the established general node pattern from
   already-implemented nodes.

2. **D4M/AA compliance** — per CLAUDE.md: this node calls an LLM to enrich
   an AST index into documentation — the LLM call itself is not D4M/AA
   algebra, but if the enrichment result needs to be reshaped back into an
   associative array for the `documented` output port, that reshaping must
   go through D4M.jl, not a hand-rolled transform. If unsure whether a
   given step counts as "AA algebra," ask rather than guessing.

3. **Frontend (Flutter/`double_vision`)** — implement the widget so it
   faithfully reflects backend-reported state. Reuse the shared Execute
   button and status row components. The Model dropdown itself is just
   Flutter's standard dropdown widget populated with this node's own
   data — no shared component to reuse or build for the dropdown itself.

4. **Model list source** — for now, hardcode the single confirmed model
   ID (`mlx-community/Phi-4-mini-instruct`) as the only selectable option.
   Do not build any dynamic model-discovery mechanism (scanning a local
   directory, calling an API, etc.) — that's explicitly out of scope per
   the Global UX Contract §7.

5. **Wiring** — "executing" means the LLM call is genuinely in flight;
   "error" means the call genuinely failed (timeout, model unavailable,
   malformed response) with a real error surfaced to the user, not a
   swallowed exception; the output port's "transmitting" state should
   reflect actual data flow, not just "the call returned."

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

6. **Tests** — add/update tests covering: no `astIndex` connected (Execute
   disabled), connected + valid fields (Execute enabled), reactive mode,
   gated mode, Execute click firing + auto-unchecking Wait, manual
   uncheck-while-gated (both "already satisfied" and "not yet satisfied"
   cases), Wait locked during execution, successful enrichment (executing
   → success), failed call (executing → error) — following this
   codebase's existing test conventions.

### What NOT to do

- Do not add additional Model options beyond the single confirmed item.
- Do not build a custom dropdown widget to match this mockup's exact
  visual style for the open-list state — use Flutter's standard dropdown
  widget directly.
- Do not turn Max Tokens or Temperature into pick lists — they stay plain
  text inputs.
- Do not write a second implementation of the Execute button or status
  row — reuse the shared ones.
- Do not re-add the "Waiting for astIndex..." text.

### Before you start

Confirm you've read all documents listed above. Then report back: which
existing shared components you plan to reuse (Execute button, status row)
and confirm this node's readiness condition (what "Execute enabled"
actually requires). Wait for my go-ahead before writing code.
