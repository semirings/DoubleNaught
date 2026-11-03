# DN current state — caption + ontology pipeline

Last verified: 2026-10-31 (read from the checkout; nothing was run).
Update this file in the same change as any edit to the nodes, prompts or
ontology files named below. Keep it to one page.

## Graph (as of the Oct 2026 screenshot)

Load File (page image) -> Seg Forge (`image`)
Load File -> Prompt -> Seg Forge (`segment prompt`, `panel prompt`)
Seg Forge `llmPayload` -> LLM Documenter (`astIndex`)
Secure Settings (Gemini) -> Documenter `authInput`
Load File -> Prompt (annotator, ~85 lines) -> Documenter `promptInput`
Documenter `panelPromptInput` -> NOT CONNECTED (errors if any panel has a caption)
Documenter `documented` -> Preview, Save Antelora (`captions`, set `mccay`)

Prompt nodes read their text from `*.md` files via Load File
(`storage/prompts/`).

## LLM Documenter (caption task)

Source: `frontend/lib/widgets/nodes/implementations/llm_documenter_node_widget.dart`,
`.../llm/caption_task.dart` (has uncommitted changes). The task is chosen by
the data: payload schema `sf.llm_payload/v1`.

Rounds per segment/panel row:
1. Improve (Gemini, vision) -> `better_caption`
2. Extract (Gemini, text) -> class (Character/Creature/Prop/Setting/null) + has_entity_name
3. Validate -> backend `POST /ontology/validate` (OntologyAnvil.jl)
4. Correct (Gemini) only for flagged rows -> `best_caption`

Output columns: `good_caption` (input `caption` column), `better_caption`,
`best_caption`, `kind`, `panel_id`, `pass`.
Save Antelora writes `best_caption`, else `better_caption`.
Max Tokens is raised to 2048 for improve/correct; temperature applies to all rounds.

Known limits: class label is model-self-reported (unparseable -> check skipped);
correction is not re-validated; output has no valid/violations column;
panel captions often extract as null/Setting and skip the check.

## Ontology

- Authoring: `ontologies/prompt_governance_ontology.yaml` (LinkML), plus `.owl.ttl`.
- Compiled to an AA of (rowKey, colKey, val) triples:
  `storage/ontologies/prompt_governance_ontology.parquet` (+ `.tsv` mirror).
- Runtime: backend `ontology_ops.py` reads the PARQUET, builds the engine once
  per path (cached, no invalidation: restart backend after recompiling).
- Engine: `OntologyAnvil.jl` — checks `disjointWith|` (class exclusivity) and
  `requires|` (only `entity_name`) triples. Range checks (`carried_by`) not done.
- Verified 2026-10-31: YAML and parquet are in sync (47 triples; Creature present).
- `dn_prompt_ontology.*` is about prompting Claude about DN; not used in this graph.
- Blender ontology (separate, not in this graph): `ontologies/blender_domain_ontology1.yaml`
  -> `storage/ontologies/blender_domain_ontology.parquet` via
  `scripts/compile_linkml_to_aa.py ... --extras`. Not read by any backend endpoint yet.

## Seg Forge captioner (Qwen) — found 2026-10-31 in the SegForge repo

`SegForge/backend/captioner.py`: Qwen2-VL-2B (+ optional LoRA adapter) via
`mlx_vlm generate`, run by the "Run captioner" button (`POST /captioner/run`).
Prompt comes from `storage/prompts/qwen_caption.md` (re-read each run; `{{text_tag}}` filled per segment; falls back to "Describe this image.") Results are stored as `draft_caption`,
never `caption`. Only a person's edit/approve (`/mask/caption`) sets `caption`
and `keep`. The export (`sf.llm_payload/v1`, include=keep) sends only `caption`,
so DN's `good_caption` = the human-approved Qwen draft (or the human's edit).
Panels: the SF export has no panel `caption`, so panel rows reach the Documenter
with no caption and are skipped (panel captions are not improved today).

## Not implemented / unverified

- No node uses the ontology to constrain image generation (Hi3D inputs).
- Qwen prompt change and `segment.md` name rule are untested end to end.
