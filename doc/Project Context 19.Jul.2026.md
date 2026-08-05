
# Project Context Document

## For: Claude (new session continuity)

## Project Owner: gcr (geoffry.roberts@gmail.com)

## Last Updated: July 2026

---

## 1. THE VISION

You are helping build a **McCay-style animated motion comic pipeline**. The end goal is a complete production system that generates animated sequences in the style of Winsor McCay's _Little Nemo in Slumberland_ (early 1900s newspaper comic), with narration, and eventual Blender-based animation.

The full pipeline:

```
Narrative script
  → panel prompts (Claude) → MCCAY LoRA inference → images
  → Blender Grease Pencil → rigging → animation
  → ElevenLabs narration
  → final composed output
```

---

## 2. THE PROJECTS

There are three codebases. **Claude (VS Code) wrote all of them.**

### DoubleNaught (DN)

- **Purpose**: General-purpose workflow orchestration tool using a node-and-noodle (N&N) graph — think ComfyUI but without the quirks, and not image-specific
- **Frontend**: Flutter
- **Backend**: FastAPI
- **Data structure**: D4M/AA (see Section 4)
- **Philosophy**: Unix — each node does one thing well. Multiple SLMs pipe to one another.
- **Status**: Phase 1 (N&N infrastructure) is complete. New nodes are being added.

### mlx-sam

- **Purpose**: Step-through wizard (not N&N) for creating a LoRA and running inference
- **Runs on**: Apple Silicon via MLX
- **Status**: Handles the image pipeline (Phase 2). Output feeds into DN.
- **Base model**: Currently SD 1.5 via PytorchSd15Provider. SDXL or Flux upgrade is under consideration.

### The McCay LoRA

- **Trigger token**: `MCCAY`
- **Training data**: 396 pages of high-quality Winsor McCay artwork (_Little Nemo in Slumberland_)
- **Training approach**: mlx-sam wizard
- **Current issue**: Word balloon removal needed before panels are clean training data
- **Inference**: Supports image-to-image (img2img), which enables panel sequence continuity chains

---

## 3. THE IMAGE PIPELINE (Phase 2)

### Training data

- 396 pages of McCay artwork, excellent quality
- Can isolate: full pages, individual panels, color palette
- **Pending**: Word balloon removal

### Word balloon removal approach

- Use SAM3 (already in pipeline) to segment/mask word balloons
- Inpaint masked regions using Lama-Cleaner or diffusion inpainting
- SAM3 prompt: "speech bubble" or "word balloon"

### SAM3

- Meta's Segment Anything Model 3 (November 2025)
- Uses Meta's Perception Encoder backbone (not CLIP — that was SAM2)
- Already integrated into the workflow

### Sequence continuity for generated panels

- img2img: feed previous panel as source for next panel
- Key parameter: denoising strength (lower = more continuity, higher = more change)
- Risk: accumulated drift over multiple panels
- Mitigation: IP-Adapter for feature-level character/style anchoring
- IP-Adapter has SD 1.5 weights; also available for SDXL

### SDXL/Flux upgrade consideration

- SD 1.5 is a quality ceiling — native 512px, older architecture
- SDXL: native 1024px, better color coherence, better architectural detail — important for McCay
- Flux: newer than SDXL, meaningfully better quality, strong LoRA support
- CloudRunProvider handles the extra resource requirements
- Decision pending — leaning toward SDXL or Flux before retraining LoRA

### Blender integration

- Generated panels → Blender Grease Pencil → rigging → animation
- Claude has Blender MCP tools (can script GP import, stroke generation, armature setup)
- Vectorization step needed between inference output and Blender (raster → GP strokes)
- Historically fitting: McCay invented animation with _Gertie the Dinosaur_

---

## 4. D4M/AA — THE DATA STRUCTURE

**D4M** = Dynamic Distributed Dimensional Data Model  
**AA** = Associative Array (treated as a sparse matrix, not just a dictionary)

### Core concept

- Rows: string keys (node IDs, document IDs, payload IDs)
- Columns: string attribute names
- Values: numbers or strings
- Supports matrix math: A + B, A * B, transpose

### Why it matters for DN

- Graph operations become linear algebra
- Pipeline state is a matrix traversal problem
- Routing logic is matrix multiplication, not conditional branching
- Co-occurrence and correlation via matrix multiply

### Orchestration AA (to be built by VS Code Claude)

DN currently lacks pipeline state tracking. Two AAs needed:

**Orchestration AA:**

```
Rows:    payloadIDs
Columns: nodeID|timestamp
Values:  iteration_count
```

**Pipeline AA (adjacency matrix of the node graph):**

```
Rows:    nodeIDs
Columns: nodeIDs
Values:  edge weight (active/inactive)
```

Multiplying a payload's state vector against the Pipeline AA returns where it can go next. Adding a new node = adding a row and column, not rewriting routing code.

---

## 5. THE VOICE SLM (Phase 3 — Current Focus)

### The concept

A fine-tuned Small Language Model that reliably produces a specific hybrid literary voice. The voice has two layers:

**Layer 1: ESL Literalism**

- ESL speakers bypass tired English idioms and construct phrases that are vivid, literal, and raw
- They see the actual thing rather than filtering through convention
- Example: "traffics" as a countable plural — not wrong, _more right_
- This is the primitive, physical layer — unmediated perception

**Layer 2: GCC Register (Gilbert, Chesterton, Churchill)**

- **W.S. Gilbert**: Comic precision, absurdist logic pursued with complete seriousness, internal rhyme, verbal dexterity. The humor comes from total deadpan sincerity. Example: "I have a constituency I'm not using. Would you like to go to parliament?" — the fairy queen sees no contradiction whatsoever.
- **G.K. Chesterton**: Paradox, the ordinary made cosmically strange, aphorism, Catholic mysticism, essays especially
- **Winston Churchill**: Grand periodic sentences, parallel constructions building to climactic close, concrete image carrying abstract weight, written for the spoken voice

### Why this combination works for McCay

- Nemo's experience IS ESL experience — he encounters the world without the buffer of habituation
- Everything is literal, physical, immediate (a staircase that grows is not metaphor, it simply grows)
- The Churchill/Gilbert frame gives raw experience its formal dignity
- McCay authority figures (heralds, officials) speak with institutional gravity about completely dream-logical things — pure Gilbert

### Two distinct narrative gears available

1. **Churchillian sublime** — for the dream's grandeur, architectural enormity
2. **Gilbertian bureaucratic** — for absurdist dream logic, institutional procedures applied to impossible situations

### The RSI loop for ESL refinement

This is where genuine recursive self-improvement enters the project:

```
SLM generates passage
  → extract ESL-primitive layer
  → modify/intensify the literalism
  → resubmit to SLM as training example
  → SLM output shifts toward that register
  → repeat
```

The user is the aesthetic filter — the human who knows the difference between vivid literalism and mere awkwardness. That judgment is the fitness function. Cannot be automated.

### Base model for fine-tuning

- **Phi-4** (recommended) — strong English base, fine-tunes well, runs on Apple Silicon via MLX
- Alternative: Llama 3.2 3B
- Fine-tuning uses LoRA — same technique as the image pipeline

### ElevenLabs

- Planned for narration (not dialog — dialog is set aside for now)
- The Churchill/Gilbert register performs well in TTS — periodic sentences have natural cadence
- ElevenLabs has an API — narration generation can be automated as a DN node

---

## 6. THE GCC CORPUS PIPELINE (Being Built Now)

The node graph for building the Phi-4 training corpus from Project Gutenberg sources:

```
[InventoryNode] → [URLNode] → [FetchNode] → [ChunkNode] → [ReviewNode] → [AA2JSONLNode]
```

### Node specifications (prompts written, ready for VS Code Claude)

**InventoryNode** ✓ prompt written

- Source node, no upstream input
- Maintains persistent list of URL entries as D4M/AA
- Flutter UI: scrollable list with Add/Edit/Delete/Select actions
- Pre-populated with four Gilbert & Sullivan operas (same URL, different work_selectors)
- General purpose — not GCC-specific

Pre-populated entries:

```
URL: https://www.gutenberg.org/files/808/808-h/808-h.htm
gilbert | HMS Pinafore        | work_selector: H.M.S. PINAFORE
gilbert | The Pirates of Penzance | work_selector: THE PIRATES OF PENZANCE
gilbert | Iolanthe            | work_selector: IOLANTHE; OR, THE PEER AND THE PERI
gilbert | The Mikado          | work_selector: THE MIKADO; OR, THE TOWN OF TITIPU
```

**URLNode** ✓ prompt written + correction prompt written

- Receives selection from InventoryNode (no longer requires manual re-entry)
- Displays incoming entry for confirmation
- Output AA: url | author | work_title | work_selector | validated | timestamp
- NOTE: work_selector field was added to support multi-work files — verify this is implemented

**FetchNode** ✓ prompt written

- Async HTTP fetch of URL content
- Strips Gutenberg boilerplate using START/END markers
- General purpose — works for any URL, not just Gutenberg
- Boilerplate stripping only triggers when Gutenberg markers detected
- Output AA: raw_text | author | work_title | char_count | fetch_timestamp

**ChunkNode** ✓ prompt written

- Author-aware chunking strategy (selected by author tag):
    - gilbert: split on song/scene/exchange boundaries, preserve complete exchanges
    - chesterton: split on paragraph boundaries, preserve complete sentences
    - churchill: split on periodic sentence clusters, preserve complete builds
- Secondary constraint: min 50 tokens, max 300 tokens per chunk
- For gilbert: uses work_selector to locate correct play within multi-work file
- Architected for additional strategies to be added without restructuring
- Output AA: text | author | work_title | position | token_count | chunk_strategy

**ReviewNode** ✓ prompt written

- Human-in-the-loop curation
- Presents passages one at a time: Approve / Edit / Reject
- Persists state between sessions (review can be paused and resumed)
- Keyboard shortcuts for fast review
- Output AA: text | original_text | author | work_title | position | token_count | review_status | edit_flag | review_timestamp
- Only approved and edited passages flow downstream
- General purpose — works for any D4M/AA payload with a text column

**AA2JSONLNode** ✓ prompt written

- Converts D4M/AA payload to Phi-4 ready JSONL file
- Two format options:
    - instruction-completion: {"prompt": "Write in the GCC voice:", "completion": "<text>"}
    - continuation: {"text": "<text>"}
- Preserves full provenance chain via chunkID
- General purpose — works for any well-formed AA with a text column
- Output AA: jsonl_line | format | output_file | write_timestamp | status

### Pending: Chesterton and Churchill Gutenberg URLs

Not yet sourced. Need to find equivalent single-volume or best available sources. Add to InventoryNode once found.

---

## 7. BUILD SEQUENCE

**Phase 1** — DN N&N infrastructure ✓ COMPLETE

**Phase 2** — Image pipeline

- mlx-sam wizard handles LoRA training and inference ✓ EXISTS
- Pending: word balloon removal pipeline (SAM3 → inpainting)
- Pending: SDXL or Flux upgrade decision
- Pending: panel extraction from pages

**Phase 3** — Voice SLM (CURRENT FOCUS)

- GCC corpus pipeline nodes: prompts written, ready for VS Code Claude
- Pending: Orchestration AA in DN (VS Code Claude)
- Pending: Phi-4 fine-tune node in DN (VS Code Claude)
- Pending: RSI loop node in DN — cyclic graph with human curation node
- Pending: ESL primitive corpus generation (this Claude, in conversation)
- Pending: Chesterton and Churchill Gutenberg URLs

**Phase 4** — Coupling

- Voice SLM → panel prompt node
- img2img continuity chain
- Narrative script drives panel prompts

**Phase 5** — Output

- Blender GP import node
- ElevenLabs narration node
- Final composition

---

## 8. KEY ARCHITECTURAL DECISIONS AND REASONING

- **N&N over linear pipeline**: Composability, reusability, visual clarity
- **D4M/AA over JSON**: Matrix operations replace loops; graph traversal is linear algebra; scales to distributed backends
- **Multiple specialized SLMs over one general SLM**: Unix philosophy; each does one thing well; swap individual nodes without affecting others
- **Text before images in sequence generation**: Narrative logic drives visual logic in McCay; images follow from dream-logic events, not the reverse
- **InventoryNode over embedded URL storage in URLNode**: URLNode stays focused; InventoryNode is a reusable DN primitive
- **Author-aware chunking**: Voice is in the complete unit; naive token splitting destroys rhythm and humor
- **Human in the RSI loop**: User is the aesthetic fitness function; ESL vividness vs. mere awkwardness cannot be automated

---

## 9. TECHNICAL ENVIRONMENT

- **Hardware**: Apple Silicon Mac
- **Local inference**: MLX (mlx-lm for SLMs, mlx for image models)
- **Cloud inference**: CloudRunProvider (Google Cloud Run) — handles SDXL/Flux resource requirements
- **Image inference providers**: MlxLocalProvider, CloudRunProvider, PytorchSd15Provider
- **Claude access**: VS Code Claude (has codebase access), Cowork/chat Claude (architectural and creative direction)
- **Division of labor**: VS Code Claude builds code; chat Claude handles architecture, creative direction, prompt writing, corpus generation

---

## 10. IMMEDIATE NEXT ACTIONS

For **VS Code Claude**:

1. Implement Orchestration AA and Pipeline AA in DN backend
2. Implement InventoryNode
3. Implement URLNode (with work_selector support — verify existing implementation)
4. Implement FetchNode
5. Implement ChunkNode
6. Implement ReviewNode
7. Implement AA2JSONLNode
8. Implement Phi-4 fine-tune node
9. Implement RSI loop node (cyclic graph with human curation node)

For **chat Claude** (this conversation or next):

1. Find Chesterton Gutenberg URLs — best essay collections
2. Find Churchill Gutenberg URLs — best speech collections
3. Generate ESL primitive corpus examples for user to react to and curate
4. Generate hybrid voice examples (ESL + GCC) as seed training data
5. Write Phi-4 fine-tune node prompt for VS Code Claude
6. Write RSI loop node prompt for VS Code Claude

---

## 11. PASTE THIS TO START A NEW SESSION

_"I am gcr. We are continuing work on a project called DoubleNaught (DN) and a related McCay animation pipeline. Please read the attached PROJECT_CONTEXT.md document carefully — it contains everything you need to know about the project, its architecture, current build state, and immediate next actions. Once you have read it, confirm you are up to speed and ask me what I want to work on."_