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