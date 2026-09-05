Implement the Function Extraction node per the finalized UX design. This
is a build task, not a design task — the interaction design is already
decided; your job is correct, working implementation that matches it
exactly.

### Required reading, in order, before writing any code

1. `frontend/UX_UI/GLOBAL_UX_CONTRACT.md` — cross-node rules (border
   states, Execute button, Wait/Execute mechanism, port states, status
   row). Function Extraction follows the full standard pattern — no
   exceptions.
2. `frontend/UX_UI/EXECUTION_MODEL.md` — standard dependency/execution
   rules apply; nothing node-specific here.
3. `frontend/UX_UI/build_function_extraction.py` — the actual UX spec
   for this node (formerly "AST Extract" — see the node rename mapping in
   the Global UX Contract §8). Read the full docstring; this node went
   through several revisions and the docstring documents the FINAL state,
   including what superseded earlier drafts.
4. Reuse already-implemented shared components directly: the Execute
   button and status row. Do not write new implementations of either.

Treat these documents as the specification. If something is ambiguous or
seems to conflict with how other parts of this codebase already work, stop
and ask before proceeding.

### This node's specific states (summary — the source of truth is
### build_function_extraction.py, read it in full)

- **Input port** `codebase` (renamed from `codebasePath`), **output port**
  `functions` (renamed from `astIndex`).
- **No text box at all** — the original reference screenshot's "File or
  Directory" input field was removed entirely. This node has no free-text
  input field of its own; it operates purely on its wired input port.
- **No hint text** — "Wire a Load File node, or type a path" was removed
  entirely (an early draft flagged this copy as possibly stale rather than
  removed; it was later removed outright — do not re-add any form of it).
- **Wait checkbox, Execute button, status row**: all standard, shared
  components per the Global UX Contract §§2–3, 5, in the standard order
  (Wait above Execute, Execute above status row). Execute is enabled once
  the `codebase` input port has data.
- **Card border, ports**: standard three-state patterns per the Global UX
  Contract §§1, 4.

This is one of the simpler nodes in the set — no fields, no dropdowns, no
dynamic ports. Its entire job is: take a wired codebase input, run
function/definition extraction on it, emit the result on `functions`.

### Implementation requirements

1. **Backend (Python)** — implement/update this node in the catalog
   registry, following the established general node pattern from other
   already-implemented nodes.

2. **D4M/AA compliance** — per CLAUDE.md: this node extracts function/
   definition information from source code into an AST index — if that
   result needs to be shaped into an associative array for the
   `functions` output port, that must go through D4M.jl, not a hand-rolled
   transform. The extraction/parsing step itself (walking source code to
   find functions) is not AA algebra and doesn't need to go through
   D4M.jl — only the final AA-shaping does, if applicable. If unsure where
   that line falls, ask.

3. **Frontend (Flutter/`double_vision`)** — implement the widget so it
   faithfully reflects backend-reported state (port states, Wait/Execute/
   status state, border state). Reuse the shared Execute button and status
   row components rather than reimplementing them.

4. **Wiring** — "executing" means extraction is genuinely in flight;
   "error" means it genuinely failed (e.g. unparseable source, empty
   codebase) with a real error surfaced to the user, not a swallowed
   exception; the output port's "transmitting" state should reflect actual
   data flow, not just "extraction finished."

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

5. **Tests** — add/update tests covering: no `codebase` connected (Execute
   disabled), connected (Execute enabled), reactive mode, gated mode,
   Execute click firing + auto-unchecking Wait, manual uncheck-while-gated
   (both "already satisfied" and "not yet satisfied" cases), Wait locked
   during execution, successful extraction (executing → success), failed
   extraction (executing → error) — following this codebase's existing
   test conventions.

### What NOT to do

- Do not re-add a "File or Directory" text input field — this node has no
  free-text input, only its wired port.
- Do not re-add the "Wire a Load File node..." hint text in any form.
- Do not write a second implementation of the Execute button or status
  row — reuse the shared ones.

### Before you start

Confirm you've read all documents listed above, and briefly summarize
back: this node's states, its two ports (`codebase` in, `functions` out),
and which existing shared components (Execute button, status row) you
plan to reuse. Wait for my go-ahead before writing code.
