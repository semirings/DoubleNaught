Implement the Load File node per the finalized UX design. This is a build
task, not a design task — the interaction design is already decided; your
job is correct, working implementation that matches it exactly.

### Required reading, in order, before writing any code

1. `double_vision/UX_UI/GLOBAL_UX_CONTRACT.md` — cross-node rules (border
   states, Execute button, Wait/Execute mechanism, port states, status
   row, URL-field convention, dropdown scope). Load File now has the FULL
   standard pattern — Wait checkbox, Execute button, and status row — same
   as every other node (an earlier design draft had Load File as
   Execute-only; this was revised for full consistency). For this
   root/source node, "required inputs satisfied" (the condition Wait/
   Execute react to) means "a valid URL has been entered," not "an
   upstream port has data" — same mechanism, different readiness
   condition.
2. `double_vision/UX_UI/EXECUTION_MODEL.md` — specifically §1 (root node
   detection). Load File is the canonical example of a root node: zero
   required input ports, so it is always a root regardless of graph shape.
3. `double_vision/UX_UI/build_load_file.py` — the actual UX spec for this
   node. Read the full docstring, not just the geometry — it documents
   every explicit instruction this design went through and any deliberate
   deviations from the original reference screenshot.

Treat these three documents as the specification. Do not invent additional
states, fields, or behavior beyond what they describe, and do not omit
anything they do describe. If something is ambiguous or seems to conflict
with how other parts of this codebase already work, stop and ask before
proceeding.

### This node's specific states (summary — the source of truth is
### build_load_file.py, read it in full)

- **Root node**: no input ports at all. One output port, `parsedPayload`.
- **URL field**: labeled "URL" (renamed from "File Path"), starts EMPTY —
  no placeholder/default value. A small file-dialog icon button sits beside
  it (opens a native file picker).
- **Field validation**: as the user types/selects a URL, validate it
  against the concrete rule in `GLOBAL_UX_CONTRACT.md` §6 — allowed
  schemes are `file`, `http`, `https` ONLY, a scheme is required (a bare
  path with no scheme is invalid, not a valid shorthand), and passing
  Dart's `Uri.tryParse` alone is NOT sufficient (it's too permissive —
  the scheme must additionally be checked against this allow-list).
  Invalid URL shows the field's error state (red outline) plus an
  "Invalid URL" message.
- **IMPORTANT — build this via a shared `IOSupport` class, not inline
  logic**: this node is very likely NOT the only URL-bearing node (Save
  File has an identical URL field and will be implemented next). Per
  `GLOBAL_UX_CONTRACT.md` §6's "Architecture: a shared intermediate class"
  note, URL validation, the URL field widget, and the file-dialog icon
  button must live in a shared `IOSupport` class/mixin sitting between the
  base node class and `LoadFileNode` — on both the backend (Python) and
  frontend (Dart) — rather than being written directly inside Load File's
  own implementation. Build this correctly now: it saves Save File's
  implementation from having to extract/refactor Load File's code later.
- **Wait checkbox**: standard mechanism per Global UX Contract §3.
  Unchecked (reactive) = automatically runs the instant the URL becomes
  valid. Checked (gated) = waits for Execute even once the URL is valid.
  Execute stays enabled based on URL validity alone, independent of Wait's
  state; clicking it fires and auto-unchecks Wait; manually unchecking
  Wait fires immediately if the URL is already valid, otherwise waits and
  fires once it becomes valid.
- **Execute button** (renamed from "Load"): enabled once the URL field
  contains a valid URL — this is the readiness condition Wait reacts to.
- **Status row**: standard idle/running/success/error, shared component.
- **Card border**: normal (grey) by default, executing (white) while the
  node runs, error (red) if execution fails — per the Global UX Contract,
  §1.
- **Output port (`parsedPayload`)**: three states per the Global UX
  Contract §4 — unfilled (no downstream connection), white (connected,
  idle), yellow (connected, actively transmitting data downstream).
- **No "Schema Mode" / Auto-Detect dropdown** — this existed in the
  original reference screenshot and was explicitly removed during design;
  do not re-add it.

### Implementation requirements

1. **Backend (Python)** — implement/update this node in the catalog
   registry per the existing pattern used by other nodes in this codebase.
   Since this may be one of the first nodes implemented under the new
   design system, if there is no existing "root/source node" pattern to
   follow yet, establish a clean one — this node's implementation will
   likely become the reference other source-type nodes (e.g. any future
   node with no required inputs) are built against, so prioritize clarity
   and correctness over speed.

2. **D4M/AA compliance** — per CLAUDE.md: any D4M/AA algebra this node
   performs must use D4M.jl/GraphBLAS, never a hand-rolled reimplementation.
   Load File's job is fundamentally I/O (reading a file into
   `parsedPayload`), so this may not apply directly — but if the parsing
   step constructs or touches an associative array, the same rule applies.
   If unsure, stop and ask rather than guessing.

3. **Frontend (Flutter/`double_vision`)** — implement the widget so it
   faithfully reflects backend-reported state (URL validity, execute
   button enabled/disabled, border state, output port state) — the
   frontend renders backend state, it does not independently decide when
   the node is "valid" or "done" unless that decision is genuinely
   client-side-only (e.g. basic URL format validation before any network
   call is even attempted — reasonable to do client-side for
   responsiveness, but final validity should still be confirmed by
   whatever actually loads the file).

4. **Execute button component** — build this as a SHARED component per the
   Global UX Contract §2, not bespoke to this node. Every other node's
   Execute button (Function Extraction, JSONL Formatter, LLM Documenter,
   D4M, Save File) must use the identical component. If this is the first
   node you're implementing, this is the moment to build that shared
   component correctly — every subsequent node's prompt will tell you to
   reuse it.

5. **Wiring** — "executing" means a file read is genuinely in flight;
   "error" means the read/parse genuinely failed with a real error surfaced
   to the user, not a swallowed exception; the output port's "transmitting"
   state should reflect actual data flow to a connected downstream node,
   not just "execution finished."

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

6. **Tests** — add/update tests covering: empty URL (button disabled),
   invalid URL (error state), valid URL (button enabled), successful load
   (executing → success → port states update), failed load (executing →
   error), reactive mode (auto-fires the instant URL becomes valid), gated
   mode (does NOT auto-fire on valid URL, waits for Execute), Execute
   click firing + auto-unchecking Wait, manually unchecking Wait while
   gated (fires immediately if URL already valid, waits otherwise if not),
   Wait locked during execution — following this codebase's existing test
   conventions.

### What NOT to do

- Do not redesign the interaction — if you think the UX spec has a
  problem, tell me; don't silently "improve" it during implementation.
- Do not add states, fields, or validation rules beyond what
  `build_load_file.py` and the two contract documents describe.
- Do not touch other nodes' code unless this node's change genuinely
  requires it (e.g., introducing the shared Execute button component) —
  and if so, explain why before making the edit.

### Before you start

Confirm you've read all three documents listed above, and briefly
summarize back: this node's states, its one port, and — since this is
likely the first node under the new design system — whether a shared
Execute button component already exists in the codebase or needs to be
created fresh. Wait for my go-ahead before writing code.
