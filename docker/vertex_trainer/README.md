# Image LoRA Cloud Trainer container

The container Vertex AI runs for cloud-backed Z-Image-Turbo LoRA training
(`node Image LoRA Cloud Trainer` -> `backend/src/double_touch/cloud_train.py`).

Bakes in [ostris/ai-toolkit](https://github.com/ostris/ai-toolkit) (the same
Ostris LoRA-adapter convention `mflux-train` already borrows for the local
trainer, so adapters trained here should be drop-in compatible with Generate
and Load File — no changes needed there).

## One-time setup

1. `./build_and_push.sh YOUR_PROJECT_ID YOUR_REGION` — builds the image and
   pushes it to a new Artifact Registry repo (`dn-vertex-trainer`) in your
   project. Needs Docker and `gcloud` installed and authenticated.
2. Create a GCS bucket for run data/outputs if you don't already have one to
   reuse, e.g.:
   ```
   gcloud storage buckets create gs://YOUR_PROJECT_ID-dn-training --location=YOUR_REGION
   ```
3. Add to `backend/.env`:
   ```
   GCP_GCS_BUCKET=YOUR_PROJECT_ID-dn-training
   GCP_VERTEX_TRAIN_IMAGE=YOUR_REGION-docker.pkg.dev/YOUR_PROJECT_ID/dn-vertex-trainer/z-image-trainer:latest
   ```
4. Make sure the service account in `GOOGLE_APPLICATION_CREDENTIALS` has
   `roles/aiplatform.user` and `roles/storage.objectAdmin` (set up when the
   service account was created).

## Rebuilding

The Dockerfile clones ai-toolkit's `main` branch at build time, so there's no
version to bump — just re-run `build_and_push.sh` (optionally
`docker build --no-cache` first) to pick up upstream changes.

## Not yet done here

- No live smoke test yet — written against the documented
  `google-cloud-aiplatform` API but not yet run against a real project.
- No mid-run checkpoint export (the local trainer's "Use latest checkpoint"
  button) — the container only uploads the adapter when the job finishes.
  Would need the container to periodically upload intermediate checkpoints
  for that to work here too.
- No per-step progress — Vertex AI's job state is coarse
  (queued/running/succeeded/failed/cancelled); step-level progress would need
  the container to write progress to GCS and the backend to poll that too.
