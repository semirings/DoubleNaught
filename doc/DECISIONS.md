# DN decisions log

Newest first. One entry per decision. Status: designed | implemented | abandoned.
Add an entry in the same change as the work. Say "verified in code" only if
you read it.

## 2026-11-02 — Preview drift: tables, not "first image"
Status: implemented; Flutter tests written but NOT run (no Flutter in the session).
Cause: `PreviewNode._buildContent` (commit 8acedf0, 2026-10-27) turned any AA with
an `image_b64`/`bytes` column into ONE picture via `AaPayload.value` (first match),
so Seg Forge `llmPayload` showed only the page and the Documenter output one image.
Fix: the picture shortcut applies only to one row whose other columns are image
metadata (`_pictureMetaCols`); everything else is a table. `AaDataFrame` now draws
`image_b64`/`bytes` cells as thumbnails (decoded once per cell, text fallback).
SF itself was not at fault: its export and `seg_forge_mapping.dart` are unchanged.
Tests: `frontend/test/widgets/preview_picture_vs_table_test.dart`.

## 2026-11-02 — Blender ontology, revision 1
Status: written, loads in LinkML (SchemaView), and COMPILED to
`storage/ontologies/blender_domain_ontology.parquet` (+ `.tsv`), 205 triples;
not wired to any checker or to the backend endpoint.
`ontologies/blender_domain_ontology1.yaml` revises `blender_domain_ontology.yaml`
(left untouched) after a review against live Blender 5.2.3: fixed engine ids
(`CYCLES`, `BLENDER_EEVEE`, `BLENDER_WORKBENCH`; `EEVEE_NEXT`/`WORKBENCH` raise
TypeError), upper-case SensorFit, depth/segmentation passes, Freestyle as a
switch not a pass, added Light/Transform/MaterialBinding/GeometryNodesInput/
RenderOutputConfig, `blender_version`, link slots between subgraphs, and
machine-readable guardrail annotations next to the prose `rule`. Guardrails are
only enforceable once a checker reads them (OntologyAnvil handles only
`disjointWith|`/`requires|` today; no enum or range checks).
Not modeled: World, Armature, shader node-tree bindings, animation/per-frame state.
Compiler: `scripts/compile_linkml_to_aa.py` (new). Verified by recompiling
`prompt_governance_ontology.yaml`: identical to the existing parquet (47 = 47).
It refuses YAML it doesn't understand rather than dropping it. `--extras` adds
rule/guard|/in_subset/multivalued|/minimum_value| rows the engine ignores today.
Guardrail annotations compile to `guard|*`, not `requires|*`, because the engine
reads `requires|X` as "slot X must be filled". Julia was not available here, so
OntologyAnvil's `build_engine` was not run on the new parquet.

## 2026-10-31 — Qwen prompt and names (ontology-aware first drafts)
Status: implemented in code; NOT run end to end (SF tests need the Mac env).
- No LoRA is trained yet: this stage curates the training data, so Qwen is the
  plain base model and its prompt is free to change.
- SF captioner prompt now comes from an .md file read on every run
  (`SF_CAPTIONER_PROMPT_FILE`, default `DoubleNaught/storage/prompts/qwen_caption.md`),
  falling back to "Describe this image.". `{{text_tag}}` is filled per segment.
  Chosen over routing through Seg Forge's `segmentPromptInput` because that
  template is sent once at session creation (stale for old sessions) and DN tests pin it.
- Names live in SF's `text_tag`. `segment.md` (Documenter) now keeps a given
  name and otherwise uses a plain descriptor, never an invented name; the
  original is `segment.pre-ontology.md`.
- Not done: `panelPromptInput` on Seg Forge is still present (dead). Removing
  it risks saved canvases (`dangling_port_edge_test`).

## 2026-10-31 — Qwen captioner supplies the first caption
Status: implemented in SegForge (verified in code); my earlier "not found" was
because only the DoubleNaught repo was connected. Qwen writes `draft_caption`;
a person approves/edits it into `caption`; the export carries `caption` only,
which becomes `good_caption`. Then Gemini -> `better_caption`, then guardrail ->
`best_caption`. Panels have no caption in the export, so they are skipped.

## 2026-10-29 — Ontology guardrail in the Documenter
Status: implemented (verified in code, uncommitted).
Caption task: improve -> extract -> validate (OntologyAnvil.jl) -> correct.
New output columns `better_caption`, `best_caption`. Save Antelora prefers `best_caption`.

## 2026-10-29 — Ontology stored as AA parquet
Status: implemented. LinkML YAML -> AA triples -> parquet; backend reads parquet
only. Creature added after auditing 88 `mccay` captions (~10% were animals).

## Open issues
- `segment.md` says "no guessed names" but the guardrail requires `entity_name`;
  the correct step may invent names. Options: allow plain descriptors, or change
  what `has_entity_name` counts.
- `panelPromptInput` unconnected; no `panel.md` exists.
- Add `valid` / `violations` output columns.
- Lower temperature (~0.2) and pin the Gemini model id.
