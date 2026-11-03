# TASK INSTRUCTION
Re-align SegForge (SF) module behavior with its original architectural bounds. 
Correct the recent implementation drift regarding downstream string/prompt processing and enforce strict boundaries between SF's core visual output and downstream pipeline nodes.

# CONTEXT & INTENT: [Core.Diagnose & Core.Implement]
- **Target Subsystem:** SegForge (SF)
- **Current Issue:** Implementation drift. A recent change caused SF to preview an AA in a manner not intended.  
- **Architectural Fact:** SegForge is an interactive, multi-pass segmentation workspace (Flutter frontend / Python backend using SAM 3 / Inpainting). SF's scope **ends at mask/image/string segment extraction**. SF itself does NOT handle downstream prompt polishing or text string transformation—that is handled downstream by dedicated pipeline nodes.

# SCHEMA & DOMAIN BOUNDARIES
## Allowed Operations (Inside SF)
- Multi-pass interactive image segmentation and mask extraction.
- Inpainting execution loops (e.g., Resolution-robust Large Mask Inpainting).
- Passing raw segment strings/payloads directly to output ports.

## Disallowed Operations (Outside SF Scope)
- Internal prompt polishing, text rewriting, or LLM string transformations within SF.
- Modifying upstream/downstream node responsibilities inside the SF workspace.

# EXECUTION GUARDRAILS
1. **Zero Re-Invention:** Do not pattern after past deprecated designs or attempt to re-introduce string polishing into SF.
2. **Explicit Interfaces:** Keep the Python backend API purely focused on segmentation/mask extraction parameters.

# RECENT DRIFT TO REVERT / CORRECT
The output of every node is an AA. 
1. The output of node Seg Forge port output llmpayload is full page of the original art. It should be an AA as a table showing row and col names and the image as val.
2. The output of LLM Documenter port output is a single image.   It should be an AA as a table showing row and col names and the images as vals.

# REQUIRED DELIVERABLE
1. **Diagnosis:** Identify the exact file/method where the boundary was crossed.
2. **Implementation:** Provide the minimal code/refactor required to revert the drift and restore clean node separation.
3. **Verification Step:** How to verify that raw output reaches the downstream node without internal modification.