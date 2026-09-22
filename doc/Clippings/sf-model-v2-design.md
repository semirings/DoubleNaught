# SF Model v2 — Reconciled Design

Supersedes the model in `sf-lama-integration-spec.md` and as currently built
in `sf_engine.py`. That earlier model conflated two independent decisions
into one green/red binary and capped peeling at two passes; neither survives
contact with the actual workflow. This document is the corrected version —
read it before writing any implementation prompt against this area, and
prefer it over anything in the original spec where the two disagree.

## 1. The workflow, as stated

1. User decides which objects in an image are worth captioning.
2. Background objects obscured by foreground ones require peeling: select
   foreground objects one by one, caption the keepers, leave the rest
   (e.g. word balloons) uncaptioned.
3. Selected foreground objects — captioned or not — get held, then scrubbed
   as a batch. Once scrubbed, keepers' crops are saved; discards are gone.
4. Once scrubbing clears a region, whatever's revealed can itself be
   selected, captioned, and held — and the same select→decide→hold→scrub
   loop applies again, at any depth. Peeling is unbounded, not two passes.
5. A background object, once captioned, isn't necessarily final — it can
   later be selected for scrubbing too, to reveal something further behind
   it, even after its own caption is saved.
6. Finishing one image and starting another continues building toward the
   same eventual training set.

## 2. The core correction: two independent axes, not one

The old model (`MaskType.IN`/`OUT`) used a single flag to mean both "does
this get scrubbed" and "does this get captioned." That's wrong on both
sides of the mapping:

- A captioned keeper still gets scrubbed — scrubbing is how the region
  behind it gets revealed, not a fate reserved for unwanted objects.
- A discarded object (a word balloon) also gets scrubbed — it's in the same
  held batch as any keeper marked in the same pass.
- "Discard" only ever meant "don't caption this." It never meant "don't
  scrub this."

So every selected `MaskRecord` needs **two independent fields**, not one:

- **`dataset_status`**: `unassigned` | `keep` (captioned) | `discard`
  (e.g. a word balloon — no caption, never exported)
- **`held`**: whether this record is currently sitting in the pending-scrub
  queue, waiting for the next batch LaMa call. Independent of
  `dataset_status` — a record can be `keep` and `held`, `discard` and
  `held`, or (after its batch has run) not held at all regardless of status.

## 3. Pass model: unbounded chain, not `FOREGROUND`/`BACKGROUND`

`sf_engine.py`'s `Pass` enum (`FOREGROUND`, `BACKGROUND`) and
`run_lama_pass`'s one-shot guard (`raise RuntimeError` on a second call) are
both wrong under §1.4/§1.5. Replace with:

- `pass` as an incrementing integer (or numeric string, to match the
  existing Parquet column convention) — 0, 1, 2, ... n. Pass 0 is always the
  original image.
- `run_lama_pass`-equivalent becomes repeatable: any pass can be scrubbed
  (its currently-`held` masks unioned and sent to LaMa) to produce the next
  pass, as many times as the workflow calls for. No cap, no "already run"
  guard.
- A pass's revealed objects are selectable and cross both axes normally —
  including, per §1.5, being `held` and scrubbed again later even after
  being marked `keep` and captioned. Nothing about being captioned makes a
  record ineligible for a later hold/scrub cycle.

## 4. Held-batch scrubbing (unchanged from the original batching decision,
   re-scoped)

The original spec's "batched with a review gate" call survives, just with a
different meaning for what's in the batch:

- Selecting an object doesn't scrub it immediately. It sets `held = true`
  (and, independently, whatever `dataset_status` the user picks — before,
  during, or after holding; order doesn't matter to the model).
- The user triggers a scrub of the current pass's held set (`LBSCard`'s
  existing "Scrub Selected Regions" button / pending-count line already
  matches this shape and needs no redesign).
- Scrubbing unions every `held` record's geometry in the current pass
  (`keep` and `discard` together — status doesn't affect whether something's
  in the union, only whether it's captioned), runs LaMa once, produces the
  next pass, and clears `held` on everything that was in the batch.
- A `discard` record needs no persistence past this point — its geometry
  did its job feeding the union mask. A thin audit trail (which mask_ids
  fed which pass transition) is worth keeping only for the "Last scrub:
  Pass N → Pass N+1" status line already in `LBSCard`, not for anything
  functionally downstream.

## 5. Persistence: session = one image, corpus = the union of saved sessions

- **No global word-balloon (or any discard) registry.** A `discard` record
  belongs to exactly one `session_id`, which is exactly one image's whole
  processing history. Reprocessing the same source image from scratch means
  a new `session_id`, which correctly starts with no memory of the old
  session's discards — this was confirmed explicitly, not assumed.
- **No new cross-image store needs building.** `aa_persistence.py`'s
  existing `storage/sf/sessions/<session_id>/` directories, one per image,
  already are the corpus. `list_registries()` already walks all of them.
- **"Compile a training set" is a read-time operation, not a write-time
  one.** A compile step walks every saved session, reads `segment.parquet`,
  filters to `dataset_status == "keep"` rows that have a caption, and
  materializes a `dataset_dir`/`metadata.jsonl` snapshot matching what
  `lora_trainer.py` already expects. Idempotent, re-runnable, no session
  needs to reach a special "finished" state first. Compiling from one
  session vs. many is the same operation at different N — not two code
  paths.
- **In-memory session state is AA-shaped and live, not a projection built
  at save time.** Every mutation (a selection, a caption edit, a hold/unhold,
  a scrub transition) updates the in-memory AA (rows/cols/vals) directly,
  replacing today's two-shape arrangement (SAM3-processor-shaped `state`
  dict during the session, separately transformed into AA form only inside
  `save_session`). This removes a whole class of "session state and its
  saved representation silently drift apart" risk, independent of anything
  about save timing.
- **Persistence to disk is explicit-Save only, not autosaved.** The live
  in-memory AA is what the existing `/saveSession` endpoint writes via
  `aa_persistence.py`, on the same trigger as today (user-initiated Save) —
  no debounce, no periodic flush. This is a deliberate trade: work done
  since the last Save (new selections, captions, holds, scrub batches) is
  lost on a crash or force-quit before the user saves. That trade was made
  explicitly in favor of simplicity over the earlier "autosave for safety"
  instinct — worth remembering if data loss on crash comes up as a
  complaint later, since it's a known, chosen tradeoff, not an oversight.

## 6. Schema consequence — now load-bearing, not just for resume

Because compile reads directly from saved sessions, `aa_persistence.py`'s
on-disk schema is the literal source of truth for training data, not merely
a convenience for resuming a session. `segment.parquet` needs, per mask row
(`{session_id}:{pass}:{mask_id}`):

- `pass` — string/int, unbounded range (not the old two-value scheme)
- `dataset_status` — `"keep"` | `"discard"` | `"unassigned"`
- `caption` — text, present only when `dataset_status == "keep"`
- `held` — bool; present/true only for records still pending a scrub batch,
  absent or false once that batch has run

If any of these fail to round-trip through save/reload correctly, the
failure mode isn't "a resumed session looks wrong" — it's "captioned work
silently never reaches the training set." Test the round-trip accordingly.

## 7. What survives unchanged from the earlier work

- The IoU-based mask-identity reconciliation fix in `_select` — unaffected
  by any of the above, still correct, still needed for both axes' records.
- `LBSCard`'s UI shape (title, pending-count status line, last-scrub status
  line, embedded scrub button) — matches the held-batch model in §4 almost
  exactly as already built.
- `LamaInpainter`/`InpaintingEngine` Protocol — the actual scrub mechanics
  don't change, only when/how often they're invoked and what feeds the
  union mask.
- `d4m_juliacall_bridge.build_triples`-based serialization convention —
  still the right approach, just needs the schema in §6 layered onto it
  rather than the old `MaskType.IN`-only filter.

## 8. Open items not yet decided

- The distinction between `unassigned` and `discard` at the UI level: does
  the user have to make an explicit "discard" choice per object (e.g. a
  button), or is `discard` just "held and scrubbed without ever having been
  captioned" — i.e., does `unassigned` even need to be a persisted state, or
  only a transient one before the user acts?
- Whether `LBSCard`'s existing UI needs any visible change to expose
  `dataset_status` as a per-object choice, given the earlier finding that no
  frontend control for this exists at all yet (confirmed during the Bug
  Group A investigation).
