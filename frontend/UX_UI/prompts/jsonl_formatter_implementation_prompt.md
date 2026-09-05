Implement the JSONL Formatter node per the finalized UX design. This is a
build task, not a design task — the interaction design is already decided;
your job is correct, working implementation that matches it exactly.

### Required reading, in order, before writing any code

1. `frontend/UX_UI/GLOBAL_UX_CONTRACT.md` — cross-node rules (border
   states, Execute button, Wait/Execute mechanism, port states, status
   row, §7 for dropdown scope). JSONL Formatter follows the full standard
   pattern — no exceptions.
2. `frontend/UX_UI/EXECUTION_MODEL.md` — standard dependency/execution
   rules apply; nothing node-specific here.
3. `frontend/UX_UI/build_jsonl_formatter.py` — the actual UX spec for
   this node, including a resolved naming decision (the first Format Mode
   option's label went through a couple of drafts before landing on its
   final form — see the docstring's note on this, and use the final label
   below, not any intermediate draft).
4. Reuse already-implemented shared components directly: the Execute
   button and status row. The Format Mode dropdown is NOT a shared
   component (see below) — it's an ordinary use of Flutter's standard
   dropdown widget, populated with this node's own data.

Treat these documents as the specification. If something is ambiguous or
seems to conflict with how other parts of this codebase already work, stop
and ask before proceeding.

### This node's specific states (summary — the source of truth is
### build_jsonl_formatter.py, read it in full)

- **Output port** `jsonl` (renamed from `jsonlLines`).
- **No "Waiting for astIndex..." text** — removed entirely, do not re-add.
- **"No index" text**: also removed (a slightly later revision than the
  "Waiting for..." removal — both are gone in the final design; the
  Format Mode field was moved up to close the resulting gap, do not leave
  dead space where either used to be).
- **Format Mode field**: a standard dropdown. CONFIRMED, FINAL complete
  option set:
    - "ChatML Doc" — renamed from "ChatML (Code/Doc)" (this went through a
      couple of drafts — "Conversational Chat" and "Conversational Chat
      (Code/Doc)" were both considered and rejected; "ChatML Doc" is
      final, use exactly this text)
    - "Instruction / Task" — renamed from "Prompt / Completion"
    - "Passthrough" — renamed from "Row Passthrough"
  This is an ordinary Flutter dropdown widget (`DropdownButton`/
  `DropdownButtonFormField` or whatever this codebase's form-field
  convention is) populated with these three options — not a shared
  component with LLM Documenter's Model field, even though both are
  "dropdown fields." Each is independently built with its own data.
- **Wait checkbox, Execute button, status row**: all standard, shared
  components per the Global UX Contract §§2–3, 5, in the standard order.
  Execute is enabled once the input port has data (Format Mode always has
  a value since it's a dropdown with a default — confirm whether an
  explicit user selection is required before Execute enables, or whether
  the default is acceptable as-is, if this app has a convention for that
  distinction elsewhere).
- **Card border, ports**: standard three-state patterns per the Global UX
  Contract §§1, 4.

### Implementation requirements

1. **Backend (Python)** — implement/update this node in the catalog
   registry, following the established general node pattern.

2. **D4M/AA compliance** — per CLAUDE.md: this node's job is reformatting
   an AST index into JSONL per one of three format modes. "Passthrough"
   mode is CONFIRMED to pass the input data into a JSON object WITHOUT
   modification — no AA reshaping, purely a wrapping/serialization step.
   The other two modes ("ChatML Doc" and "Instruction / Task") DO
   restructure the data into a specific chat/instruction format — any such
   reshaping must go through D4M.jl, not a hand-rolled transform.

3. **Frontend (Flutter/`double_vision`)** — implement the widget so it
   faithfully reflects backend-reported state. Reuse the shared Execute
   button and status row. The Format Mode dropdown is a standalone
   Flutter widget, built directly for this node.

4. **Wiring** — "executing" means the formatting operation is genuinely in
   flight; "error" means it genuinely failed with a real error surfaced to
   the user; the output port's "transmitting" state should reflect actual
   data flow, not just "the operation returned."

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

5. **Tests** — add/update tests covering: no input connected (Execute
   disabled), connected (Execute enabled), all three Format Mode options
   producing correct output shape, reactive mode, gated mode, Execute
   click firing + auto-unchecking Wait, manual uncheck-while-gated (both
   cases), Wait locked during execution, successful format (executing →
   success), failed format (executing → error) — following this
   codebase's existing test conventions.

### What NOT to do

- Do not use "Conversational Chat" or "Conversational Chat (Code/Doc)" for
  the first Format Mode option — both were considered and rejected; the
  final label is "ChatML Doc".
- Do not treat the Format Mode dropdown as a shared component with LLM
  Documenter's Model field — they're independently-built uses of the same
  kind of standard widget, not one shared implementation.
- Do not re-add "Waiting for astIndex..." or "No index" text.
- Do not write a second implementation of the Execute button or status
  row — reuse the shared ones.
- Do not let "Passthrough" mode reshape the AA structure in any way — it
  must pass the data into a JSON object unmodified. If an implementation
  approach would require reshaping, that's a sign something's wrong;
  reconsider rather than reshaping anyway.

### Before you start

Confirm you've read all documents listed above and briefly summarize this
node's readiness condition. Wait for my go-ahead before writing code.
