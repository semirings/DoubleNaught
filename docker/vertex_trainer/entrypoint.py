"""Vertex AI Custom Job entrypoint: download the run's data+config from GCS,
run ai-toolkit (`python run.py config.yaml`), upload the resulting adapter.

cloud_train.py (DN/BE) sets three env vars on the container:
    GCS_INPUT_URI   gs://.../input/   (holds data/ and config.yaml)
    GCS_OUTPUT_URI  gs://.../output/  (where the adapter gets uploaded to)
    CONFIG_FILE     config.yaml       (filename under GCS_INPUT_URI)

ai-toolkit's own `training_folder` (baked into the config DN/BE generates)
is a local container path, /workspace/output - this script uploads whatever
`.safetensors` lands there to GCS_OUTPUT_URI when the training process exits
successfully. DN/BE polls Vertex AI's job state directly (no Pub/Sub - DN/BE
has no public endpoint to push to) and downloads from GCS_OUTPUT_URI once the
job reports success.
"""

import os
import subprocess
import sys
from pathlib import Path

from google.cloud import storage

WORKDIR = Path("/workspace")
AI_TOOLKIT = Path("/opt/ai-toolkit")


def _split_gcs_uri(uri: str) -> tuple[str, str]:
    bucket, _, prefix = uri.removeprefix("gs://").partition("/")
    return bucket, prefix


def _download_prefix(uri: str, dest: Path) -> None:
    bucket_name, prefix = _split_gcs_uri(uri)
    client = storage.Client()
    bucket = client.bucket(bucket_name)
    found = False
    for blob in client.list_blobs(bucket, prefix=prefix):
        if blob.name.endswith("/"):
            continue
        rel = blob.name[len(prefix):].lstrip("/")
        if not rel:
            continue
        target = dest / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        blob.download_to_filename(str(target))
        found = True
    if not found:
        raise RuntimeError(f"nothing found under {uri}")


def _upload_dir(local_dir: Path, uri: str) -> int:
    bucket_name, prefix = _split_gcs_uri(uri)
    client = storage.Client()
    bucket = client.bucket(bucket_name)
    n = 0
    for path in local_dir.rglob("*.safetensors"):
        rel = path.relative_to(local_dir).as_posix()
        bucket.blob(f"{prefix.rstrip('/')}/{rel}").upload_from_filename(str(path))
        n += 1
    return n


def main() -> int:
    input_uri = os.environ["GCS_INPUT_URI"]
    output_uri = os.environ["GCS_OUTPUT_URI"]
    config_name = os.environ.get("CONFIG_FILE", "config.yaml")

    print(f"downloading {input_uri} -> {WORKDIR}", flush=True)
    _download_prefix(input_uri, WORKDIR)

    config_path = WORKDIR / config_name
    if not config_path.is_file():
        print(f"error: {config_path} not found after download", flush=True)
        return 2

    print(f"running ai-toolkit on {config_path}", flush=True)
    code = subprocess.call(
        ["python3.11", "run.py", str(config_path)], cwd=str(AI_TOOLKIT)
    )
    if code != 0:
        print(f"ai-toolkit exited with code {code}", flush=True)
        return code

    output_dir = WORKDIR / "output"
    uploaded = _upload_dir(output_dir, output_uri)
    print(f"uploaded {uploaded} adapter file(s) to {output_uri}", flush=True)
    return 0 if uploaded else 3


if __name__ == "__main__":
    sys.exit(main())
