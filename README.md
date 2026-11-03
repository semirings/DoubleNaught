# DoubleNaught (DN)

An experimental node-graph toolkit for working with small language models and the data around them. Nobody knows yet what SLMs are ultimately for, so DN is built to adapt: you wire nodes together on a canvas, and every node passes its result to the next one as an **associative array**.

The workflow DN is mainly used for today is turning comic pages into captioned LoRA training data: segment a page, caption the segments, check the captions against an ontology, and save the result as a training set. The training and generation nodes then use that set.

DN is a macOS app (Flutter) with a Python backend, and a Julia library underneath for the array algebra. Segmentation is done by its sibling project, **SegForge** (SF).

## How it fits together

| Part | Where | What it is |
|------|-------|------------|
| `double_vision` | `frontend/` | Flutter macOS app: the canvas, the nodes, the focus panel |
| `double_touch` | `backend/` | FastAPI service on port **8400**: file I/O, D4M, LLM, training, ontology checks |
| D4M.jl | `../D4M.jl` | Associative-array algebra, reached from Python through `d4m_juliacall_bridge` |
| OntologyAnvil.jl | `../OntologyAnvil.jl` | Rules engine that validates entities against an ontology |
| SegForge | `../SegForge` | Interactive segmentation workspace (SAM 3, inpainting), port **8401**; DN's Seg Forge node launches it |

### Everything is an associative array

The output of every node is an associative array (AA): a sparse table of `(row, col, val)` triples. Ports carry AAs, the Preview node shows them as a table, and saved data is stored as triples. The formal definition is in `aa-spec.pdf` (Kepner et al.).

Two rules follow from that:

- Array algebra (⊕, ⊗, matrix product, lift/drop) goes through D4M.jl and GraphBLAS. Don't write your own.
- It runs on the backend. The Dart app holds and passes AAs but never computes on them.

### Nodes

Registered in `frontend/lib/config/node_registry.dart`:

- **Data:** File Source, URL Source, Load File, Save File, Save Antelora, Collect Antelora, Fetch, Inventory, Categorize, Preview, Image Display
- **Code:** Function Extraction
- **Formatting:** JSONL Formatter, Chunk, Tokenizer
- **AI:** LLM Documenter, Secure Settings, Prompt, Model Classifier, SAM3, Balloon Scrub, Seg Forge
- **Compute:** Polyglot Exec, D4M, Start
- **Training:** Split, Review, Model Builder, Generate, Image LoRA Trainer, Image LoRA Cloud Trainer, LoRA Trainer, Caption, Load Model

Each node follows the shared Wait / Execute / status behavior in `frontend/UX_UI/GLOBAL_UX_CONTRACT.md`. API keys live in the Secure Settings vault; a key is redeemed on the Dart side and never sent to the backend.

### The captioning workflow

```
Load File ─► Seg Forge ─llmPayload─► LLM Documenter ─► Save Antelora
             (SAM 3 + Qwen drafts)    (Gemini + ontology check)
```

1. **Seg Forge** segments a page. A Qwen captioner in SF drafts a caption for each segment, and you review and approve them. The approved caption becomes `good_caption`.
2. **LLM Documenter** improves each caption (`better_caption`), checks it against the ontology through `/ontology/validate`, and corrects any that fail (`best_caption`).
3. **Save Antelora** writes the pages to `storage/antelora/<set>/<page>/`, using `best_caption`.

Prompts for these steps live in `storage/prompts/*.md` and are fed in through Load File and Prompt nodes.

### Ontologies

Guardrails for prompts and captions are written as LinkML in `ontologies/*.yaml`, compiled to an associative array of triples, and stored as parquet in `storage/ontologies/`. The backend and OntologyAnvil read the parquet, not the YAML. After editing a YAML, recompile and restart the backend:

```sh
python scripts/compile_linkml_to_aa.py ontologies/<name>.yaml storage/ontologies/<name>.parquet \
    --tsv storage/ontologies/<name>.tsv --extras
```

The compiler refuses YAML it does not understand, rather than dropping it. Leave off `--extras` for `prompt_governance_ontology`; it reproduces the existing parquet exactly that way.

## Requirements

- macOS (the app builds with `flutter build macos`)
- Flutter
- Python 3.10 or later, and [uv](https://docs.astral.sh/uv/)
- Julia, with the packages in `Project.toml` and `Manifest.toml`
- The sibling checkouts above: `D4M.jl`, `OntologyAnvil.jl`, `SegForge`, and `d4m_juliacall_bridge`
- Optional extras for the backend: `local` (torch, transformers), `text` (mlx-lm), as listed in `backend/pyproject.toml`

## Run

`run.sh` is the task runner (zsh):

```sh
./run.sh up            # start both backends as launchd agents, build and launch the app
./run.sh up --no-fe    # backends only
./run.sh status        # per-service pid, port and health
./run.sh logs [dn|sf|fe]
./run.sh re            # restart: dn, then up
./run.sh dn            # stop the app and both backends
```

For development: `./run.sh BE` runs the backend alone on `http://127.0.0.1:8400`, `./run.sh FE` runs the app, and `./run.sh all` frees the port, starts the backend, waits for `/health`, then runs the app.

Ports: DN uses 8400 and SF uses 8401, so both run together. Override the backend port with `DOUBLE_TOUCH_PORT`, and point the app at it with `./run.sh FE --dart-define=DN_BACKEND_URL=http://127.0.0.1:<port>`.

### Build

```sh
./bld.sh [dn|sf|all] [--fe] [--be] [--no-clean] [--restart] [--dry-run]
```

This builds the frontend (`flutter build macos --debug`) and syncs the backend environment. DN does not build SF's app on its own: the Seg Forge node opens whatever SF app was last built, so run `./bld.sh sf` or `./bld.sh all` after changing SF. Running backends keep serving old code until you pass `--restart` or restart them.

## Test

```sh
cd backend && uv run pytest        # backend
cd frontend && flutter test        # frontend
```

## Layout

```
frontend/       Flutter app (double_vision); UX_UI/ holds the node design scripts and prompts
backend/        FastAPI service (double_touch)
ontologies/     LinkML ontologies (YAML source, OWL/TTL renderings)
scripts/        compile_linkml_to_aa.py and other helpers
storage/        antelora/ (training sets), ontologies/ (compiled parquet), prompts/ (*.md)
doc/            notes; STATE.md (how things work now) and DECISIONS.md (what was decided)
aa-spec.pdf     the associative-array specification
CLAUDE.md       instructions for Claude Code sessions
```

## Further reading

- `doc/STATE.md`: the current pipeline, the Documenter's rounds, the ontology flow
- `doc/DECISIONS.md`: dated decisions and their status
- `frontend/DESIGN.md`: the visual design tokens
- `frontend/UX_UI/GLOBAL_UX_CONTRACT.md`: the node behavior contract
