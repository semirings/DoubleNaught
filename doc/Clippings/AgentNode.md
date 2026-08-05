---
title: "AgnetNode"
source: "https://gemini.google.com/app/daaeef8bfa8e67a5?is_sa=1&is_sa=1&android-min-version=301356232&ios-min-version=322.0&campaign_id=bkws&utm_source=sem&utm_medium=paid-media&utm_campaign=bkws&pt=9008&mt=8&ct=p-growth-sem-bkws&gclsrc=aw.ds&gad_source=1&gad_campaignid=20108148196&gbraid=0AAAAApk5BhkcKFCPAYK4hSZxm1eNlnQRi&gclid=Cj0KCQjwp7jOBhDGARIsABe7C4dAOBtocrZYoO-EqkPkC2PT6WFLBTUb2tjLVD4B-V25UjwRpyXoj50aAmCzEALw_wcB"
author:
  - "[[designing the AgentNode this way:]]"
published:
created: 2026-07-21
description: "Gemini conversation with 76 messages"
tags:
  - "clippings"
---
To build an `AgentNode` that works for *all* situations, the core principle is **decoupling the harness execution from the node's domain logic**.

The `AgentNode` itself should be a pure **orchestrator**—it doesn't know *what* it's processing; it only knows how to receive inputs, manage an SLM reasoning loop, call exposed tools, write to memory, and emit outputs.

Here is a complete blueprint for specifying a universal `AgentNode`, defining its ports, internal lifecycle, and Flutter UI representation.

## 1\. The Universal Port Specification

To make the node truly plug-and-play across any workflow, it needs standard, typed ports that abstract away the specifics:

### Input Ports (Ingress)

- **`trigger` (Signal / Stream):** An event port that tells the node to start processing (e.g., button click, incoming upstream data event, or timer tick).
- **`contextIn` (AA / Map):** Background data or history required for reasoning (e.g., current dataset row, D4M state, user preferences, style references).
- **`taskIn` (String / Prompt):** The explicit goal or directive for this run (e.g., *"Segment panels"*, *"Critique prompt"*, *"Index metadata"*).
- **`feedbackIn` (Map / Error):** Routed back from downstream nodes (like a Critic node) containing evaluation scores, correction notes, or retry counts.

### Output Ports (Egress)

- **`resultOut` (AA / Map):** The primary payload generated upon completion (e.g., bounding boxes, synthesized prompts, extracted text).
- **`contextOut` (AA / Map):** Updated memory state ready to pass downstream or loop back to `contextIn` / D4M.
- **`statusOut` (Enum / Event):** System state events emitted during execution (`idle`, `thinking`, `executingTool`, `success`, `failed`).
- **`feedbackOut` (Map):** Error or retry signals sent if the internal validation step fails, ready to route to an upstream node or self-correct.

## 2\. What Happens Inside (The Internal Engine)

Inside the `AgentNode`—running across your Flutter state controller and Python MLX execution backend—a standard 5-stage lifecycle executes when a `trigger` is received:

```
[ Ingress Payload ] ──► (1. Assembly) ──► (2. SLM Inference) ──► (3. Tool Execution)
                                                  ▲                       │
                                                  │ (Iterative ReAct)     ▼
[ Egress Payload ]  ◄── (5. Emission) ◄────────────────────────── (4. Evaluation)
```
1. **Context Assembly:** The harness merges `contextIn`, `taskIn`, and any incoming `feedbackIn` into a structured ReAct prompt template, pulling model configs from its local settings.
2. **SLM Inference (MLX):** Sends the assembled context to the local SLM via IPC. The SLM outputs its next step: either a *Final Answer* or a *Tool Call* request.
3. **Tool Execution:** If the SLM requests a tool call (e.g., `runSAM3`, `readImage`), the harness intercepts the JSON request, executes the corresponding tool function registered to the node, and feeds the output **back to Step 2**.
4. **Internal Evaluation / Guardrail:** The harness checks if the output matches structural schema rules (e.g., valid JSON, required keys present, iteration count 
	$$
	<maxAttempts
	$$
	).
5. **Payload Emission:** Once validated, the result is packaged into an Associative Array format and emitted concurrently through `resultOut`, `contextOut`, and `statusOut`.

## 3\. Flutter UI: Widgets Exposed by the Node

Because this is a universal node canvas block, its Flutter representation needs to balance **high-level clarity** (for zoomed-out canvas views) with **deep inspectability** (when tweaking or debugging).

### On-Canvas Node UI (The Compact Widget)

- **Port Connectors:** Visual sockets on the left (inputs) and right (outputs) showing active connection indicators.
- **Header / Identity Bar:** Dropdown or text field to select/show the assigned SLM target (e.g., `phi4-mccay-spatial.mlx`) and custom node label.
- **Live Status Indicator:** Animated pulse ring or status badge showing current state (`Idle`, `Thinking...`, `Tool Execution`, `Error`).
- **Streaming Thought Box:** A miniature, scrollable text line showing real-time token streaming (*"Analyzing panel 3..."*).
- **Quick Action Controls:** Play/Pause button to trigger or interrupt execution manually, and a step counter (showing active ReAct loops).

### Inspector / Slideout Panel Widgets (Expanded UI)

When clicking or expanding the `AgentNode`, Flutter renders a rich detail view:

- **System Prompt & Hyperparameter Tuning:** Sliders for temperature, max tokens, step limits (TTL), and system instruction overrides.
- **Tool Configuration Matrix:** Toggle switches showing which registered tools this specific node instance is allowed to invoke.
- **Live Step-by-Step Trace Log:** An expandable timeline tree showing:
	- Raw Input context received
		- Intermediate SLM thoughts
		- Tool parameters sent & raw tool results returned
		- Final output schema validation
- **Memory / D4M Binding Inspector:** View live key-value state associated with this node's `contextIn`/`contextOut` streams.

## The Universal Advantage

By designing the `AgentNode` this way:

- You write the **Flutter widget and Python harness code once**.
- To make a "Cataloging Agent", you simply plug a metadata SLM into the node and wire its input to a folder reader.
- To make a "Critique Agent", you plug an evaluator SLM into another instance of the exact same node and wire its output back to the primary generator's `feedbackIn` port.