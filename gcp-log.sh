#!/usr/bin/env bash
# Print the most recent cloud-train job's IDs, latest known state, and a
# ready-to-paste Cloud Logging Explorer query -- everything needed to go
# look up what a training job on Vertex AI is doing right now.
#
# Usage: ./gcp-log.sh

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$ROOT/logs/dn-backend.log"

if [[ ! -f "$LOG" ]]; then
  echo "gcp-log.sh: no log file at $LOG -- is the backend running? (./run.sh status)" >&2
  exit 1
fi

SUBMIT_LINE="$(grep 'cloud_train\].*submitted:' "$LOG" | tail -1 || true)"
if [[ -z "$SUBMIT_LINE" ]]; then
  echo "gcp-log.sh: no cloud-train job has been submitted yet in $LOG" >&2
  exit 1
fi

# "[cloud_train] job <dn-id> submitted: projects/<n>/locations/<region>/customJobs/<vertex-id>"
DN_JOB="$(echo "$SUBMIT_LINE" | sed -E 's/.*job ([a-f0-9]+) submitted:.*/\1/')"
RESOURCE_PATH="$(echo "$SUBMIT_LINE" | sed -E 's/.*submitted: //')"
VERTEX_JOB="${RESOURCE_PATH##*/}"
REGION="$(echo "$RESOURCE_PATH" | sed -E 's#projects/[^/]+/locations/([^/]+)/.*#\1#')"
PROJECT="$(echo "$RESOURCE_PATH" | sed -E 's#projects/([0-9]+)/.*#\1#')"

LATEST_STATE_LINE="$(grep "cloud_train\] job $DN_JOB " "$LOG" | tail -1 || true)"

echo "DN job id:      $DN_JOB"
echo "Vertex job id:  $VERTEX_JOB"
echo "Latest status:  ${LATEST_STATE_LINE#*"cloud_train] job $DN_JOB "}"
echo ""
echo "Console:"
echo "  https://console.cloud.google.com/agent-platform/locations/$REGION/training/$VERTEX_JOB?project=$PROJECT"
echo ""
echo "Logs Explorer query:"
echo "  resource.type=\"ml_job\""
echo "  resource.labels.job_id=\"$VERTEX_JOB\""
