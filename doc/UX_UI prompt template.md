Here's a reusable prompt template — fill in the bracketed parts once a given node's Blender mockup is finalized, and hand the whole thing to VSClaude:

```
Implement the [NODE NAME] node per the finalized UX design. This is a build
task, not a design task — the interaction design is already decided; your job
is correct, working implementation that matches it exactly.

### Source of truth for UX/states

The design lives in `blender/nodes/build_[node_name].py` (Grease Pencil mockup
script) — read it before writing any code. It defines:
- The node's states: [list them, e.g. idle, running, success, error]
- What visually changes in each state: [e.g. "outline glows violet during
  running", "status dot turns red + label reads 'error' on failure"]
- Ports: [list, e.g. "codebasePath (in), astIndex (out)"]
- Any button/control behavior: [e.g. "Execute button disabled until input
  port is wired"]

Treat this file as the specification for *when* each visual state should be
active — do not invent additional states or omit any of the ones defined
there. If something in the mockup is ambiguous or seems to conflict with how
existing nodes behave in this codebase, stop and ask me before proceeding.

### Implementation requirements

1. **Backend (Python)** — implement/update the node in the catalog registry
   per the existing pattern used by other nodes in this codebase (find and
   follow the closest existing example, e.g. [name a similar existing node]
   rather than inventing a new structure). Node logic must emit the states
   listed above at the correct lifecycle points (e.g. `running` the moment
   execution starts, `success`/`error` based on actual outcome — not
   optimistic/hardcoded).

2. **D4M/AA compliance** — per CLAUDE.md: any D4M/AA algebra this node
   performs must use D4M.jl/GraphBLAS, never a hand-rolled reimplementation.
   If this node needs an operation neither library provides, stop and ask me
   — do not write a new implementation unprompted.

3. **Frontend (Flutter/`double_vision`)** — implement the widget so it
   reflects backend-reported state changes (port lit/unlit, button
   lit/disabled, status dot color + label, content pill state) — the
   frontend should be a faithful renderer of backend state, not compute or
   infer state itself. The Dart `AA` class may carry data but must not
   perform AA algebra client-side.

4. **Wiring** — connect the visual states to real conditions, not
   placeholders: e.g. "port lit" means the port actually has a bound value
   upstream, "running" means a request is genuinely in flight, "error" means
   the backend call actually failed with a real error surfaced to the UI
   (not a swallowed exception).

5. **Tests** — add/update tests covering each state transition (idle→running,
   running→success, running→error at minimum), following this codebase's
   existing test conventions (check how other nodes are tested first).
   
6. **Cross-node consistency** — this node must look and behave consistent with
   already-implemented nodes, not just match its own mockup in isolation.
   Specifically, before implementing, check how these existing nodes handle
   the same concern and follow their established pattern rather than
   inventing a new one:

   - Button styling/behavior (idle/hover/disabled/lit): match [Node X]
   - Port lit/unlit logic and wiring detection: match [Node Y]
   - Status dot states (idle/running/success/error) and label text: match [Node Z]
   - [Add more rows as shared patterns emerge — e.g. content pill behavior,
     error message formatting, loading/spinner conventions]

   If this node's mockup visually implies a *different* pattern than what's
   already implemented elsewhere (e.g., a differently-styled button, a status
   dot with a state the others don't have), do not silently implement the
   divergence and do not silently force it to match the old pattern either —
   stop and ask me which is correct: is this node intentionally different, or
   did the mockup drift from the established convention?
### What NOT to do

- Do not redesign the interaction — if you think the UX spec itself has a
  problem, tell me; don't silently "improve" it during implementation.
- Do not add states, animations, or visual details beyond what's in the
  mockup script, even if they seem like good ideas — flag suggestions
  separately instead of implementing them.
- Do not touch other nodes' code unless this node's change genuinely requires
  it (e.g., a shared base class) — if so, explain why before making the edit.

### Before you start

Confirm you've read `blender/nodes/build_[node_name].py` and CLAUDE.md, and
briefly summarize back to me: the states you found, the ports, and which
existing node's pattern you plan to follow for the backend implementation.
Wait for my go-ahead before writing code.
```

A few notes on why it's structured this way:

- **The "confirm and summarize before coding" step at the end** mirrors the audit-prompt pattern that worked well earlier — it catches misreadings of the mockup _before_ code gets written, which is much cheaper to fix than after.
- **Point 4 (wiring)** exists because the single most common failure mode in this kind of handoff is a frontend that fakes states cosmetically (e.g., a button that just turns purple on click regardless of whether the backend call actually succeeded) rather than truly reflecting backend reality — worth being explicit about, since a screenshot alone can't convey that requirement.
- It deliberately references your **existing CLAUDE.md rules** rather than restating them, so the two documents stay in sync rather than drifting into two sources of truth.