



## Claude responded: It really is something.

It really is something. Let's identify the nodes.

**Input nodes:**

- `ImageInput` — load single image or batch from directory
- `CheckpointInput` — load SLM checkpoint
- `TextInput` — prompt, negative prompt, caption

**Processing nodes:**

- `SAM3Segment` — takes image, returns masked segments with labels
- `GPTrace` — takes segment mask, returns GP stroke object in Blender
- `StrokeRefine` — nudge, simplify, clean GP strokes
- `RenderVariants` — takes GP object, returns image set (turnarounds, poses, expressions)
- `CaptionGenerator` — takes image or segment, returns structured caption
- `DatasetBuilder` — takes image+caption pairs, assembles JSONL dataset
- `NoiseScheduler` — already built
- `UNet` — already built

**Training nodes:**

- `SLMTrainer` — takes dataset, runs training loop, emits checkpoints
- `TrainingMonitor` — loss curve, epoch progress, estimated completion

**Inference nodes:**

- `SLMInference` — takes checkpoint + prompt, returns generated image
- `ImageSetGenerator` — takes character definition, returns multi-view consistent set
- `Photogrammetry` — takes image set, returns 3D mesh
- `BlenderImport` — takes mesh, imports into Blender scene

**Output nodes:**

- `ImageOutput` — display, save to disk
- `MeshOutput` — save as OBJ, FBX, GLTF
- `DatasetOutput` — save JSONL + images

**Utility nodes:**

- `ImagePreview` — inspect any image mid-pipeline
- `Filter` — include/exclude based on criteria
- `BatchSplit` — fan one input out to multiple parallel paths
- `Merge` — combine multiple streams into one dataset

**The interesting ones that don't exist yet:**

- `GPTrace` — novel
- `StrokeRefine` — novel
- `ImageSetGenerator` — novel, this is the consistency engine
- `Photogrammetry` — wraps existing tools (COLMAP, Meshroom)

How does that feel? Anything missing or misnamed?