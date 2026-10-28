"""Fine-tune and run a vision-language model (Qwen-VL) through mlx-vlm.

Training is `python -m mlx_vlm.train --data <folder>` on a folder the Collect
Antelora node wrote (it reads `<folder>/train.jsonl`, images relative to the
folder). Captioning is `python -m mlx_vlm generate --adapter-path <adapter>`.
Both run as subprocesses of the interpreter this backend runs in, so mlx-vlm
must be installed there: `pip install "mlx-vlm[train]"`.

Training is a job: [start_train] returns at once, the caller polls [train_status]
(progress is read from the trainer's tqdm bar) and may [cancel_train].
Captioning is one blocking call per image.
"""

from __future__ import annotations

import importlib.util
import re
import subprocess
import sys
import threading
import uuid
from collections import deque
from pathlib import Path
from typing import Any, Optional

from .antelora import antelora_root, safe_name

DEFAULT_MODEL = "mlx-community/Qwen2-VL-2B-Instruct-bf16"
INSTALL_HINT = 'mlx-vlm is not installed in the backend environment: pip install "mlx-vlm[train]"'

# Seam for tests: replaced by a fake that spawns a harmless process.
_popen = subprocess.Popen
_run = subprocess.run


class VlmError(Exception):
    """A request that cannot run; the message is meant for the user."""


def lora_root() -> Path:
    """`storage/postlora/` next to `storage/antelora/`."""
    return antelora_root().parent / "postlora"


def mlx_vlm_installed() -> bool:
    return importlib.util.find_spec("mlx_vlm") is not None


class _Job:
    def __init__(self, adapter: Path, epochs: int) -> None:
        self.id = uuid.uuid4().hex
        self.adapter = adapter
        self.epochs = epochs
        self.status = "running"  # running | done | failed | cancelled
        self.step = 0
        self.total = 0
        self.error: Optional[str] = None
        self.lines: deque[str] = deque(maxlen=60)
        self.proc: Any = None
        self.cancelled = False


_jobs: dict[str, _Job] = {}
_BAR = re.compile(r"(\d+)\s*/\s*(\d+)")


def _pump(job: _Job) -> None:
    """Read the trainer's output (tqdm redraws with \\r) until it exits."""
    buf = ""
    stream = job.proc.stdout
    while True:
        chunk = stream.read1(4096) if hasattr(stream, "read1") else stream.read(1)
        if not chunk:
            break
        buf += chunk.decode("utf-8", "replace")
        parts = re.split(r"[\r\n]", buf)
        buf = parts.pop()
        for line in parts:
            line = line.strip()
            if not line:
                continue
            job.lines.append(line)
            if "%|" in line or line.startswith("Training"):
                m = _BAR.search(line.split("|")[-1] if "|" in line else line)
                if m:
                    job.step, job.total = int(m.group(1)), int(m.group(2))
    code = job.proc.wait()
    if job.cancelled:
        job.status = "cancelled"
    elif code == 0 and job.adapter.is_file():
        job.status = "done"
        job.step = job.total or job.step
    else:
        job.status = "failed"
        tail = " | ".join(list(job.lines)[-3:])
        job.error = (
            f"trainer exited with code {code}" + (f": {tail}" if tail else "")
            if code != 0
            else f"trainer finished but wrote no adapter at {job.adapter}"
        )


def start_train(
    dataset: str,
    model: str = DEFAULT_MODEL,
    name: str = "",
    epochs: int = 3,
    rank: int = 8,
    batch_size: int = 1,
    learning_rate: float = 1e-5,
    require_installed: bool = True,
) -> dict[str, Any]:
    folder = Path(dataset)
    if not (folder / "train.jsonl").is_file():
        raise VlmError(
            f"{dataset!r} has no train.jsonl — run Collect Antelora first and pass its output folder"
        )
    if not model.strip():
        raise VlmError("enter a base model, e.g. " + DEFAULT_MODEL)
    if epochs < 1 or rank < 1 or batch_size < 1 or learning_rate <= 0:
        raise VlmError("epochs, rank and batch size must be at least 1, learning rate above 0")
    if require_installed and not mlx_vlm_installed():
        raise VlmError(INSTALL_HINT)

    antelora = folder.parent.parent.name  # …/antelora/<set>/_collected/<output>
    run_name = safe_name(name, "") or safe_name(f"{folder.name}-r{rank}-e{epochs}", "run")
    adapter = lora_root() / safe_name(antelora, "antelora") / run_name / "adapters.safetensors"
    adapter.parent.mkdir(parents=True, exist_ok=True)
    if adapter.exists():
        adapter.unlink()  # a stale adapter must not read as this run's result

    cmd = [
        sys.executable, "-m", "mlx_vlm.train",
        "--model", model, "--data", str(folder), "--output-path", str(adapter),
        "--epochs", str(epochs), "--lora-rank", str(rank),
        "--batch-size", str(batch_size), "--learning-rate", str(learning_rate),
    ]
    job = _Job(adapter, epochs)
    job.proc = _popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    _jobs[job.id] = job
    threading.Thread(target=_pump, args=(job,), daemon=True).start()
    return {"run_id": job.id, "adapter": str(adapter)}


def train_status(run_id: str) -> dict[str, Any]:
    job = _jobs.get(run_id)
    if job is None:
        raise VlmError(f"no such training run: {run_id}")
    return {
        "status": job.status,
        "step": job.step,
        "total": job.total,
        "adapter": str(job.adapter),
        "error": job.error,
        "lines": list(job.lines)[-8:],
    }


def cancel_train(run_id: str) -> dict[str, Any]:
    job = _jobs.get(run_id)
    if job is None:
        raise VlmError(f"no such training run: {run_id}")
    if job.status == "running":
        job.cancelled = True
        job.proc.terminate()
    return train_status(run_id)


def caption_image(
    image: str,
    model: str = DEFAULT_MODEL,
    adapter: str = "",
    prompt: str = "Describe this image.",
    max_tokens: int = 200,
    timeout: float = 600,
    require_installed: bool = True,
) -> str:
    """Caption one image file. [adapter] may be empty for the plain base model."""
    if not Path(image).is_file():
        raise VlmError(f"image not found: {image}")
    if adapter and not Path(adapter).is_file():
        raise VlmError(f"adapter not found: {adapter}")
    if require_installed and not mlx_vlm_installed():
        raise VlmError(INSTALL_HINT)
    cmd = [
        sys.executable, "-m", "mlx_vlm", "generate",
        "--model", model, "--image", image, "--prompt", prompt,
        "--max-tokens", str(max_tokens), "--temperature", "0",
    ]
    if adapter:
        cmd += ["--adapter-path", adapter]
    try:
        done = _run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise VlmError(f"captioning timed out after {int(timeout)}s")
    if done.returncode != 0:
        tail = (done.stderr or "").strip().splitlines()[-1:] or ["no error output"]
        raise VlmError(f"caption failed: {tail[0]}")
    text = done.stdout.strip()
    if not text:
        raise VlmError("the model returned no text")
    return text
