#!/bin/sh
# Build the Image LoRA Cloud Trainer container and push it to Artifact Registry.
#
# One-time setup, run from this directory (docker/vertex_trainer/) on a
# machine with Docker and gcloud installed and authenticated:
#
#   ./build_and_push.sh YOUR_PROJECT_ID us-central1
#
# The resulting image URI goes into backend/.env as GCP_VERTEX_TRAIN_IMAGE.
# Rebuild and re-run this script whenever ai-toolkit itself needs updating
# (the Dockerfile clones its `main` branch at build time, so re-running with
# --no-cache picks up upstream changes).

set -eu

PROJECT_ID="${1:?usage: build_and_push.sh PROJECT_ID REGION}"
REGION="${2:?usage: build_and_push.sh PROJECT_ID REGION}"
REPO="dn-vertex-trainer"
IMAGE="$REGION-docker.pkg.dev/$PROJECT_ID/$REPO/z-image-trainer:latest"

gcloud artifacts repositories describe "$REPO" \
  --project="$PROJECT_ID" --location="$REGION" >/dev/null 2>&1 || \
gcloud artifacts repositories create "$REPO" \
  --project="$PROJECT_ID" --location="$REGION" --repository-format=docker \
  --description="DoubleNaught cloud LoRA trainer images"

gcloud auth configure-docker "$REGION-docker.pkg.dev" --quiet

# --platform linux/amd64: every GCP machine type (including the g2-standard-*
# shapes this trains on) is x86_64. Without this, Docker Desktop on Apple
# Silicon builds an arm64 image by default, which fails on Vertex with
# "exec /usr/bin/python3.11: exec format error" - the container can't even
# start (confirmed live: job 6324317292997902336, 2026-10-24).
docker build --platform linux/amd64 -t "$IMAGE" .
docker push "$IMAGE"

echo
echo "Pushed: $IMAGE"
echo "Set in backend/.env:  GCP_VERTEX_TRAIN_IMAGE=$IMAGE"
