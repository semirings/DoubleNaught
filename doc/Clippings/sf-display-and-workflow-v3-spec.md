# SF Display Layers & Selection Workflow — v3 Spec

Consolidates a long design conversation into one reference. Marks each
decision as SETTLED (ready to implement), OPEN (needs investigation before
implementation), or BLOCKED (needs an earlier open item resolved first).
Do not start implementation prompts from this doc until the OPEN items are
closed — several downstream decisions depend on their answers.

## 1. Display layers — what each one should mean

Today, `originalImage` is one conflated slot: it starts as the true
original but gets silently overwritten with the current pass's image after
every scrub. `OriginalImagePainter` and `RawCutoutsPainter` both read that
same slot, so "Original" and "Raw" have both been silently showing
current-pass content, not true original content, for any session with one
or more scrubs behind it.

**SETTLED — the split:**
- **Original** → pass 0, always, never overwritten by a scrub. Requires
  the frontend to retain pass 0's bytes as their own slot, separate from
  whatever the canvas currently displays — confirm this retention doesn't
  already exist before assuming it does (open sub-question, cheap to
  check: does `_uiImage`/`_imageBytes` get overwritten in place on scrub,
  losing pass 0 forever by the time you're several passes deep, or is
  pass 0 still fetchable from `session.original.bytes` on the backend
  regardless of frontend state?).
- **Current** (new, or `Final` renamed/repurposed — see below) → today's
  actual current-pass image. This is what `originalImage` has actually
  been showing all along; it just needs its own honestly-named slot
  instead of masquerading as "Original."
- **Masks** → unchanged rendering (diagonal-hatch fill per segment path).
  Behavior fix required — see §2.
- **Raw** → unchanged mechanism (`dstIn` cutout per segment, live on
  canvas) but re-sourced. **SETTLED: sources from Current, not Original.**
  The value of a live cutout preview is checking a selection against what's
  actually on screen right now, not against a long-since-scrubbed original.
- **Final** → **SETTLED: retire the per-segment `retouchedImage`/
  `FinalsPainter` compositing mechanism.** Nothing in this codebase has
  ever populated `retouchedImage` — it was built for a manual per-segment
  retouch workflow that never got implemented. What "Final" was actually
  trying to preview ("the whole page as it currently stands") is exactly
  what the **Current** layer already is, via the pass system that got
  built instead. Collapse Final into Current rather than maintaining two
  code paths for the same concept. If a genuinely distinct "Final" concept
  is wanted later (e.g. only captioned/kept objects composited, excluding
  discards) that's a new, separate feature — not a repurposing of the
  existing dead mechanism.

## 2. Masks must survive Clear Prompts

**OPEN — investigation was sent, result not yet in hand.** Confirmed live
that masks visually disappear after Clear Prompts. Two possible causes
with very different severity:
- (a) Display-only: `_segments` gets cleared as a side effect of whatever
  Clear Prompts calls (likely `/reset`, matching the pattern already found
  in `_scrubLamaBackground`), but committed `MaskRecord`s survive
  backend-side and just aren't re-fetched/re-rendered.
- (b) Real loss: committed records (`dataset_status == "keep"` or
  `held == true`) are actually being destroyed by an action whose name and
  documented purpose ("reset SAM3's grounding state") doesn't suggest that
  consequence.

**SETTLED, pending (a) being confirmed: Clear Prompts should NOT clear the
mask display.** It should reset grounding state only; committed masks stay
visible and re-selectable (this directly matters for the "a `keep` record
can be held and scrubbed again in a later pass" capability already built
and tested). If the investigation instead confirms (b), that is a
higher-priority correctness bug to fix first, before this display
behavior is worth implementing on top of it.

**SETTLED — precise definition of what Clear Prompts removes:** everything
where `dataset_status != "keep"`. ("Clears all selections not written to
the AA" was the original phrasing; under the live-AA model every selection
is technically "in" the AA the instant it exists, so `dataset_status`
is the actual criterion that captures the intent.)

## 3. Box/Point selection behavior

**OPEN — load-bearing and unconfirmed: was the PVS (single-instance)
switch for box/point selection ever actually implemented?** A full
implementation prompt for this (routing box/point through
`inst_interactive_predictor` instead of `add_geometric_prompt`'s exemplar
grounding) was written earlier in this project's history, but no
execution report was ever seen. Everything in §3 is BLOCKED on knowing
this. Check directly (grep for `inst_interactive_predictor` actually being
called from the box/point endpoints) before anything below is scoped as
an implementation prompt.

**SETTLED (design intent, implementation BLOCKED on the above):**
- Box selects only the object inside the box; Point selects only the
  object surrounding the click. Single-instance, not exemplar/multi-match.
- **New finding this session:** when a text prompt is supplied *alongside*
  a Box or Point selection, every object in the image matching that prompt
  is currently being selected too — not just the boxed/pointed object.
  Intent: **eliminate this.** A prompt supplied as a tag for a Box/Point
  selection should constrain grounding to just that one object; it must
  not also trigger an independent whole-image exemplar search.
  - If box/point are still on the PCS/exemplar path today (the likely
    case if the PVS switch was never executed): this matches the
    documented mechanism exactly — `add_geometric_prompt` "injects a dummy
    text prompt when none exists, then calls `_call_grounding`, which
    returns every instance above threshold." Supplying a *real* prompt
    instead of the dummy one very plausibly makes the box/point call
    itself ground on the text, exemplar-style, with the box/point barely
    constraining the search. Fix, if this is the case: bound
    `_call_grounding`'s results to the drawn box/point region, don't let
    the presence of a real prompt widen the search to the whole image.
  - If box/point are already on the PVS path: this would have to be a
    distinct bug — some second, independent PCS call firing off the
    supplied text alongside the PVS call. Different fix entirely (find
    and remove the extra call), not a grounding-bound adjustment.
- **OPEN, needs one more clarification:** is the prompt supplied alongside
  Box/Point meant purely as a grounding-constraint tag (SAM3-facing, not
  the same thing as a caption), or does supplying it also commit
  `dataset_status = "keep"` immediately? If the latter, this reverses the
  deferred-captioning design that implicit-discard depends on (an object
  selected via box/point could no longer be selected-without-committing,
  e.g. a word balloon headed for discard-via-scrub). Confirm which before
  implementing — this determines whether box/point selection remains
  compatible with the discard workflow at all.

## 4. Prompt/Select button state

**SETTLED:** disabled while Box or Point mode is active (mutually
exclusive with those two input modes — Select is specifically the
trigger for a standalone text-prompt search, not something used alongside
box/point).

## 5. LaMa Scrub gating — Hold's fate

**SETTLED, with an explicit tradeoff to carry forward, not silently
absorb:** Scrub becomes enabled whenever one or more objects are currently
selected — via Prompt, Box, or Point — rather than requiring a separate
Hold step. Scrub becomes disabled again immediately after a scrub
completes.

This **retires Hold as a distinct gating concept.** Two things worth
recording plainly:
- **What this resolves:** the Hold checkbox was confirmed, earlier in this
  project, to be genuinely undiscoverable in the UI ("I do not see any way
  for the user to command hold"). Removing the step instead of trying to
  make it more visible is a legitimate resolution, not a workaround.
- **What this trades away:** today, a multi-object text-prompt result does
  NOT become scrub-eligible until something additionally decides "yes,
  queue these." Under this change, the instant a prompt returns several
  objects, Scrub is live for all of them — no intermediate review gate
  built into the UI. This may be an acceptable tradeoff (nothing stops a
  human from visually reviewing before clicking Scrub), but it is a real
  reduction in built-in safety margin and should be stated as a conscious
  choice when this ships, not discovered later as a surprise.

**SETTLED — repurpose, don't just remove, the per-object checkbox list.**
The screenshot from this session confirms multi-object Hold was already
fixed at some point into a real per-mask-id checkbox list ("Hold
cee47989 for next scrub", etc.) — earlier project history calling
multi-hold "not yet built" was stale. Under Hold's retirement, this exact
list stops having anything to bind to for scrub-eligibility. Rather than
deleting it: **repurpose the same per-row-checkbox shape as the commit
mechanism for §6** — "commit this object to the AA" instead of "hold this
object for scrub." Same UI shape, different verb, different downstream
action.

## 6. Committing a selection to the AA

**OPEN — real, unresolved gap, more serious than initially assumed.**
There is currently no "Save Caption" button or equivalent commit action in
the running app. Before this can be spec'd further, confirm directly:
does submitting text in the Prompt card's caption mode currently set
`dataset_status = "keep"` at all (auto-commit on submit, no separate
button needed), or does typed caption text just sit in the field with
genuinely no path to the AA today? These are very different states and
determine whether §6 is "rename/clarify an existing action" or "build a
missing one."

**SETTLED, pending the above:** whatever the commit mechanism turns out to
require, it should be a **deliberate user action**, not implicit — and per
§5's repurposing, the natural mechanism is the same per-object checkbox
list already built for Hold, now meaning "commit to AA" per row, with
some explicit trigger (a button, analogous to today's "Scrub Selected
Regions") applying the commit to every checked row at once.

**SETTLED, unchanged, already correct:** scrubbed-but-never-captioned
objects are never written to the AA — this is the existing implicit-
discard design and remains correct under everything above.

## 7. Save

**SETTLED, unchanged:** Save writes the current session to file, on the
existing explicit-Save-only trigger. Nothing in this spec changes when or
how Save fires — only what state is available to be saved, per §1–§6.

## Open items, in priority/dependency order

1. **§2 — Clear Prompts investigation result.** Blocks confirming the
   Masks-survival fix is the right one (vs. a more serious data-loss bug
   needing priority attention first).
2. **§3 — Was the PVS box/point switch ever implemented?** Blocks all of
   §3's implementation, and blocks knowing whether the prompt-causes-
   whole-image-match bug has one root cause or two.
3. **§3 — Is a box/point-supplied prompt a grounding tag or a caption
   commit?** Blocks confirming box/point stays compatible with deferred
   captioning / implicit discard.
4. **§6 — Does caption submission already commit `dataset_status`, or is
   there truly no commit path today?** Blocks scoping §6 as small
   (rename/clarify) vs. large (build a missing mechanism).
5. **§1 — Does the frontend still retain pass 0's bytes after several
   scrubs, or would fixing "Original" require a new fetch path?** Cheap
   to check, blocks implementation but not further design.

Do not write implementation prompts against §2, §3, or §6 until their
respective open items are resolved. §1, §4, §5, §7 are ready to implement
once §1's retention question is answered.
