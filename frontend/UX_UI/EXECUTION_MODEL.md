# Execution Model — DoubleNaught Node Graph

This document specifies how the node graph actually executes — order,
triggering, and validation — as a companion to `GLOBAL_UX_CONTRACT.md`
(which covers per-node visual/behavioral rules). This is graph-level logic,
not any single node's concern, and should be implemented once in the
graph-execution engine, not duplicated per node.

---

## 1. Root Node Detection

A node is a **root** if none of its *required* input ports have an
incoming wire. This is standard in-degree-zero detection, restricted to
required ports:

```
for each node N in the graph:
    N.is_root = all(
        port.is_wired == False
        for port in N.input_ports
        if port.required
    )
```

- Every input port needs a `required: bool` flag in its definition. A node
  with unwired *optional* inputs but wired/satisfied required inputs is
  NOT a root and is not in an error state — it simply doesn't need that
  optional input yet.
- Nodes with zero required input ports at all (Load File, and any future
  node that only generates data rather than transforming it) are trivially
  always roots.
- Canvas X/Y position is NEVER used to determine root status or execution
  order — only the wiring graph matters. (Position is purely a
  human-readability convention, not a mechanism.)

---

## 2. Execution Order

Execution order is the **topological order of the dependency graph**
derived from actual port connections — not canvas position, not creation
order, except as an explicit tie-break (see §3).

---

## 3. Multiple Roots / Ties

When multiple nodes have no unmet required-input dependencies at the same
point in execution:

- **v1 behavior: sequential, deterministic.** Do not run nodes in
  parallel. Use a deterministic tie-break (e.g. top-to-bottom canvas Y, or
  graph-creation order) so the same graph always executes in the same
  order.
- Parallel execution was explicitly deferred as a v2+ consideration — it
  adds real UX complexity (simultaneous running-states, interleaved
  errors/logs) that should be earned once the sequential model is proven,
  not built in from the start.

---

## 4. Cycle Detection

If a subgraph has no nodes with satisfiable required inputs (i.e. a cycle:
A requires B's output, B requires A's output), **Go must refuse to run**
and surface a clear, specific error (e.g. "Cycle detected between Node A
and Node B") rather than silently doing nothing or hanging. This should be
validated before execution starts, not discovered mid-run.

---

## 5. Triggering — How a Node Actually Fires

See `GLOBAL_UX_CONTRACT.md` §3 for the full Wait/Execute mechanism. Summary
for graph-level purposes:

- **Reactive nodes** (Wait unchecked) fire the instant their required
  inputs become satisfied — this can cascade automatically through a chain
  of reactive nodes.
- **Gated nodes** (Wait checked) do not auto-fire on satisfaction — they
  wait for an explicit Execute click (or an equivalent manual uncheck of
  Wait).
- **Any node with cost or an external side effect (paid API calls, LLM
  calls, anything billed) should default to gated (Wait checked) and must
  NEVER fire automatically just because a wire was connected or a value
  changed during graph editing.** This is a hard rule, not a preference —
  informed directly by a real billing incident during this project where
  an unexpected model default caused a large unattended charge. Nothing
  with cost or a side effect runs before an explicit trigger, under any
  circumstance.
- Cheap, local, side-effect-free operations (schema detection, basic
  validation, parsing) may run eagerly during graph editing if it improves
  UX (e.g. validating a URL as the user types) — this is unrelated to the
  Wait/Execute node-firing mechanism and should not be confused with it.

---

## 6. Visual Feedback During Execution

- The currently-executing node shows the `executing` (white) border state
  and, where present, the `running` status-row state.
- Not-yet-reached nodes remain in their idle/normal state.
- Completed nodes show `success` or `error` per their actual outcome.
- A node that cannot yet run because it's missing required input(s) should
  make this diagnosable at a glance via its **port states** (§4 of the
  Global UX Contract) — an unfilled or non-transmitting required port
  tells the user exactly what's blocking that node, without needing to
  click into it.
- For graphs too large to eyeball at once, consider a lightweight global
  progress indicator (e.g. "Step 3 of 7 — Function Extraction") — not yet
  designed visually, flagged here as a future consideration rather than a
  current requirement.

---

## 7. Node-Specific Structural Patterns (for reference)

These are per-node-type mechanics that informed the graph model but are
specific to individual nodes, not global rules:

- **D4M's dynamic input ports:** a single "+" affordance appends the next
  lettered port (A → B → C → ...) below the existing port list. All port
  names are user-editable after creation.
- **D4M's chain-nav arrows** (bottom of the card, "← +" / "+ →"): these
  insert a new sibling D4M node to the left/right in the graph — this is
  NOT a port-management control and should not be confused with the
  add-port "+" above (an earlier design draft conflated these; corrected).

---

## 8. Source of Truth

As with the Global UX Contract, the authoritative detail for any given
node's specific ports, fields, and states is that node's
`build_<node>.py` in this folder. This document covers only the
graph-level mechanics that apply across all of them.
