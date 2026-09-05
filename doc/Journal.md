Generate a master workspace desktop shell frame titled "DoubleNaught Canvas". It must feature a dark theme (deep slate background) with thin outline widgets. The header toolbar must contain: (1) a dropdown/pick list for selecting created workflows, (2) an outlined "New Workflow" button, and (3) an outlined "Save Current" button. The large remaining center space must act as a spacious outlined grid canvas container designed to display nested nodes.

Create a Base Node Blueprint card frame that dictates the container rules for all workspace widgets. It must establish a dark-themed card container with thin cobalt blue outlines, standard padding, and rounded corners. It must define a strict typography scaling ruleset to prevent labels or status logs from clipping or overflowing on variable data, and include a top area reserved for a camelCase header title.

Create an Abstract Ingest Node frame that inherits its base dark container structure and cobalt outlines from the Base Node Blueprint. This abstract class must specialize in raw data entry. It must define a visual single-action button slot in the body, a status indicator strip at the bottom, and a dedicated right-side output port labeled rawOutput to denote that it streams raw unstructured string text to downstream blocks.

Design a concrete File Load Ingest Node inheriting from the Abstract Ingest Node layout. The center body must show an outlined "Browse Files" file picker button. Below it, include an inline progress loading bar (showing a green active percentage load indicator) and an outlined "allDone" green checkmark indicator. The right side of the card must house a prominent outlined output data node connector port labeled rawFileStream.

Design a concrete Display Node card that inherits container styling from the Base Node Blueprint. It must feature a left-side input data port labeled inputStream. The main body area must be an outlined polymorphic viewport box. Include a text label "Render Window" at the top-left of the viewport. The viewport should display a scrollable raw text stream box OR a scaled image placeholder depending on the mimetype parsed from inputStream.

# Claude
Review our local double_vision Flutter directory. Using the Vyuh module system, implement the base abstract node widget class based on the Master Base Node design. Ensure it handles global padding, dark-theme outlines, and enforces a text-scaling boundary to prevent key-value label clipping.

# Stitch
Create a modular SAM3 Content Panel component designed to fit inside a standard node frame body slot. The layout must be a vertical stack of three dark-themed card segments with subtle outlined widget boundaries, matching the exact interface in image_e05ee3.png:
1) "Text Prompt" Segment: Features a text input box with the placeholder 'e.g. "cat", "wheel"' and a square action submission button with a send icon arrow on the right.
2) "Box Prompts" Segment: Displays a descriptive subtitle "Draw boxes to include/exclude regions" above a dual-segmented capsule pill button split into "Include" (with a checkmark icon) and "Exclude" (with a box outline icon).
3) "Point Prompts" Segment: Displays a descriptive subtitle "Click on the image to select specific points" above a identical dual-segmented capsule pill button split into "Include" (with a checkmark icon) and "Exclude" (with a minus/circle icon).
All internal metadata and state definitions must use strict camelCase naming conventions.

# Claude

Update our local "DESIGN.md" file to reflect our shift to a compositional widget pattern instead of strict OOP inheritance. Rewrite the core architectural rules section to state that all workflow widgets must use a universal 'DoubleNaughtNodeWrapper' shell component that accepts modular child configurations (like the upcoming 'Sam3ControlPanel') to enforce strict camelCase styling and prevent data contract clipping. Save these changes to the file before moving on to implementation.

Before writing code, reference our "DESIGN.md" file to maintain strict camelCase standards and our Vyuh modular composition pattern. 

### 1. Core Architecture Rule (Composition Over Inheritance)
Forget strict OOP class inheritance for our nodes. We are using a compositional wrapper pattern instead. 
* First, implement a single, universal Flutter widget named 'DoubleNaughtNodeWrapper' using our camelCase layout rules. 
* This widget must simply provide the visual card layout, dark theme outlines, input/output ports, and accept a generic 'child' widget for its inner body content slot.

### 2. External Reference Context
Instead of writing our functional features from scratch, inspect the existing logic located at these absolute local paths:
* Frontend Reference UI: `/Users/gcr/populi.Wk/mlx_sam3/app/frontend/lib/main.dart`
* Backend Reference API: `/Users/gcr/populi.Wk/mlx_sam3/app/backend/main.py`

### 3. Your Task: Implement 'Sam3ControlPanel'
Extract the prompt text box, the bounding box selector, and the coordinate point feature logic from the referenced 'main.dart' file. Package these interactions into a standalone, modular widget called 'Sam3ControlPanel' that will be injected directly into the body slot of our 'DoubleNaughtNodeWrapper'.

The UI segments must match this layout structure:
1) Text Prompt Segment: A text input box with placeholder 'e.g. "cat", "wheel"' and a square action submission button.
2) Box Prompts Segment: Subtitle "Draw boxes to include/exclude regions" above a dual-segmented capsule pill button split into "Include" and "Exclude".
3) Point Prompts Segment: Subtitle "Click on the image to select specific points" above an identical dual-segmented capsule pill button split into "Include" and "Exclude".

### 4. Data Boundaries & Event Handlers
Ensure this node remains a pure controller. Do not attempt to render the resulting segment images inside this node widget. 
When a user changes a toggle state, submits a text prompt, or clicks an interaction trigger, capture that state using camelCase state variables (e.g., activeSelectionMode, currentPointCoordinates). Trigger the corresponding async HTTP/gRPC backend calls to the endpoints defined in the referenced 'main.py'. 

Pipes the output stream payloads (image matrix metadata, selection streams, and coordinate arrays) out of this node so our main workspace shell's large side panel display viewport can handle the actual high-resolution image rendering and lateral point-clicking coordinate capture.

### STEP 1: UPDATE YOUR DESIGN DOC (DO THIS FIRST)
Locate our local project's "DESIGN.md" file. Before writing any application code, update its content to reflect our shift to a compositional widget pattern instead of strict OOP inheritance. Add a rule stating that all workflow node elements must use a universal 'DoubleNaughtNodeWrapper' shell component that accepts modular child configurations to enforce strict camelCase styling and prevent data contract clipping. Save these updates to the disk immediately.

---

### STEP 2: REVIEW EXTERNAL REFERENCE CONTEXT
With "DESIGN.md" successfully updated, inspect the existing reference files located at these absolute local paths:
* Backend Reference Logic: `/Users/gcr/populi.Wk/mlx_sam3/app/backend/main.py`
* Frontend Reference UI: `/Users/gcr/populi.Wk/mlx_sam3/app/frontend/lib/main.dart`

Analyze the underlying SAM3 inference logic, model configurations, and interaction handlers so we can adapt them for our fresh DoubleNaught architecture.

---

### STEP 3: IMPLEMENT THE DOUBLENAUGHT BACKEND
The backend services within our DoubleNaught architecture are currently un-implemented. Using the extracted logic from the mlx_sam3 reference files, implement the clean backend service routes for DoubleNaught. Expose endpoints that handle three interaction modalities:
1) Semantic Text Prompts
2) Bounding Box Selections (with include/exclude state tags)
3) Coordinate Point Features (with include/exclude state tags)

Ensure all JSON dictionary payloads returned by this backend strictly use camelCase keys (e.g., segmentMask, inferenceMetrics) to conform to our design doc requirements.

---

### STEP 4: IMPLEMENT THE FRONTEND NODE WIDGETS
Now, implement the UI components within our "double_vision" Flutter app matching our newly updated compositional standards:

1) Universal Shell ('DoubleNaughtNodeWrapper'): Build this layout shell to handle the card outlines, padding, and input/output ports. It must accept a generic 'child' widget for its inner content body.
2) Feature Panel ('Sam3ControlPanel'): Build this modular panel to fit inside the wrapper, matching the exact layout segments seen in image_e05ee3.png:
   - Segment 1 (Text Prompt): A text input box with placeholder 'e.g. "cat", "wheel"' and a square submission arrow button.
   - Segment 2 (Box Prompts): Subtitle "Draw boxes to include/exclude regions" above an Include/Exclude dual pill toggle button.
   - Segment 3 (Point Prompts): Subtitle "Click on the image to select specific points" above an Include/Exclude dual pill toggle button.

Ensure that when a user interacts with these options, the widget captures the inputs using camelCase variables, makes asynchronous network requests to our newly created DoubleNaught backend endpoints, and streams the coordinate map data out of the node to the workspace's large lateral viewport for high-res rendering.

# Debug

Modify the File Picker Node Card component. Change its main title header to be exactly two distinct words using clean camelCase styling: "filePicker". Ensure the typography settings allocate proper padding so the words do not clip or wrap awkwardly.

### STEP 1: SANITY CHECK THE DESIGN DOC
Locate our local "DESIGN.md" file. Ensure it specifies that the File Source node is an ingestion layer boundary that reads local storage and streams out raw string data rather than structured Associative Arrays. Save any necessary clarifications to the file.

### STEP 2: FIX THE INTERACTION LOGIC
Our File Source  widget node is currently completely unresponsive when clicked. Review the file picker node component implementation in our local 'double_vision' Flutter project. 

1) Integration Check: Ensure the desktop/mobile file selection trigger is bound to a native handler using 'file_picker' or an equivalent Flutter plugin.
2) Desktop Platform Check: Since this is running locally, verify that the macOS/Windows/Linux platform entitlements allow file access dialogs (check 'macos/Runner/DebugProfile.entitlements' for the 'com.apple.security.files.user-selected.read-only' key if on Mac).
3) State Stream: Ensure that on a successful file select, the file contents are pushed down the stream using clean camelCase variables, triggering our 'loadingProgress' progress bar state before marking the operation 'allDone'.

## Debug 2

Change filePicker to File Source.

## Debug 3

Rename preview to Preview

Upon connection with File Source, Preview hangs. 

![[Pasted image 20260618111442.png]]

## Debug 4

### STEP 1: UPDATE DESIGN DOC
Update "DESIGN.md" to enforce the "Edge-Anchor" design pattern. 
Rule: All ports (Input/Output) must be explicitly positioned on the absolute boundary edges of the 'DoubleNaughtNodeWrapper' (Left for Inputs, Right for Outputs). 
Port Contract: The SAM3 work node must implement a "preview" Input port and an "Image Array" Output port.

### STEP 2: FIX GLOBAL NODE CONNECTORS
Our current Vyuh node implementation is missing visible ports on the edges and noodles are failing to connect/snap.
1) Modify 'DoubleNaughtNodeWrapper': Use a Stack to wrap the child content. Add Positioned widgets to place Input ports on the far left and Output ports on the far right.
2) Implement Port Snapping: Update the Vyuh NodeFlowTheme or NodeFlowController to ensure connections termination points target the GlobalKey of the specific port widget rather than the node's center.
3) SAM3 Logic Update: Add a specific Output port stream that handles a List of image data (Uint8List or Image objects) to support the segmentation array results.

### STEP 3: VISUAL SYNC
Ensure all node titles use two-word camelCase styling (e.g., "sam3Work", "filePicker"). 
Verify that noodles "glow" or pulse when being dragged near a valid port to provide visual confirmation of connectivity.

Your slide deck and implementation plan are ready! I've refined the visual architecture and provided a clear path for Claude to fix the connectivity gaps. Feel free to review the slides and let me know if you'd like to adjust any of the technical specifications.

## Have Gemini critique my plan

Let me list out what I understand to be the steps to be taken in light of our current use case.

To be clear, our current use case is where the SLM generates images that conform to a certain style.

Training such an SLM requires certain steps be taken. These steps translate into specific nodes. Ultimately, I want to outline a series of episodes where I show the training process. I need to identify the steps/nodes/episodes. Which step with with node will be covered in which episode.

  

The steps:

Step 1 Get the data

This is done. I have the source art work I will be using.

  

Step 2 Prepare the data

Using the SAM3 utility, I segment the art work using prompts. This yields a set of sub-images. These sub images are already described by the prompt that segmented them. I then, as necessary, further segment the sub-images if and when they contain subsub-images that need a prompt.

Step 3

After segmentation, Run a process that submits these images and prompts to an LLM. I prompt the LLM to review the submission and write an improved prompt.

Step 4

Submit the improved prompt to be formatted into a line the appended to a JSONL file. This is done with three nodes.

[LLM Prompt Improver]
  input:  segment_prompt + context_image
  output: raw LLM response

[Response Formatter]
  input:  raw LLM response
  output: structured record (dict/object)

[JSONL Appender]
  input:  structured record
  output: confirmation / error

Step 5 

Tokenize the prompts into a .bin file.  This is a call to MLX.  It fires when it receives an even notice from the appender.

**Input:** JSONL file with captions (text) and image paths  
**What happens:**

- Captions → token ID sequences (integers)
- Images → patch embeddings / pixel tensors
- Both processed through the model's **processor** (tokenizer + image processor combined for VLMs)

**Output:** Raw numerical representations — yes, effectively binary data, typically `.npz`

```
from mlx_lm import load
from transformers import AutoProcessor

# Load the processor for your base model
processor = AutoProcessor.from_pretrained("Qwen/Qwen2-VL-2B-Instruct")

# For each record in your JSONL
from PIL import Image

image = Image.open("./segments/frame_042.png")

inputs = processor(
    text="your caption text here",
    images=image,
    return_tensors="np"  # numpy, then convert to MLX arrays
)

# inputs now contains:
# inputs["input_ids"]        ← caption token IDs
# inputs["pixel_values"]     ← image as normalized tensor
# inputs["attention_mask"]   ← attention mask
```

Then save to `.npz`

```
import mlx.core as mx
import numpy as np

mx.savez(
    "dataset/sample_0042.npz",
    input_ids=inputs["input_ids"],
    pixel_values=inputs["pixel_values"],
    attention_mask=inputs["attention_mask"]
)
```
### Key point

The processor is **model-specific** — it must match your base model exactly. This is why locking down the base model early matters. The processor for Qwen2-VL will produce different output shapes and formats than moondream2 or SmolVLM.

Does this match what you were expecting, or were you expecting a more direct MLX primitive

Step 6
### Transformation

**Input:** Tokenized data  
**What happens:**

- Applies the model's **chat template** / instruction format
- Packs sequences to efficient lengths
- Creates **attention masks**
- Pairs inputs with labels (what the model should predict)
- Shuffles and batches

**Output:** Structured tensors ready for a training loop

Transformation is largely **not an MLX call** — it's data preparation logic that you write, which then feeds into MLX.

```
import mlx.core as mx
import numpy as np

# Load your tokenized .npz file
data = mx.load("dataset/sample_0042.npz")

input_ids = data["input_ids"]
pixel_values = data["pixel_values"]
attention_mask = data["attention_mask"]
```
Then you construct the **labels** (what the model is trained to predict):

```
# This is model-specific — Qwen2-VL example
messages = [
    {
        "role": "user",
        "content": [
            {"type": "image"},
            {"type": "text", "text": caption}
        ]
    }
]

formatted = processor.apply_chat_template(
    messages,
    tokenize=False,
    add_generation_prompt=True
)
```
The only real MLX call here

```
# Convert everything to MLX arrays for training
batch = {
    "input_ids": mx.array(input_ids),
    "pixel_values": mx.array(pixel_values),
    "attention_mask": mx.array(attention_mask),
    "labels": mx.array(labels)
}
```
### Honest summary

|Sub-step|Tool|
|---|---|
|Load `.npz`|`mx.load()`|
|Apply chat template|`processor.apply_chat_template()`|
|Construct labels|NumPy logic|
|Convert to training tensors|`mx.array()`|

Transformation is mostly **glue code** — the MLX calls bookend it, but the logic in between is yours. This is the step most tutorials gloss over, and where most first-time SLM pipelines break.

Step 7: 
### Training

**Input:** Transformed batches  
**What happens:**

- Forward pass through the base model
- Loss calculated
- Weights updated (LoRA adapters or full fine-tune)

**Output:** Trained weights / adapter files

For VLM fine-tuning with MLX, the primary call is **`mlx_lm.lora`** — but let me be honest about the current state.

```
# CLI
mlx_lm.lora \
  --model Qwen/Qwen2.5-2B-Instruct \
  --train \
  --data ./dataset \
  --iters 1000
```
```
from mlx_lm import train

train(
    model="Qwen/Qwen2.5-2B-Instruct",
    train_data="./dataset",
    iters=1000,
    lora_rank=8
)
```
### The honest answer (vision models)

MLX-LM's **vision fine-tuning is still maturing**. As of mid-2025, full VLM fine-tuning via `mlx_lm.lora` is not uniformly supported across all vision models. What this means practically:

- You may need to write a **custom training loop**
- The core MLX calls in that loop are:
### The clean answer (text-only models)

For a text-only model, this is well-supported:

```
import mlx.core as mx
import mlx.nn as nn
from mlx.optimizers import Adam

model, processor = load("Qwen/Qwen2-VL-2B-Instruct")
optimizer = Adam(learning_rate=1e-5)

def loss_fn(model, batch):
    logits = model(**batch)
    return nn.losses.cross_entropy(logits, batch["labels"])

# Training step
loss_and_grad_fn = nn.value_and_grad(model, loss_fn)

for batch in dataloader:
    loss, grads = loss_and_grad_fn(model, batch)
    optimizer.update(model, grads)
    mx.eval(model.parameters(), optimizer.state)  # ← critical MLX call
```
The critical MLX-specific call

```
mx.eval(model.parameters(), optimizer.state)
```
### Bottom line

|Scenario|Approach|
|---|---|
|Text-only base model|`mlx_lm.lora` CLI or Python API|
|Vision model, supported|`mlx_lm.lora` with vision flags|
|Vision model, unsupported|Custom loop with `mx.eval()` at its core|

Before building the training node, you need to verify whether your specific base model is supported by `mlx_lm.lora` for vision fine-tuning. That single answer determines whether your training node is a config call or a full custom implementation.

Step 8
### Evaluation

**Input:** Trained weights + held-out validation data  
**What happens:** Measures whether the model actually improved

### What you're measuring

For your specific use case — image segments + captions — evaluation answers:  
**"Does the fine-tuned model generate better prompts than the base model?"**

This is harder to measure than classification tasks because the output is text. You have two categories of metrics:

### Automatic metrics

#### Perplexity — the primary MLX call

```
from mlx_lm import evaluate

perplexity = evaluate(
    model=model,
    dataset="./dataset/validation.jsonl",
)
```
Lower perplexity = model is less "surprised" by the validation data. Useful for tracking improvement across checkpoints but doesn't tell you if the outputs are actually good.

#### BLEU / ROUGE

```
from nltk.translate.bleu_score import sentence_bleu

reference = ["improved", "prompt", "tokens"]
candidate = model_output.split()

score = sentence_bleu([reference], candidate)
```
### The validation split question

You need to have held back data before training:

```
dataset/
  train.jsonl        ← ~80%
  valid.jsonl        ← ~10%
  test.jsonl         ← ~10%
```
### Honest reality for VLM evaluation

Automatic metrics only tell part of the story. For prompt quality specifically you likely need:

|Method|What it tells you|
|---|---|
|Perplexity|Model fit to validation data|
|BLEU/ROUGE|Lexical similarity to reference prompts|
|Human review|Whether prompts are actually useful|
|Round-trip test|Feed generated prompt back to image gen, does it produce a good image?|

The **round-trip test** is arguably the most meaningful for your use case — generate a prompt from a segment, feed it to an image generator, compare output to original segment.

Step 9
### Quantization (likely)

**Input:** Trained weights  
**Output:** Compressed model (4-bit, 8-bit) suitable for deployment on Apple Silicon

### What it is and why

Your fine-tuned model weights are in **float32 or bfloat16** — full precision. Quantization compresses them to 4-bit or 8-bit integers, which for Apple Silicon means:

- Smaller model size (4-bit = ~75% reduction)
- Faster inference
- Fits in unified memory more easily
- Small, acceptable quality loss

### The MLX call

This is one of the cleanest steps — MLX has first-class quantization support:

```
from mlx_lm import convert

convert(
    hf_path="./fine_tuned_model",    # your trained model
    mlx_path="./quantized_model",    # output destination
    quantize=True,
    q_bits=4                          # 4-bit is standard
)
```
Or via CLI:

```
mlx_lm.convert \
  --hf-path ./fine_tuned_model \
  --mlx-path ./quantized_model \
  -q \
  --q-bits 4
```
### Bit depth tradeoffs

|Setting|Size reduction|Quality|
|---|---|---|
|`q_bits=8`|~50%|Very close to original|
|`q_bits=4`|~75%|Good, standard choice|
|`q_bits=2`|~87%|Noticeable degradation|

**4-bit is the right default** for an SLM on Apple Silicon.

---

### One important flag — LoRA adapters

If you trained with LoRA rather than full fine-tuning, you need to **fuse the adapters first** before quantizing:

```
from mlx_lm import fuse

fuse(
    model="./base_model",
    adapter_path="./adapters",
    save_path="./fused_model"
)

# Then quantize the fused model
convert(
    hf_path="./fused_model",
    mlx_path="./quantized_model",
    quantize=True,
    q_bits=4
)
```

Quantizing unfused LoRA adapters is a common mistake that produces a broken model.

---

### After quantization

You can immediately test with:

```
from mlx_lm import load, generate

model, tokenizer = load("./quantized_model")

response = generate(
    model=model,
    tokenizer=tokenizer,
    prompt="your test prompt",
    max_tokens=200
)
'''
### Full pipeline — now complete

```
[LLM Prompt Improver]
[Response Formatter]
[JSONL Appender]        ← with train/valid/test split
[Validator]
[Tokenizer]
[Transformer]
[Training]
[Evaluation]
[Quantization]          ← you are here
[Deployment]
'''

Does this match what you've been reading? And does MLX-LM handle steps 2-3 internally, or are you building those steps yourself?

# After Ely.

### URLNode

_"We are adding a new node to DoubleNaught called URLNode. Before implementing, read the existing node implementations to understand DN's conventions for both the FastAPI backend and Flutter frontend._

_URLNode is a source node — it has no upstream input. It stores a URL string plus metadata and outputs a D4M/AA payload for downstream nodes._

_URLNode should have the following:_

_Flutter frontend:_

- _Three input fields: URL, author tag (dropdown: gilbert | chesterton | churchill), work title (free text)_
- _A validate button that pings the FastAPI endpoint to confirm the URL is reachable_
- _Follows existing DN node UI conventions_

_FastAPI backend:_

- _Endpoint to receive and validate the URL (HEAD request to confirm reachable)_
- _Endpoint to output the D4M/AA payload_
- _Follows existing DN FastAPI route and model conventions_

_Output AA structure:_

```
Rows:    nodeID
Columns: url | author | work_title | validated | timestamp
Values:  corresponding strings
```

_The output AA flows to FetchNode downstream._

_Follow all existing DN conventions for node registration, N&N graph wiring, and D4M/AA payload structure. If any conventions are ambiguous, read additional existing nodes before deciding."_

### FetchNode

_"We are adding a new node to DoubleNaught called FetchNode. Before implementing, read the existing node implementations and the newly implemented URLNode to understand DN's conventions for both the FastAPI backend and Flutter frontend._

_FetchNode receives a D4M/AA payload from URLNode, fetches the text content from the URL, strips boilerplate, and streams clean raw text plus metadata to ChunkNode downstream._

_FetchNode should have the following:_

_Flutter frontend:_

- _Displays the incoming URL and metadata from the upstream AA payload_
- _A fetch button that triggers the backend fetch operation_
- _Status indicator: idle | fetching | complete | error_
- _Follows existing DN node UI conventions_

_FastAPI backend:_

- _Endpoint to receive the URLNode AA payload_
- _Fetches text content from the URL using an async HTTP client_
- _Strips Project Gutenberg boilerplate using the standard markers:_

```
*** START OF THE PROJECT GUTENBERG EBOOK [TITLE] ***
*** END OF THE PROJECT GUTENBERG EBOOK [TITLE] ***
```

- _Everything outside these markers is discarded_
- _Streams cleaned text to output_
- _Follows existing DN FastAPI route and model conventions_

_Output AA structure:_

```
Rows:    chunkID (sequential)
Columns: raw_text | author | work_title | char_count | fetch_timestamp
Values:  corresponding strings
```

_FetchNode is general purpose — it should work for any URL, not just Project Gutenberg. The boilerplate stripping should only trigger when Gutenberg markers are detected._

_Follow all existing DN conventions for node registration, N&N graph wiring, and D4M/AA payload structure. If any conventions are ambiguous, read additional existing nodes before deciding."_
### ChunkNode

_"We are adding a new node to DoubleNaught called ChunkNode. Before implementing, read the existing node implementations, URLNode, and FetchNode to understand DN's conventions for both the FastAPI backend and Flutter frontend._

_ChunkNode receives a D4M/AA payload from FetchNode containing raw cleaned text plus metadata, applies author-aware chunking, and outputs a D4M/AA payload of discrete passages for downstream processing._

_ChunkNode should have the following:_

_Flutter frontend:_

- _Displays incoming author tag and work title from upstream AA payload_
- _Shows chunk count and token statistics after processing_
- _A chunk button that triggers the backend chunking operation_
- _Status indicator: idle | chunking | complete | error_
- _Follows existing DN node UI conventions_

_FastAPI backend:_

- _Endpoint to receive the FetchNode AA payload_
- _Applies three author-aware chunking strategies selected by author tag:_

```
gilbert:
  - Split on song/scene/exchange boundaries
  - Markers: stage directions, song titles, speaker changes
  - Preserve complete exchanges — never split mid-dialogue
  - Token range: 50-300

chesterton:
  - Split on paragraph boundaries (blank lines)
  - Merge short consecutive paragraphs until minimum token count reached
  - Preserve complete sentences — never split mid-sentence
  - Token range: 50-300

churchill:
  - Split on periodic sentence clusters
  - Detect clause builds using punctuation patterns (semicolons, em-dashes building to full stop)
  - Preserve complete periodic sentences — never split mid-build
  - Token range: 50-300
```

- _Secondary constraint for all strategies: if a natural unit exceeds 300 tokens, split at the nearest sentence boundary below the maximum. If a natural unit is below 50 tokens, merge with the next unit._
- _Discard any fragment below 50 tokens that cannot be merged_
- _Token counting should use a consistent tokenizer aligned with Phi-4_
- _Follows existing DN FastAPI route and model conventions_

_Output AA structure:_

```
Rows:    chunkID (sequential, globally unique)
Columns: text | author | work_title | position | token_count | chunk_strategy
Values:  corresponding strings and integers
```

_chunk_strategy column records which strategy was applied (gilbert | chesterton | churchill) for downstream auditability._

_ChunkNode is author-aware but should be architected so additional chunking strategies can be added in future without restructuring the node._

_Follow all existing DN conventions for node registration, N&N graph wiring, and D4M/AA payload structure. If any conventions are ambiguous, read additional existing nodes before deciding."_
### AA2JSONLNode

_"We are adding a new node to DoubleNaught called AA2JSONLNode. Before implementing, read the existing node implementations, URLNode, FetchNode, and ChunkNode to understand DN's conventions for both the FastAPI backend and Flutter frontend._

_AA2JSONLNode receives a D4M/AA payload from ChunkNode and writes it as a JSONL file formatted for Phi-4 fine-tuning._

_AA2JSONLNode should have the following:_

_Flutter frontend:_

- _Displays incoming chunk count and author metadata from upstream AA payload_
- _A file path input field for the output JSONL file destination_
- _A format selector with two options:_

```
instruction-completion:
  {"prompt": "Write in the GCC voice:", "completion": "<text>"}

continuation:
  {"text": "<text>"}
```

- _A write button that triggers the backend write operation_
- _Status indicator: idle | writing | complete | error_
- _Displays output file path and line count on completion_
- _Follows existing DN node UI conventions_

_FastAPI backend:_

- _Endpoint to receive the ChunkNode AA payload_
- _Iterates rows of the AA in position order_
- _Formats each chunk according to selected format_
- _Writes one JSON object per line to the output file_
- _Validates each line is valid JSON before writing_
- _Reports total lines written, any skipped chunks, and output file size_
- _Follows existing DN FastAPI route and model conventions_

_Output AA structure:_

```
Rows:    chunkID
Columns: jsonl_line | format | output_file | write_timestamp | status
Values:  corresponding strings
```

_The output AA preserves the full provenance chain — each row retains its chunkID from ChunkNode so the JSONL line can be traced back to its source passage._

_AA2JSONLNode is general purpose — it should handle any well-formed D4M/AA payload with a text column, not just GCC corpus output. The Phi-4 formatting options should be selectable per run._

_Follow all existing DN conventions for node registration, N&N graph wiring, and D4M/AA payload structure. If any conventions are ambiguous, read additional existing nodes before deciding."_
### ReviewNode

_"We are adding a new node to DoubleNaught called ReviewNode. Before implementing, read the existing node implementations, URLNode, FetchNode, ChunkNode, and AA2JSONLNode to understand DN's conventions for both the FastAPI backend and Flutter frontend._

_ReviewNode sits between ChunkNode and AA2JSONLNode. It presents candidate passages to the user for human-in-the-loop curation. Approved passages flow downstream. Rejected passages are discarded. Flagged passages can be edited before approval._

_ReviewNode should have the following:_

_Flutter frontend:_

- _Displays passages one at a time from the incoming AA payload_
- _Each passage card shows:_

```
- text content
- author
- work title
- position
- token count
- chunk strategy
```

- _Three action buttons per passage:_

```
Approve  — passes chunk downstream unchanged
Edit     — opens inline text editor, saves edited version downstream
Reject   — discards chunk, records rejection in output AA
```

- _Progress indicator: current chunk / total chunks_
- _Session can be paused and resumed — ReviewNode persists state between sessions_
- _Keyboard shortcuts for approve/reject for fast review_
- _Follows existing DN node UI conventions_

_FastAPI backend:_

- _Endpoint to receive ChunkNode AA payload_
- _Persists review state so sessions survive interruption_
- _Tracks approved, edited, rejected counts_
- _For edited passages, preserves both original and edited text in output AA_
- _Endpoint to resume interrupted review session_
- _Follows existing DN FastAPI route and model conventions_

_Output AA structure:_

```
Rows:    chunkID
Columns: text | original_text | author | work_title | position | 
         token_count | review_status | edit_flag | review_timestamp
Values:  corresponding strings
```

_review_status values: approved | edited | rejected_  
_edit_flag: true if passage was modified during review, false otherwise_  
_original_text preserves the pre-edit text when edit_flag is true_

_Only approved and edited passages flow to AA2JSONLNode. Rejected passages are retained in the output AA with review_status: rejected for auditability but are not forwarded downstream._

_ReviewNode is general purpose — it should handle any D4M/AA payload with a text column, not just GCC corpus chunks._

_Follow all existing DN conventions for node registration, N&N graph wiring, and D4M/AA payload structure. If any conventions are ambiguous, read additional existing nodes before deciding."_


_"Review the current URLNode implementation. We have discovered that the Gilbert and Sullivan source is a single large file containing multiple complete operas at this URL:_

_[https://www.gutenberg.org/files/808/808-h/808-h.htm](https://www.gutenberg.org/files/808/808-h/808-h.htm)_

_URLNode currently stores a URL plus author tag and work title. However it needs to support targeting a specific work within a multi-work file. ChunkNode will need the work title to locate and extract the correct play before chunking._

_Check whether URLNode currently supports a work_selector field — a string that ChunkNode can use to locate the start of a specific work within a larger file._

_If URLNode does not support this:_

- _Add a work_selector field to the URLNode data model and Flutter UI_
- _work_selector is optional — leave empty for single-work files_
- _Update the output AA to include a work_selector column_
- _Update FetchNode to pass work_selector through to ChunkNode unchanged_
- _Update ChunkNode to use work_selector to locate and extract the target work before applying chunking strategy — text runs from the work_selector marker to the next matching title-level marker or end of file_

_Verify the change is consistent with existing DN conventions and that the AA payload structure remains valid through the full pipeline:_

```
[URLNode] → [FetchNode] → [ChunkNode] → [ReviewNode] → [AA2JSONLNode]
```

_If URLNode already supports this, confirm and make no changes."_

_"We are adding a new node to DoubleNaught called InventoryNode. Before implementing, read the existing node implementations to understand DN's conventions for both the FastAPI backend and Flutter frontend._

### InventoryNode

_InventoryNode is a source node — it has no upstream input. It maintains a persistent, editable list of URL entries and outputs a single selected entry as a D4M/AA payload to URLNode downstream. It replaces the manual re-entry problem in URLNode by providing a managed, reusable inventory of sources._

_InventoryNode should have the following:_

_Flutter frontend:_

- _A scrollable list displaying all inventory entries with columns:_

```
description | author | work_title | work_selector | url
```

- _Toolbar actions:_

```
Add     — opens form to create new entry
Edit    — opens form to edit selected entry  
Delete  — removes selected entry with confirmation
Select  — outputs selected entry as AA payload to downstream URLNode
```

- _Add/Edit form fields:_

```
URL            (required)
Author         (dropdown: gilbert | chesterton | churchill)
Work Title     (required)
Work Selector  (optional — for multi-work files)
Description    (free text — human readable label)
```

- _List is sortable by author and work title_
- _Persists between sessions_
- _Follows existing DN node UI conventions_

_FastAPI backend:_

- _Persistent storage of inventory as D4M/AA_
- _CRUD endpoints: create, read, update, delete entries_
- _Endpoint to output selected entry as AA payload_
- _On first run, pre-populate inventory with the following four entries:_

```
Entry 1:
  url:            https://www.gutenberg.org/files/808/808-h/808-h.htm
  author:         gilbert
  work_title:     HMS Pinafore
  work_selector:  H.M.S. PINAFORE
  description:    Gilbert & Sullivan — HMS Pinafore

Entry 2:
  url:            https://www.gutenberg.org/files/808/808-h/808-h.htm
  author:         gilbert
  work_title:     The Pirates of Penzance
  work_selector:  THE PIRATES OF PENZANCE
  description:    Gilbert & Sullivan — The Pirates of Penzance

Entry 3:
  url:            https://www.gutenberg.org/files/808/808-h/808-h.htm
  author:         gilbert
  work_title:     Iolanthe
  work_selector:  IOLANTHE; OR, THE PEER AND THE PERI
  description:    Gilbert & Sullivan — Iolanthe

Entry 4:
  url:            https://www.gutenberg.org/files/808/808-h/808-h.htm
  author:         gilbert
  work_title:     The Mikado
  work_selector:  THE MIKADO; OR, THE TOWN OF TITIPU
  description:    Gilbert & Sullivan — The Mikado
```

- _Follows existing DN FastAPI route and model conventions_

_Output AA structure:_

```
Rows:    entryID
Columns: url | author | work_title | work_selector | description | selected_timestamp
Values:  corresponding strings
```

_InventoryNode is general purpose — it should handle any list of URL-based sources, not just GCC corpus entries. Future entries for Chesterton and Churchill will be added to the same inventory._

_Also update URLNode to receive its input from InventoryNode's output AA rather than from manual field entry. URLNode should display the incoming entry for confirmation but no longer requires manual re-entry of fields._

_Follow all existing DN conventions for node registration, N&N graph wiring, and D4M/AA payload structure. If any conventions are ambiguous, read additional existing nodes before deciding."_

## primary execution button ("Go")

Let me add a primary execution button ("Go") to our main top action/button bar, giving DoubleNaught (DN) a ComfyUI-style workflow trigger.

PLACEMENT & STYLING SPECIFICATIONS:
1. Position: The "Go" button must be placed as the FIRST item in the top button bar, immediately preceding the "Save" button.
2. Styling: 
   - Fill/Accent Color: Vibrant Green (e.g., `Colors.green.shade600` or `#2E7D32` with a clear, high-contrast white text label).
   - Icon: Include a clean play icon (e.g., `Icons.play_arrow_rounded`) before the text label.
   - Text Label: "Go" (or "Run Workflow" depending on button bar spacing, formatted in natural prose, with internal variables following camelCase).

FUNCTIONALITY & BEHAVIOR:
- Trigger Event: Clicking the "Go" button evaluates the currently active/displayed node graph on the canvas.
- Execution State: 
  - While executing, update the button UI to show an active state (e.g., change label to "Running..." or show a subtle loading indicator, disabling re-clicks until completion).
  - Collect the active nodes on the canvas, resolve their topological order starting from active source nodes (like Inventory or URLSource), and trigger the node evaluation chain.

Please update the top button bar widget layout to insert this green "Go" button in the first position before "Save", and connect its `onPressed` callback to our workflow execution engine state.

## Please refine the visual styling of our newly added "Go"

Please refine the visual styling of our newly added "Go" button to strictly match the design system of the existing top button bar (e.g., the "Save" button).

STYLING REQUIREMENTS:
1. Button Variant: Outlined style (e.g., matching the `OutlinedButton` or custom outlined border decoration used by "Save").
2. Border & Text Color: Accent Green (e.g., `Colors.green.shade600` or `#2E7D32` for both the border outline and the text/icon label).
3. Background: Transparent background, matching the non-solid, outlined design of the other action buttons.
4. Structure: Preserve its position as the first item in the button bar (right before "Save"), as well as its icon (`Icons.play_arrow_rounded`) and text label ("Go").

Please update the button's theme/style parameters so its layout, padding, font size, and outline match the "Save" button exactly, differing only in using green for its border, text, and icon.

Please fix the text and icon colors for our green "Go" button in the top action bar so that the text and icon render in green alongside the border.

## SPECIFIC FIX:

SPECIFIC FIX:
In Flutter's `OutlinedButton.styleFrom`, setting `side: BorderSide(...)` only colors the outline border. To explicitly color the text and icon, we must also specify `foregroundColor`.

Please update the "Go" button's `OutlinedButton.styleFrom` configuration to explicitly set:
1. `side`: `const BorderSide(color: Colors.green.shade600)` (or `#2E7D32`)
2. `foregroundColor`: `Colors.green.shade600` (or `#2E7D32`)
3. `iconColor`: `Colors.green.shade600` (or `#2E7D32`)

This will ensure the text label ("Go") and the play icon (`Icons.play_arrow_rounded`) match the green border exactly, maintaining a unified outlined look.

Act as an expert Flutter developer working on DoubleNaught (DN).

## URLSource and Inventory:

We are restructuring the relationship between URLSource and Inventory:
1. `URLSource` takes manual text input (URLs or local file paths) and emits a raw location string.
2. `Inventory` receives input from `URLSource` and sends an asynchronous call to our FastAPI backend to persist this new URL into `inventory.json` as a new D4M AA row entry.
3. `Inventory` maintains its picklist reading from the backend's `inventory.json`. Receiving input from `URLSource` automatically updates this picklist and selects the new item.
4. `Inventory` is now responsible for fetching the actual content behind the active URL (text/html or image data) and streaming that payload out to downstream nodes.

TASK 1: Update Node Connectivity
- Add an `inputPort` to `Inventory` to accept connections from `URLSource`.
- When a string payload arrives at `Inventory` from `URLSource`, trigger an internal state update: create a new D4M row entry for this item and send a POST request to our FastAPI backend service to append it to `inventory.json`.

TASK 2: Update Inventory Canvas Picklist
- Re-query/update the internal picklist state whenever a new item is added via `URLSource`. Set the newly added item as the currently active picklist selection.

TASK 3: Content Fetch & Stream Output
- Implement the content loader in `Inventory`. Once a URL is active (selected manually from the dropdown or received from `URLSource`), perform an HTTP GET (or local file read) to fetch the payload.
- Emit the retrieved content and asset metadata out of `Inventory`'s main output port so downstream processing nodes receive the actual file bytes/text.

Please implement this input-to-catalog pipeline and backend save workflow cleanly.

## Inventory node: removing the HTTP/FastAPI 

Act as an expert Flutter developer working on DoubleNaught (DN). 

We are making two major improvements to the Inventory node: removing the HTTP/FastAPI requirement in favor of local `dart:io` file persistence, and cleaning up the crowded canvas UI layout shown in the screenshot.

TASK 1: Direct File I/O Persistence (Remove BE Dependency)
- Replace all HTTP client calls (`http://localhost:8000/inventory`) in `Inventory` state/controller with local `dart:io` file operations.
- Save and load `inventory.json` directly to/from the local workspace directory (`File(workspacePath + '/inventory.json')`).
- If the file does not exist, initialize it cleanly as an empty array `[]` without throwing network exceptions.

TASK 2: Node UI & Port Alignment Overhaul
- Fix Port Alignment: Move the port connection labels (`urlInput` on left; `entry` and `content` on right) outside or properly padded away from the top action buttons (+ Add, Edit, Delete, Select) so labels no longer overlay button shapes.
- Clean Table Layout: Replace the horizontal multi-column text row (`description`, `author`, `work_title`, `work_selector`, `url`) with a clean, vertical card list or a single dropdown selector showing `work_title (author)`.
- Compact Action Bar: Wrap the action buttons (`+ Add`, `Edit`, `Delete`, `Select`) in a compact `Wrap` or `Row` with standard `IconButton` tooltips or smaller padding to save vertical space.
- Graceful Error Banner: Catch file read/write errors cleanly and show a concise single-line status indicator instead of dumping raw stack traces inside the node bounds.

Please update the Inventory node widget layout and file persistence model accordingly.


## refactor and reorganize the node widgets 

Please refactor and reorganize the node widgets in `frontend/lib/widgets` into a dedicated `nodes` subdirectory.

### Objective
Group all current and future node-related UI widgets into `frontend/lib/widgets/nodes/` while preserving clean imports and compiling without errors.

### Directory Structure Target
Create the following layout under `frontend/lib/widgets/nodes/`:
- `lib/widgets/nodes/base/` -> Place foundational/abstract node UI widgets here (e.g., base node container, port renderers, header widgets).
- `lib/widgets/nodes/implementations/` -> Place all concrete canvas node widgets here (e.g., agent node, function node, source node, start node).
- `lib/widgets/nodes/nodes.dart` -> Create an export barrel file that re-exports all public widgets from `nodes/`.

### Requirements & Guardrails
1. File Movements: Move all node-related widget files from `lib/widgets/` into their respective subdirectories inside `lib/widgets/nodes/`. Leave non-node generic UI widgets (like canvas toolbars or modal dialogs) in `lib/widgets/`.
2. Import Updates: Update all `package:` and relative `import` statements across the entire project (`lib/` and `test/`) to reflect the new file locations.
3. Barrel File Usage: Prefer exporting all node widgets through `lib/widgets/nodes/nodes.dart` so callers outside the `nodes/` directory can import `package:frontend/widgets/nodes/nodes.dart` cleanly.
4. Naming Conventions: Maintain lowerCamelCase for variables and methods, UpperCamelCase for class names, and standard lower_snake_case for filenames. User-facing labels, tooltips, and titles must use standard text formatting (not camelCase).
5. Verification: Ensure all code compiles cleanly with no broken relative imports or missing symbol errors.

Please analyze the current contents of `lib/widgets/`, present the planned file moves, and execute the refactoring.

## manually added

I have manually added the new core reactive primitives (`OutputPort`, `InputPort`, and `AgentNode`) to the codebase. We are moving from our legacy direct-call execution to a fully decoupled PubSub event architecture.

Please execute this task in two clear phases:

### Phase 1: Code Review & Validation
Review the implementation of `OutputPort`, `InputPort`, and `AgentNode` against the following criteria:
1. Stream Lifecycle & Memory Safety: Are Dart Streams, `StreamSubscription`s, and `StreamController`s properly disposed of when ports or nodes are disconnected or destroyed?
2. Queue & Backpressure Handling: How does `InputPort` handle incoming payloads when the node is busy or executing? Are there edge cases with missing or late-arriving data?
3. Type Safety & Schema Guardrails: Are `AaPayload` objects validated correctly on ingress?
4. Naming & Style Rules: Ensure all code uses lowerCamelCase for members, UpperCamelCase for types, and lower_snake_case for filenames. User-facing labels must use standard human text formatting (not camelCase).

Provide a concise summary of any critical findings or improvements needed before integration.

### Phase 2: Integration Plan & Refactoring
Once the core primitives are verified, outline and execute a step-by-step refactoring plan to replace our legacy execution engine:
1. Target Analysis: Identify all legacy node definitions, execution callers, and UI wire-binding components currently in use.
2. Step-by-Step Refactoring: Rewrite the legacy execution components to inherit from or delegate to `AgentNode`, using `InputPort.connect(outputPort)` for wire connections.
3. Verification: Ensure all relative and package imports compile without errors and that nodes cleanly emit and consume `AaPayload` messages across the canvas.

Please start with Phase 1 (Code Review) and present your findings before we proceed to Phase 2.

## when selecting or dragging a node

We need to update the drag-and-drop / selection visual feedback for nodes on our Flutter visual canvas.

### Issue
Currently, when selecting or dragging a node, the **entire node container highlights** (filling the background). 

### Desired Behavior
Change the visual selection feedback so that **only the outer border highlights** upon selection/drag, while the node's main card background color remains unchanged.

### Requirements & Code Rules
1. Selection Visuals:
   - Keep the normal node card/container background color constant during selection or dragging state changes.
   - Apply the active accent/selection color strictly to the node card's `Border` or `BoxDecoration` border width/color (e.g., a 2px accent outline).
2. Canvas State Management:
   - Locate the node widget's `BoxDecoration` or wrapping selection container (e.g., in `NodeWidget`, `CanvasNode`, or custom painter).
   - Ensure hover, selected, and dragging visual states are driven cleanly by selection state flags without altering the inner child fill.
3. Code Standards:
   - Maintain lowerCamelCase for internal variables/properties.
   - Ensure user-facing labels or tooltips remain formatted in standard text.

Please inspect our node visual canvas widget, update the selection/drag decoration styling to highlight only the border, and confirm that it compiles cleanly.

We need to refactor and correct our canvas workflow and node management system, as well as fix a UI layout restriction on our split view. Please read these functional requirements carefully and implement the necessary architecture updates across both frontend and backend handlers.

---

### 1. Reconceptualize & Disambiguate: Node Catalog vs. Workflow Inventory

There is currently a design confusion in the UI regarding nodes and workflows:
* **Node Catalog (Inventory):** A catalog of individual, available functional/agentic node primitives that can be dragged or placed onto the canvas.
* **Saved Workflows:** Configured node graphs (nodes, connections/edges, spatial coordinates, and parameter states) that have been saved and can be loaded back onto the canvas.

#### Required UI & State Fixes:
1. **Rename the existing dropdown:** The current dropdown incorrectly lists node primitives under the title "Workflows". Rename or re-purpose this UI area to **"Node Catalog"** (or "Node Inventory").
2. **Add a true "Workflow Inventory" Dropdown / Drawer:**
   * Create a dedicated UI control labeled **"Workflows"** that lists all previously saved workflow files/configs.
   * Selecting a workflow from this list loads its complete graph state onto the canvas.

---

### 2. Implement Full Workflow Lifecycle (Save, Save As, Load)

Implement standard file-like lifecycle management for canvas graph states:

1. **Save Operations:**
   * **Initial Save:** If the active canvas has not yet been saved, clicking "Save Workflow" must open a modal prompting the user for a **Workflow Name**.
   * **Uniqueness Validation:** Enforce unique names. If the user enters a name that already exists, prompt them to overwrite or choose a different name.
   * **Save As:** Provide a "Save As" menu option allowing the user to save the current canvas state under a new distinct name.
   * **Overwrite Save:** If the workflow already has a name, "Save" silently updates the existing saved workflow file/record.
2. **Persistence & Payload:**
   * A saved workflow payload must capture:
     * Workflow ID and unique Name.
     * List of node instances (node type, unique instance ID, canvas coordinates $x, y$, parameter configurations).
     * List of connections/edges (source node, output port, target node, input port).
   * Persist workflows to a dedicated local storage directory or backend configuration registry (e.g., `storage/workflows/` or `workflows.json`).
3. **Execution & Re-loading:**
   * Selecting a workflow from the **Workflows** dropdown must clear or offer to replace the current canvas with the saved workflow state.
   * Loaded workflows can be re-executed, modified, re-saved, or exported.

---

### 3. Node Inventory File Storage (`storage/inventory.json`)

Establish clear separation for individual node definition storage:

* **Location:** Maintain node definitions in `storage/inventory.json`.
* **Behavior:**
  * Populate `inventory.json` whenever a new custom node definition is created.
  * Update or patch entries in `inventory.json` whenever a node definition is renamed, updated, or deleted.
* Write the necessary backend/storage handler code to support CRUD operations on `storage/inventory.json`.

---

### 4. Resizable Canvas vs. Preview Split Panel

Currently, the border dividing the canvas and the preview area is rigid/fixed.

* **Requirement:** Convert the divider between the main canvas and the preview/inspector panel into an interactive **Resizable Split View** (drag handle / splitter bar).
* Allow the user to drag the handle left/right (or up/down depending on layout) to dynamically resize the canvas relative to the preview panel.
* Ensure the canvas view-box and redraw handlers update their responsive bounds dynamically during drag events.

---

### Task Summary for Claude:
1. Update the UI layout to split the **Node Catalog** from the **Saved Workflows** dropdown.
2. Implement modal-driven "Save", "Save As", and "Load" handlers for complete canvas graph states.
3. Add backend/local file logic to manage node primitives in `storage/inventory.json`.
4. Replace the static panel divider between canvas and preview with a flexible, draggable resizable panel container.

Please outline the file changes required and provide the full code implementations.

We are implementing the `Start` execution node, the `LoadModel` functional node, and model storage. 

CRITICAL REQUIREMENT: All data payloads, model catalog storage, and node contracts MUST follow our standard Associative Array (AA) JSON schema. Use our existing Dart AA implementation (`*.dart`) for loading and persisting AA objects.

---

### 1. Model Catalog AA Storage (`storage/models_aa.json`)

1. Store model definitions in an AA-compliant JSON structure at `storage/models_aa.json`.
2. Each model entry is a Row in the AA matrix, using attributes for key properties:
   * **Row Key:** `model:<modelId>`
   * **Attributes:** `displayName`, `sourceType` (`local` | `huggingface` | `remote_url`), `pathOrUrl`, `format` (`safetensors` | `gguf` | `mlx` | `onnx`), `task` (`zero-shot-classification` | `text-generation` | etc.).
3. Use the Dart AA class (`*.dart`) to load, update, slice, and save `storage/models_aa.json`.

---

### 2. Implement `LoadModel` Node (AA Payload Native)

Create the `LoadModel` node:

* **Inputs:**
  * `urlIn` (Optional String Port): Receives a URL string or Hugging Face model ID.
  * `modelSelect` (Dropdown UI): Populated directly from the `displayName` attributes of rows in `models_aa.json`.
* **Behavior:**
  * If `urlIn` receives a payload, it overrides the dropdown and loads from the incoming URL.
  * If `urlIn` is empty, it resolves the selected model from the AA catalog.
  * Newly loaded remote models can be saved back into `storage/models_aa.json` as a new AA row using the Dart AA writer.
* **Output:** Emits a standard `AaPayload` containing the resolved model attributes down the canvas edge.

---

### 3. Implement `Start` Node with Canvas Trigger Button

Create the `Start` execution catalyst node:

* **Node UI:** Render an interactive button labeled **`Go`** directly inside the node card on the canvas.
* **Behavior:**
  * Clicking **`Go`** launches canvas workflow execution starting from this node.
  * While active, visually indicate execution state on the button (`Running...`).
  * Emits an initial trigger signal as an `AaPayload` downstream to connected nodes (e.g., `LoadModel` or `IngestNode`).

---

### Task Summary for Claude:
1. Ensure `storage/models_aa.json` is formatted as a valid AA array and integrated with our Dart AA load/save code.
2. Build `LoadModel` using AA inputs/outputs.
3. Build `Start` with an inline `Go` button to trigger the reactive pipeline execution loop.

We need to implement the `ModelClassifierNode` in Dart using our `rcvs.json` schema for AA data interchange.

### Requirements:

1. **Model Catalog (`storage/models_rcvs.json`):**
   * Refactor model storage to use parallel `rows`, `cols`, and `vals` lists adhering to `rcvs.json`.
   * Use `package:d4m` to load `models_rcvs.json` into a Dart `AssociativeArray` instance.

2. **Node UI & Parameters:**
   * Build `ModelClassifierNode` extending our standard canvas node class.
   * **Picklist UI:** Extract all distinct model names from the AA where `col == "displayName"` and render them in a dropdown selector.
   * **Manual Input:** Provide a text field for a custom path/URL.
   * **Ports:**
     * `urlIn` (Optional String Port): Overrides the dropdown/manual path if connected.
     * `textIn` (Required String/AA Port): Accepts text input originating from the Inventory node output.
     * `classifiedAaOut` (Output Port): Emits an AA payload formatted in `rcvs.json`.

3. **Execution Logic:**
   * Resolve target model path (`urlIn` -> `manual input` -> `picklist selection`).
   * **Model Identifier Resolution:** 
     * If `sourceType == "huggingface"`, ensure the Hugging Face repo ID (e.g., `MoritzLaurer/ModernBERT-large-zeroshot-v2.0`) is passed directly to the classification runner endpoint.
     * If formatted as a web URL or local file path, pass the resolved path.
   * Pass text from `textIn` to the classification runner.
   * Format the classification results (document IDs vs. category scores) into an `AssociativeArray` object and serialize to `rcvs.json` for downstream nodes.

## Implement AA editing in the existing node/display architecture.

### Objective

Extend the existing AA display workflow so that an AA loaded from a file can be inspected and manually edited in the **Display Panel**.

The desired user workflow is:

```text
LoadFile
   │
   └── AA ───► Preview
                  │
                  ▼
            Display Panel
              [View] [Edit]
```

The important architectural point is:

**Edit is NOT a node.**  
It is a UI capability of the Display Panel.

Do not create an `EditAA` node for this feature.

---

### 1. Rename FileSource to LoadFile

Rename the existing `FileSource` node to `LoadFile`.

Preserve its existing behavior and connections.

The node must continue to provide the same two output ports:

1. Character stream
    
2. AA
    

Do not change the port types, port semantics, or downstream compatibility unless the existing implementation requires a mechanical rename.

The existing file-selection dialog should remain in place and continue to work.

Update all references, labels, serialization, registration, and UI text necessary to make `LoadFile` the canonical node name.

Where backward compatibility is already supported by the application, preserve it.

---

### 2. Keep Preview read-only

The existing Preview node should remain a presentation/inspection node.

Do **not** turn Preview itself into an editor.

Preview should continue to receive the AA and cause it to be displayed in the Display Panel.

However, when the Display Panel is displaying an AA, the panel should expose an editing capability.

---

### 3. Add Edit capability to the Display Panel

When the Display Panel is displaying an AA, provide a clear UI control such as:

```text
[View] [Edit]
```

The Edit control belongs to the **Display Panel**.

Clicking Edit should switch the panel from read-only display mode into AA editing mode.

The user should then be able to modify the AA interactively.

At minimum, support:

- editing an existing row/association
    
- adding a row/association
    
- deleting a row/association
    
- editing the associated value
    

Use terminology appropriate to the actual AA implementation. Do not force AA into a conventional rectangular spreadsheet abstraction if the underlying structure is an associative array.

An AA association should conceptually remain:

```text
(row key, column key) -> value
```

---

### 4. Use a working copy while editing

Do not mutate the source AA on every keystroke.

When Edit mode begins:

```text
source AA
   ↓
editable working copy
```

The user edits the working copy.

Provide explicit controls such as:

```text
[Apply] [Cancel]
```

or equivalent.

`Cancel` must discard unsaved changes.

`Apply` must commit the modified AA and make the resulting AA available to the application through the existing display/data model.

Do not silently modify the original loaded object merely because the user entered Edit mode.

---

### 5. Preserve the existing dataflow model

Do not introduce a new graph node merely to support manual editing.

Manual editing is a **human/UI operation**, not a graph transformation.

The conceptual model should be:

```text
LoadFile
   │
   └── AA ───► Preview
                  │
                  ▼
            Display Panel
             ┌───────────┐
             │ View      │
             │ Edit      │
             └───────────┘
                  │
             working AA
                  │
             Apply/Cancel
```

A future automated transformation such as:

```text
AA → AddRowNode → AA
```

would be a separate feature and should not be implemented as part of this task.

---

### 6. UI expectations

The AA editor should fit naturally into the existing Display Panel rather than looking like a separate application.

When in View mode, continue to use the current AA visualization.

When in Edit mode, provide a practical editing representation. A table/grid is acceptable if it accurately represents the underlying AA.

For example:

```text
┌──────────────────────────────────────────┐
│ AA: training_data                        │
│                                          │
│ Row Key       Column Key       Value     │
│ ──────────────────────────────────────── │
│ row1          col1             12        │
│ row1          col2             27        │
│ row2          col1             8         │
│                                          │
│ [+ Add Row]                              │
│                                          │
│ [Apply]   [Cancel]                       │
└──────────────────────────────────────────┘
```

If the existing AA implementation has a more appropriate native representation, use that instead.

---

### 7. Validation

Use the existing AA validation/data structures.

Prevent invalid edits from being committed.

At minimum:

- row and column identifiers must be valid for the AA implementation
    
- values must have the correct type
    
- incomplete new associations should not be committed
    
- duplicate associations should be handled according to existing AA semantics
    

Display useful validation errors in the panel rather than failing silently.

---

### 8. State and downstream behavior

Determine how the current application represents node outputs and panel state.

After `Apply`, ensure the modified AA is represented consistently with other node data.

Be careful not to break:

- existing Preview behavior
    
- node execution
    
- serialization
    
- graph persistence
    
- existing AA consumers
    
- character-stream output from LoadFile
    

Do not redesign unrelated parts of the application.

---

### 9. Implementation approach

Before changing code:

1. Inspect the existing `FileSource` implementation.
    
2. Identify how Preview sends data to the Display Panel.
    
3. Identify how the Display Panel currently determines the type of data being displayed.
    
4. Identify the existing AA representation and mutation APIs.
    
5. Follow the existing application architecture rather than introducing a parallel data model.
    

Then implement the smallest coherent change that provides the requested behavior.

Please identify the relevant files/classes first and explain briefly how the current dataflow works before making changes.

After implementation, provide:

- files changed
    
- architectural decisions
    
- any assumptions made
    
- any tests added or modified
    
- any issues that remain
    

Do not replace existing architecture with a new framework or component hierarchy unless the current implementation makes that unavoidable.

## D4MNode

You are implementing a new node called D4MNode in an existing DN pipeline 
application. DN has a Flutter frontend and a Python backend. The node catalog 
is already running with multiple existing nodes.

## STEP 1 — READ BEFORE YOU WRITE

Before writing any code, read the following:

1. Find two existing nodes in the Python BE — one simple (single input, 
   single output) and one with multiple ports if it exists. Read both 
   implementations fully. Understand:
   - How a node class is defined and registered in the catalog
   - How input ports are declared
   - How output ports are declared
   - How input data arrives at the node (method signature, data format)
   - How output data is returned
   - How node configuration (user-supplied parameters) is passed in

2. Find the corresponding Flutter widgets for those same two nodes. Read 
   both fully. Understand:
   - How a node widget is structured and registered
   - How port connection state is received by the widget
   - How user input fields (text boxes, etc.) are implemented
   - How configuration is sent to the BE
   - How the widget reacts to connections and disconnections

3. Read the AA (Associative Array) display node that is already implemented. 
   Understand how it receives and renders an AA, since D4MNode outputs an AA 
   and must be compatible with it.

4. Locate d4m.py in the codebase. It contains the AssocArray class with 
   D4M operations. If it is not present, the canonical implementation is 
   in the project files — read it before proceeding. Key facts:
   - AssocArray uses MATLAB-style call syntax: A("row: ", "col: ")
   - Trailing space on a selector string means prefix match
   - Trailing ", " means list match
   - ":" means all
   - Supports: +, &, >=, >, * operators
   - D4M expressions are evaluated with Python eval() in a namespace 
     containing the named input AAs

Do not write any code until you have read all of the above.

## STEP 2 — WHAT TO BUILD

Implement D4MNode following exactly the patterns you found in Step 1.

### Functional specification

D4MNode performs D4M algebraic operations on Associative Arrays (AAs).

**Inputs:**
- A variable-arity input port that accepts multiple AA connections.
- Each connected upstream node provides one AA.
- Each connected AA has a name. The name is the identifier used to 
  reference it in the D4M expression (e.g. A, B, orthodoxy, categories).
  Use the upstream node's output name or a user-assignable alias — 
  follow whatever pattern your existing multi-input nodes use. If no 
  such pattern exists, assign names sequentially: A, B, C, ...

**Configuration:**
- A single text field containing a D4M expression string.
- Examples of valid expressions:
    A("chunk: ", "score: ")
    A + B
    (A + B)("chunk: ", "score: ") >= 0.75
    A & B
    A * B
    A("chunk: ", "text,passed, ")

**Output:**
- A single AA output port, compatible with the existing AA display node.

**Execution:**
- When the node executes, evaluate the D4M expression string using 
  Python eval() with a namespace containing the named input AAs.
- The result must be an AssocArray instance.
- If evaluation fails, surface the error message on the node.

### Flutter widget specification

The widget has three visual zones, from top to bottom:

1. **Connected inputs list** — a read-only text list showing the name 
   of each currently connected upstream AA, one per line. This list 
   updates reactively as connections are made and broken. It sits above 
   the expression text area so the user can see which names are available 
   when writing their expression. If no AAs are connected, show a 
   placeholder: "No inputs connected."

2. **D4M expression text area** — a multi-line text input where the user 
   types the D4M expression. It should be monospaced font. Label it 
   "D4M Expression". It is the only editable field.

3. **Output port** — single AA output at the bottom of the node, 
   following your existing output port convention.

The overall visual style, sizing, border, and color scheme must match 
your existing nodes exactly. Do not introduce new design patterns.

### Python BE specification

Follow the exact class structure and registration pattern of your 
existing nodes. The core execution logic is:

    def execute(self, inputs: dict[str, AssocArray], expression: str) -> AssocArray:
        namespace = dict(inputs)
        result = eval(expression, {"__builtins__": {}}, namespace)
        if not isinstance(result, AssocArray):
            raise TypeError(f"Expression must return an AssocArray, got {type(result).__name__}")
        return result

Wrap this in whatever base class or method signature your existing 
nodes use.

## STEP 3 — VALIDATION

After implementing, verify:

1. D4MNode appears in the node catalog
2. Multiple upstream AA nodes can be connected to its input port
3. Connected node names appear in the list above the text area
4. Disconnecting a node removes its name from the list
5. A valid expression executes and the output AA can be connected 
   to the existing AA display node
6. An invalid expression surfaces an error without crashing the pipeline
7. The visual style matches existing nodes

## CONSTRAINTS

- Match existing code style, naming conventions, and file organisation exactly
- Do not introduce new dependencies unless essential and not already available
- Do not modify d4m.py — consume it as-is
- Do not modify any existing node — only add new files and registrations
- If you find that the existing framework does not support variable-arity 
  input ports, implement the minimum necessary extension to support it 
  and document clearly what you changed and why

I am redesigning and modernizing the surface syntax for D4M.jl (Dynamic Distributed Dimensional Data Model in Julia). 

### Background & Context:
D4M represents data using Associative Arrays backed by sparse linear algebra over arbitrary semirings. In the future, the backend will be offloaded to GraphBLAS (`SuiteSparseGraphBLAS.jl`), while the frontend maintains string/key indexing and dynamic mapping.

Currently, D4M’s expression and slicing syntax can be counter-intuitive, verbose, and error-prone (e.g., handling prefix queries, wildcard string ranges, boundary characters, and complex row/col conditions).

### Objective:
I want to design a set of Julia macros (syntactic sugar and DSL constructs) that make querying and manipulating D4M associative arrays clean, expressive, and intuitive. 

Additionally, this DSL will eventually serve as a target language for a RAG/SLM compiler that translates natural language requests into valid D4M query expressions. Therefore, the macros should be deterministic, highly readable, and easy for an LLM to generate accurately without syntax hallucinations.

### Please propose a categorized set of Julia macros covering the following areas:

1. **Prefix & Pattern Matching Sugar:**
   - Replacing manual string range/prefix logic (e.g., `StartsWith`, `EndsWith`, `Contains`, `Between` / range bounds).
   - Show how these can be written both as macro calls (e.g., `@StartsWith(...)`) and string literal macros (e.g., `k"prefix*"` or similar).

2. **Unified Query & Slicing Macro (`@q` or similar):**
   - Clean syntax for slicing rows and columns simultaneously using logical conditions or named dimension selectors (e.g., `rows = ...`, `cols = ...`).
   - Support for boolean/semiring context switching or masked operations.

3. **Semiring & Algebraic Sugar:**
   - Concise macros for executing matrix operations under non-standard semirings (e.g., min-plus, max-min, custom string/set operations) without verbose function-passing boilerplate.

4. **AST / LLM-Friendly Design Guidelines:**
   - Explain briefly why the proposed macro signatures are easy to validate via `macroexpand()` when generated by an SLM/LLM.

### Output Format:
For each proposed macro/construct, please provide:
- **Macro Name & Signature**
- **What Low-Level Code It Replaces** (Before vs. After example)
- **Proposed Julia Implementation Sketch** (How the macro expands into standard Julia / D4M range bounds)

## Tokenizing

## Chunking revisited

In our DoubleNaught codebase, update the chunking module/node to support sentence and paragraph boundary-aware chunking alongside the existing character-count chunking.

Requirements:
1. Update the configuration/interface to accept a chunking strategy parameter: `paragraph_sentence` (new) vs `character_count` (existing fallback/legacy).
2. Implement paragraph/sentence boundary chunking:
   - Split source text on paragraph breaks first (`\n\n`), then on sentence boundaries (`. `, `? `, `! `) if a paragraph exceeds the target size.
   - Assemble full sentences into a single chunk up to a user-configured `max_tokens` or `max_chars` threshold. Do NOT truncate mid-sentence.
   - Include optional parameters for `stride` (overlap) and `inject_eot` (appending the <|endoftext|> token to each chunk).
3. Preserve the original character-count chunking behavior as an explicit execution strategy or fallback mode so existing tests/pipelines do not break.
4. Add unit tests verifying:
   - Paragraph/sentence boundaries are preserved without splitting mid-sentence.
   - Character-count chunking continues to yield expected outputs when explicitly selected.
   - Output data contracts remain compatible with our downstream ingestion pipeline.