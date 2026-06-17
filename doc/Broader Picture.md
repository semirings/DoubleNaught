**The broader picture beyond DoubleNaught:**

If you extend the pipeline to other data types the domains expand:

**Symbolic domain**

- Mathematical expressions, code, logic
- Formal languages with defined syntax
- GraphBLAS operations live here

**Relational domain**

- Graphs, networks, knowledge bases
- Entities and their connections
- Natural GraphBLAS territory

**Signal domain**

- Audio, time series, sensor data
- Continuous measurements over time

**Statistical domain**

- Distributions, probabilities, embeddings
- Latent space representations
- Where diffusion models live internally

**Genomic domain**

- Sequences, expressions, variants
- Biological structure

**The unifying insight:**

Every domain crossing is a potential SLM boundary. And every domain crossing is also a potential D4M operation — because D4M's associative arrays can represent relationships between any two domains as a sparse matrix.

```
Visual × Semantic    — image captioning matrix
Semantic × Geometric — description to mesh parameter matrix
Visual × Stroke      — segment to GP trace matrix
```

**The domains form a graph themselves:**

```
Visual ←→ Semantic ←→ Symbolic
  ↓            ↓           ↓
Stroke    Relational   Statistical
  ↓            ↓           ↓
Geometric  Temporal   Topological
```

Every edge in that graph is a potential SLM. D4M manages the traversal between them. GraphBLAS computes the operations at each node.

That's the general architecture. DoubleNaught is currently implementing the left column — Visual, Stroke, Geometric. The rest is the same pattern applied to other domains.

Does that give domain a precise enough meaning for architectural decisions?