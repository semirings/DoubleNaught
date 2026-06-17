**Good to nail this down precisely. Domain means the fundamental nature of the data — its structure, its representation, its semantics.

**The domains you're likely to encounter in DoubleNaught specifically:**

**Visual domain**

- Raw pixel data
- Images, frames, textures
- What things look like
- SLM operates on appearance

**Geometric domain**

- Coordinates, vertices, edges, faces
- Spatial relationships, topology
- What things are shaped like
- SLM operates on structure

**Semantic domain**

- Text, captions, labels, categories
- What things mean
- Natural language descriptions
- SLM operates on meaning

**Stroke domain**

- GP strokes, bezier curves, vector paths
- How things are drawn
- Distinct from geometry — a stroke is an artistic decision, not a measurement
- SLM operates on mark-making

**Temporal domain**

- Sequences, animations, pose transitions
- How things change over time
- Frame sequences, motion curves
- SLM operates on change

**Topological domain**

- Mesh connectivity, UV maps, rigging hierarchies
- How parts relate and deform
- Distinct from geometry — topology is about relationships not positions
- SLM operates on structure of structure

**Correspondence domain**

- D4M associative arrays
- Relationships between entities across other domains
- Which visual segment maps to which geometric primitive
- SLM operates on mappings**