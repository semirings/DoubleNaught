# SF v4 — Greyscale Pipeline, Layer Model, Mode-Switching, Panel Cutouts

Consolidates a long design conversation into one reference, the same way
sf-display-and-workflow-v3-spec.md did for the layer/selection rework.
This supersedes v3's §1 (Original/Current split) where the two disagree —
v4 extends that split rather than replacing its mechanism.

## 1. The pipeline, as settled

1. Original color artwork is uploaded. Retained permanently, unaltered —
   this is layer 0, never touched by anything downstream.
2. Greyscale conversion runs once, against layer 0. This is pass 0 of the
   working sequence AND layer 1 — the fixed, permanent starting point
   every subsequent step derives from. Layer 1 is never overwritten.
3. WB (word-balloon) scrub runs against layer 1, producing layer 2.
   One layer — the state after all balloon removal is complete, not one
   layer per balloon.
4. Segment & Scrub (S&S) rounds run against layer 2 initially, then
   against the previous round's own result — sequential, compounding,
   same relationship passes already have today (each round builds on the
   last, the same way image_for_pass(N) already derives from N-1). This
   produces layer 3, continuously overwritten as rounds proceed. One
   layer regardless of how many rounds a given page needs (foreground
   objects, then whatever they reveal, repeated until done).
5. Panel cutout detection and capture happen as their own step (see §4) —
   NOT a layer; geometry only, exported at LLM-transfer time like masks.
6. Save writes the AA to disk, same explicit-Save-only persistence
   already in place.
7. LLM transfer (button: Execute) — masks (segments and cutouts both)
   get their pixel content filled from GREYSCALE, not color, at the
   moment of transfer. See §5.

**Explicitly rejected, and why:** a per-S&S-round layer. Traceability
("what did I select at round 3") is already available from the data —
every MaskRecord carries its own pass_, geometry, caption, and
dataset_status independently of how many display layers exist — and the
AA Preview table already gives a non-overlapping, per-mask view where
overlap on canvas would otherwise be confusing. Building a canvas-level
"click a row, see it highlighted" feature is deferred until a real need
for it arises; nothing about deferring it forecloses building it later,
since the underlying data it would read already exists.

## 2. The layer model — six fixed layers, display-only

**SETTLED.** Not pass-count-dependent, not dynamic — six checkboxes,
known in advance, same Display Layers card mechanism already built
(independent multi-select, v3's existing pattern extended, not replaced).

| # | Layer | Source | Fixed/dynamic |
|---|-------|--------|----------------|
| 0 | Original | True color upload | Fixed forever |
| 1 | Greyscale | Greyscale(layer 0) | Fixed forever (pass 0) |
| 2 | WB-scrub result | WB scrub applied to layer 1 | Fixed once WB scrub completes |
| 3 | S&S working layer | Accumulating S&S rounds, from layer 2 | Updates every S&S round |
| 4 | Masks — diagonal hatch | Existing Masks layer, unchanged | Tracks layer 3's current masks |
| 5 | Masks — greyscale fill | Mask geometry, pixels from layer 1 (or layer 3's greyscale basis) | Tracks layer 3's current masks |
| 6 | Masks — color fill | Mask geometry, pixels from layer 0 | Tracks layer 3's current masks |

"Masks" in layers 4-6 means both segments and cutouts — every
MaskRecord, regardless of how it was selected (Prompt/Box/Point/Balloon
Scrub).

**Multi-select across all six, confirmed explicitly over a radio-button
alternative.** Display Layers already supports combining layers (e.g.
Masks + Original together); layers 4-6 must stay independent checkboxes
for the same reason — combining a fill-style mask layer with layer 3 or
layer 0 underneath it (e.g. "show greyscale-filled masks over the
current working canvas") is a real, intended use case, not a hypothetical
one. Radio-button exclusivity would block exactly that combination.

**One caveat, worth stating explicitly rather than leaving implicit:**
checking more than one of layers 4/5/6 simultaneously has a defined paint
order (whichever renders last/on top wins for a given mask's pixels), not
a blended result — matching how layer stacking already behaves today
(e.g. Original + Current both checked shows whichever paints on top).

## 3. Mode-switching: Comix / Poster / Cine

**SETTLED (mechanism), Cine flagged as its own open architectural
question, unchanged from prior discussion.**

- One shared engine (SFSession, pass chain, selection/hold/caption/scrub,
  save/resume) — unchanged regardless of mode. Comix and Poster are both
  pure toolset differences over this same engine; no new session shape.
- Mode determined by a new launch parameter (SEGFORGE_MODE or similar),
  mirroring LaunchConfig's existing env-var pattern (SEGFORGE_IMAGE_URL,
  SEGFORGE_SESSION_ID, SEGFORGE_BACKEND_URL).
- SF's sidebar renders a mode-to-card-list mapping — each mode shows only
  its relevant cards (Comix: Balloon Scrub, Panel Split, greyscale
  toggle, alongside the general-purpose cards; Poster/Cine: their own
  sets as those get scoped).
- DN gets a mode selector (radio button) on the Seg Forge node. Open,
  still-undecided: what happens when the selected mode doesn't match
  what's actually upstream (e.g. Comix mode selected but a video file is
  wired in) — warn, block, or allow silently. Needs a decision before
  the DN-side node work is scoped.
- Sequencing, confirmed: Comix first (most toolset already exists —
  Balloon Scrub, Panel Split, greyscale), then Poster (same engine, new
  toolset, second confirmation the "new domain = new card set" pattern
  holds generally), then Cine last — Cine may not fit the per-image
  SFSession model at all (temporal sequence management is a materially
  different problem) and should get its own design pass before being
  assumed to fit this same mode-switching mechanism.
- Dependency: the five-card extraction (Prompt, Box Select, Point Select,
  Objects Selected, Save) out of main.dart into their own widget files
  should land BEFORE mode-switching is built — the mode-to-card-list
  mapping is far cleaner against extracted widgets than inline build
  methods.

## 4. Panel cutouts

**SETTLED.** Geometry-only, exactly like masks — a `panel_bounds` record
(bbox + which pass/layer it was captured against), never baked pixels
during the session. Pixels only get materialized at LLM-transfer time,
reading the stored bounds against whatever the relevant layer's image is
at that moment — same deferred-extraction pattern build_sf_payload
already uses for mask crops.

Panel-bounds detection needs the same validate-before-build treatment the
balloon detector got: find a candidate panel-detection model/tool, run it
zero-shot against real Little Nemo pages, check it BEFORE building the
capture mechanism around it. Little Nemo's irregular/non-grid panel
layout is a known risk to check for specifically, not assumed away by a
tool built for modern comic-grid layouts.

Panel crops at export: sourced from greyscale (layer 1 or the relevant
layer), same rule as mask crops — see §5. No captions are attached to
panel crops themselves; they are pure visual layout/action context for
the LoRA, independent of any mask's caption data.

## 5. LLM export — the greyscale-fill rule

**SETTLED.** At the moment of transfer (button: Execute), every mask
(segment or cutout) gets its pixel content filled from GREYSCALE, not
color — a direct change from today's build_sf_payload, which currently
sources crops from each pass's COLOR image (pass_images[mask.pass_]).
This is a real, deliberate reversal of the crop-sourcing design built
earlier this project, not an extension of it — build_sf_payload's crop
logic needs to change its source, not just gain a new optional field.

Panel-bounds crops follow the identical rule — greyscale, not color —
confirmed as one shared rule for both segments/cutouts and panels, not
two separate sourcing paths.

## 6. The formatted, editable prompt field

**SETTLED.** A new field on MaskRecord, separate from and alongside the
existing text_tag (which keeps its current meaning — a short provenance
label, never reaching SAM3). The new field:
- Is a draft prompt the user can write/edit, intended to eventually be
  submitted to an LLM for caption improvement.
- Is explicitly MORE structured/robust than a one-word label — described
  as "formatted," not just longer. Exact internal shape (one multi-line
  free-text block vs. real sub-structure composed into a final string)
  is still open and needs resolving before implementation.
- NEVER reaches SAM3's grounding call. The dummy-"visual"-grounding fix
  from the point-selection hijack investigation stays exactly as-is,
  completely untouched by this addition. This field is purely downstream
  — attached to the mask record, read only by the eventual LLM-transfer
  step.
- Reflects a real, deliberate workflow shift from this project's original
  design: Box/Point selection, with this richer prompt attached, is now
  the PRIMARY selection mechanism for most work; SAM3's text-prompt
  concept search (Prompt card) remains available and is not being
  deprioritized, but the earlier assumption that it should be the first
  resort and Box/Point merely a fallback no longer reflects how this is
  actually being used.

## 7. Open items, in priority order

1. **Mismatched mode/upstream-input behavior** (§3) — blocks scoping the
   DN-side radio button node.
2. **Panel detector validation** (§4) — blocks building panel-cutout
   capture; same gate the balloon detector already passed.
3. **The formatted prompt field's exact internal structure** (§6) —
   blocks its UI/schema implementation; free-text vs. real sub-fields.
4. **Five-card extraction** — not blocked on anything, should land first
   as the dependency for #1's eventual implementation.
5. **Cine's architectural fit** — not blocking Comix or Poster work, but
   needs its own design pass before assumed to share the mode-switching
   mechanism built for the other two.

Do not write implementation prompts against §3's DN node, §4's capture
mechanism, or §6's field until their respective open items are resolved.
§1, §2, and §5 (the pipeline reorder, the six-layer model, and the
greyscale-export rule) are internally consistent and ready to scope as
implementation work once the five-card extraction (already in progress)
is confirmed done.
