"""Train an image LoRA on Vertex AI (ai-toolkit, CUDA) from a collected loraset.

This is the cloud-backed sibling of `image_train.py`. Where that module shells
out to `mflux-train` on Apple Silicon, this one:

  1. Builds the same `data/` folder of (image, caption) pairs `image_train.py`
     builds (reused from there directly — same captions, same trigger-word
     prefix, same file layout).
  2. Writes an ai-toolkit YAML config instead of mflux's `train.json` — same
     idea (model, rank, resolution, steps, learning rate) but ai-toolkit's
     own shape. Model arch is `zimage` (ai-toolkit's name for
     Tongyi-MAI/Z-Image-Turbo) — the same Ostris LoRA-adapter convention
     mflux already borrows, so the resulting `.safetensors` should be the
     same shape Generate and Load File already load for Z-Image.
  3. Uploads `data/` + the config to GCS, submits a Vertex AI CustomJob
     running a container with ai-toolkit baked in (see
     `docker/vertex_trainer/`), and polls its state.
  4. On success, downloads the resulting adapter back into
     `storage/lora/<set>/<name>/<name>.safetensors` — the same run-directory
     shape `image_train.py`'s `export()` produces, so nothing downstream
     (Generate, Load File) needs to know whether a LoRA was trained locally
     or in the cloud.

No Pub/Sub: DN/BE has no public endpoint for GCP to push to, so this polls
the job's state directly on a timer, same as the FE already polls
`/image-train/{id}`.

Required env (see `backend/.env`):
    GCP_PROJECT_ID, GCP_REGION, GOOGLE_APPLICATION_CREDENTIALS
    GCP_GCS_BUCKET            - bucket for run data, configs and outputs
    GCP_VERTEX_TRAIN_IMAGE    - Artifact Registry URI of the ai-toolkit
                                training container (see docker/vertex_trainer/)
Optional:
    GCP_VERTEX_MACHINE_TYPE      (default g2-standard-24)
    GCP_VERTEX_ACCELERATOR_TYPE  (default NVIDIA_L4)
    GCP_VERTEX_ACCELERATOR_COUNT (default 1)

NOTE: the Vertex AI SDK calls below (`CustomJob(...).submit()`, and the
JobServiceClient `get_custom_job`/`cancel_custom_job` calls used for polling)
are written against the documented google-cloud-aiplatform API, but this
module has not yet been exercised against a real project — there was no
live GCP credential available while writing it. Smoke-test `start_cloud_train`
end to end the first time real credentials are in place before trusting it
unattended.
"""

from __future__ import annotations

import json
import os
import threading
import time
import uuid
from pathlib import Path
from typing import Any, Optional

import yaml

from .image_train import TrainError, collected_dir, lora_root, read_captions
from .loraset import safe_name

MODEL_ARCH = "zimage"
MODEL_NAME_OR_PATH = "Tongyi-MAI/Z-Image-Turbo"

_DONE_STATES = {"JOB_STATE_SUCCEEDED", "JOB_STATE_FAILED", "JOB_STATE_CANCELLED"}
_RUNNING_STATES = {"JOB_STATE_RUNNING", "JOB_STATE_CANCELLING", "JOB_STATE_UPDATING"}
_QUEUED_STATES = {"JOB_STATE_QUEUED", "JOB_STATE_PENDING", "JOB_STATE_PAUSED"}


def _env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def _require_config() -> dict[str, str]:
    """GCP settings from backend/.env; raises TrainError naming what's missing."""
    project = _env("GCP_PROJECT_ID")
    region = _env("GCP_REGION", "us-central1")
    bucket = _env("GCP_GCS_BUCKET")
    image = _env("GCP_VERTEX_TRAIN_IMAGE")
    missing = [
        name
        for name, val in (
            ("GCP_PROJECT_ID", project),
            ("GCP_GCS_BUCKET", bucket),
            ("GCP_VERTEX_TRAIN_IMAGE", image),
        )
        if not val
    ]
    if missing:
        raise TrainError(
            "backend/.env is missing " + ", ".join(missing) + " - see docker/vertex_trainer/README"
        )
    return {
        "project": project,
        "region": region,
        "bucket": bucket,
        "image": image,
        # g2-standard-24 needs 2x L4 GPUs (Vertex rejects accelerator_count=1
        # with it); g2-standard-16 is the smallest G2 shape that pairs with a
        # single L4, which is the GPU class everything here (quantize default
        # off, etc.) was designed around.
        "machine_type": _env("GCP_VERTEX_MACHINE_TYPE", "g2-standard-16"),
        "accelerator_type": _env("GCP_VERTEX_ACCELERATOR_TYPE", "NVIDIA_L4"),
        "accelerator_count": _env("GCP_VERTEX_ACCELERATOR_COUNT", "1"),
    }


def default_name(epochs: int, rank: int) -> str:
    return f"z-image-cloud-r{rank}-e{epochs}"


def build_config(
    *,
    run_name: str,
    data_dir_in_container: str,
    output_dir_in_container: str,
    epochs: int,
    rank: int,
    learning_rate: float,
    resolution: int,
    num_images: int,
    trigger: str = "",
    quantize: bool = False,
) -> dict[str, Any]:
    """The ai-toolkit YAML config for one run. Mirrors `image_train.prepare()`'s
    train.json: same knobs (rank, resolution, epochs->steps, learning rate),
    ai-toolkit's own field names (see config/examples/*.yaml in ai-toolkit)."""
    steps = max(1, epochs * max(1, num_images))
    save_every = max(1, steps // 4)  # about four checkpoints, same spirit as mflux side
    return {
        "job": "extension",
        "config": {
            "name": run_name,
            "process": [
                {
                    "type": "sd_trainer",
                    "training_folder": output_dir_in_container,
                    "device": "cuda:0",
                    **({"trigger_word": trigger} if trigger else {}),
                    "network": {"type": "lora", "linear": rank, "linear_alpha": rank},
                    "save": {
                        "dtype": "float16",
                        "save_every": save_every,
                        "max_step_saves_to_keep": 4,
                    },
                    "datasets": [
                        {
                            "folder_path": data_dir_in_container,
                            "caption_ext": "txt",
                            "cache_latents_to_disk": True,
                            "resolution": [resolution],
                        }
                    ],
                    "train": {
                        "batch_size": 1,
                        "steps": steps,
                        "gradient_accumulation": 1,
                        "train_unet": True,
                        "gradient_checkpointing": True,
                        "noise_scheduler": "flowmatch",
                        "optimizer": "adamw8bit",
                        "lr": learning_rate,
                        "dtype": "bf16",
                        "disable_sampling": True,  # no inference samples needed for an unattended run
                    },
                    "model": {
                        "name_or_path": MODEL_NAME_OR_PATH,
                        "arch": MODEL_ARCH,
                        # ai-toolkit's own `zimage` registry entry carries no
                        # default here - Z-Image-Turbo fits a 24GB L4 without
                        # it. Quantizing trades training quality for VRAM
                        # headroom, so it's opt-in, not assumed.
                        **({"quantize": True, "low_vram": True} if quantize else {}),
                    },
                }
            ],
        },
        "meta": {"name": "[name]", "version": "1.0"},
    }


class _CloudJob:
    def __init__(self, run_dir: Path, name: str, gcs_prefix: str) -> None:
        self.id = uuid.uuid4().hex
        self.run_dir, self.name = run_dir, name
        self.gcs_prefix = gcs_prefix  # gs://bucket/dn-vertex-trainer/<name>-<id>/
        self.resource_name: Optional[str] = None  # set once Vertex assigns it
        self.status = "queued"  # queued | running | done | failed | cancelled
        self.error: Optional[str] = None
        self.adapter = ""
        self.started = time.time()
        self.cancelled = False


_jobs: dict[str, _CloudJob] = {}


# ---- GCS / Vertex seams (mockable in tests; see test_cloud_train.py) ------

def _upload_dir(local_dir: Path, gcs_prefix: str) -> None:
    from google.cloud import storage

    bucket_name, _, blob_prefix = gcs_prefix.removeprefix("gs://").partition("/")
    client = storage.Client()
    bucket = client.bucket(bucket_name)
    for path in local_dir.rglob("*"):
        if path.is_file():
            rel = path.relative_to(local_dir).as_posix()
            bucket.blob(f"{blob_prefix.rstrip('/')}/{rel}").upload_from_filename(str(path))


def _download_adapter(gcs_prefix: str, dest: Path) -> bool:
    """Find the newest `*.safetensors` under the run's GCS output and download
    it to [dest]. Returns False if none is there yet."""
    from google.cloud import storage

    bucket_name, _, blob_prefix = gcs_prefix.removeprefix("gs://").partition("/")
    client = storage.Client()
    bucket = client.bucket(bucket_name)
    blobs = sorted(
        (b for b in client.list_blobs(bucket, prefix=blob_prefix) if b.name.endswith(".safetensors")),
        key=lambda b: b.updated,
    )
    if not blobs:
        return False
    dest.parent.mkdir(parents=True, exist_ok=True)
    blobs[-1].download_to_filename(str(dest))
    return True


def _submit_job(cfg: dict[str, str], job: _CloudJob) -> str:
    """Submit the Vertex AI CustomJob; returns its resource_name."""
    from google.cloud import aiplatform

    aiplatform.init(project=cfg["project"], location=cfg["region"])
    worker_pool_specs = [
        {
            "machine_spec": {
                "machine_type": cfg["machine_type"],
                "accelerator_type": cfg["accelerator_type"],
                "accelerator_count": int(cfg["accelerator_count"]),
            },
            "replica_count": 1,
            "container_spec": {
                "image_uri": cfg["image"],
                "env": [
                    {"name": "GCS_INPUT_URI", "value": f"{job.gcs_prefix}input/"},
                    {"name": "GCS_OUTPUT_URI", "value": f"{job.gcs_prefix}output/"},
                    {"name": "CONFIG_FILE", "value": "config.yaml"},
                ],
            },
        }
    ]
    vertex_job = aiplatform.CustomJob(
        display_name=f"dn-{job.name}",
        worker_pool_specs=worker_pool_specs,
        staging_bucket=f"gs://{cfg['bucket']}",
    )
    vertex_job.submit()
    return vertex_job.resource_name


def _poll_state(cfg: dict[str, str], resource_name: str) -> tuple[str, Optional[str]]:
    """(raw JobState name, error message or None) for an already-submitted job."""
    from google.cloud import aiplatform

    client_options = {"api_endpoint": f"{cfg['region']}-aiplatform.googleapis.com"}
    client = aiplatform.gapic.JobServiceClient(client_options=client_options)
    response = client.get_custom_job(name=resource_name)
    state_name = response.state.name  # e.g. "JOB_STATE_RUNNING"
    error = response.error.message if response.error and response.error.message else None
    return state_name, error


def _cancel_job(cfg: dict[str, str], resource_name: str) -> None:
    from google.cloud import aiplatform

    client_options = {"api_endpoint": f"{cfg['region']}-aiplatform.googleapis.com"}
    client = aiplatform.gapic.JobServiceClient(client_options=client_options)
    client.cancel_custom_job(name=resource_name)


# ---- public API, mirrors image_train.py's start_train/train_status/cancel --

def start_cloud_train(
    loraset: str = "mccay",
    output: str = "train",
    name: str = "",
    epochs: int = 20,
    rank: int = 16,
    learning_rate: float = 1e-4,
    resolution: int = 768,
    trigger: str = "",
    quantize: bool = False,
    dataset: str = "",
    root: Optional[Path] = None,
) -> dict[str, Any]:
    if epochs < 1:
        raise TrainError("epochs must be at least 1")
    if not 1 <= rank <= 128:
        raise TrainError("rank must be between 1 and 128")
    if not 0 < learning_rate <= 1e-2:
        raise TrainError("learning rate must be above 0 and at most 0.01")
    if resolution < 256 or resolution > 1536 or resolution % 16:
        raise TrainError("resolution must be a multiple of 16 from 256 to 1536")
    if any(j.status in ("queued", "running") for j in _jobs.values()):
        raise TrainError("a cloud LoRA run is already in progress - wait for it or cancel it")
    cfg = _require_config()

    if dataset.strip():
        folder = Path(dataset.strip()).expanduser()
        set_name = folder.parent.parent.name if folder.parent.name == "_collected" else folder.name
    else:
        folder, set_name = collected_dir(loraset, output, root), loraset
    pairs = read_captions(folder)

    name = safe_name(name, default_name(epochs, rank))
    run_dir = (root.parent / "lora" if root else lora_root()) / safe_name(set_name, "mccay") / name
    if run_dir.exists():
        stamp = time.strftime("%Y%m%d_%H%M%S")
        name = f"{name}_{stamp}"
        run_dir = run_dir.with_name(name)
    data_dir = run_dir / "data"
    data_dir.mkdir(parents=True)
    used: set[str] = set()
    prefix = f"{trigger}, " if trigger else ""
    for image, text in pairs:
        stem = safe_name(image.stem, "img")
        n, unique = 2, stem
        while unique in used:
            unique, n = f"{stem}_{n}", n + 1
        used.add(unique)
        (data_dir / f"{unique}{image.suffix.lower()}").write_bytes(image.read_bytes())
        (data_dir / f"{unique}.txt").write_text(prefix + text, encoding="utf-8")

    config = build_config(
        run_name=name,
        data_dir_in_container="/workspace/data",
        output_dir_in_container="/workspace/output",
        epochs=epochs,
        rank=rank,
        learning_rate=learning_rate,
        resolution=resolution,
        num_images=len(pairs),
        trigger=safe_name(trigger, "") if trigger else "",
        quantize=quantize,
    )
    (run_dir / "config.yaml").write_text(yaml.safe_dump(config, sort_keys=False), encoding="utf-8")

    job = _CloudJob(run_dir, name, gcs_prefix=f"gs://{cfg['bucket']}/dn-vertex-trainer/{name}-{uuid.uuid4().hex[:8]}/")
    _jobs[job.id] = job

    def _run() -> None:
        try:
            _upload_dir(data_dir, f"{job.gcs_prefix}input/data")
            _upload_dir_single(run_dir / "config.yaml", f"{job.gcs_prefix}input/config.yaml")
            job.resource_name = _submit_job(cfg, job)
            job.status = "running"
            print(f"[cloud_train] job {job.id} submitted: {job.resource_name}")
        except Exception as exc:  # noqa: BLE001 - surfaced to the UI as job.error
            import traceback
            traceback.print_exc()
            job.status, job.error = "failed", str(exc)
            print(f"[cloud_train] job {job.id} submission failed: {exc!r}")

    threading.Thread(target=_run, daemon=True).start()
    return {
        "run_id": job.id,
        "adapter": str(run_dir / f"{name}.safetensors"),
        "images": len(pairs),
        "run_dir": str(run_dir),
    }


def _upload_dir_single(local_file: Path, gcs_uri: str) -> None:
    from google.cloud import storage

    bucket_name, _, blob_name = gcs_uri.removeprefix("gs://").partition("/")
    storage.Client().bucket(bucket_name).blob(blob_name).upload_from_filename(str(local_file))


def _job(run_id: str) -> _CloudJob:
    job = _jobs.get(run_id)
    if job is None:
        raise TrainError(f"no such cloud training run: {run_id}")
    return job


def cloud_train_status(run_id: str) -> dict[str, Any]:
    job = _job(run_id)
    if job.status in ("running",) and job.resource_name:
        cfg = _require_config()
        try:
            state_name, error = _poll_state(cfg, job.resource_name)
        except Exception as exc:  # noqa: BLE001
            import traceback
            traceback.print_exc()
            print(f"[cloud_train] job {job.id} poll failed: {exc!r}")
            return {
                "status": job.status, "adapter": job.adapter, "error": f"polling failed: {exc}",
                "elapsed": int(time.time() - job.started),
            }
        print(f"[cloud_train] job {job.id} state={state_name} error={error!r}")
        if state_name in _DONE_STATES:
            if job.cancelled or state_name == "JOB_STATE_CANCELLED":
                job.status = "cancelled"
            elif state_name == "JOB_STATE_SUCCEEDED":
                dest = job.run_dir / f"{job.name}.safetensors"
                if _download_adapter(f"{job.gcs_prefix}output/", dest):
                    job.adapter, job.status = str(dest), "done"
                else:
                    job.status, job.error = "failed", "job succeeded but no adapter was found in its output"
            else:
                job.status, job.error = "failed", error or f"training job ended in state {state_name}"
    return {
        "status": job.status,
        "adapter": job.adapter or str(job.run_dir / f"{job.name}.safetensors"),
        "error": job.error,
        "elapsed": int(time.time() - job.started),
    }


def cancel_cloud_train(run_id: str) -> dict[str, Any]:
    job = _job(run_id)
    if job.status in ("queued", "running") and job.resource_name:
        job.cancelled = True
        cfg = _require_config()
        _cancel_job(cfg, job.resource_name)
    elif job.status in ("queued", "running"):
        job.cancelled = True  # not yet submitted; the background thread's next check stops it
        job.status = "cancelled"
    return cloud_train_status(run_id)
