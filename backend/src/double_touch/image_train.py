"""Train an image LoRA with mflux (`mflux-train`) from a collected antelora.

The Collect Antelora node leaves `storage/antelora/<set>/_collected/<output>/` with
`metadata.jsonl` (``file_name`` relative to that folder, ``text`` the caption) and
the images. `mflux-train` wants a flat folder of images each with a same-named
``.txt`` caption, plus a JSON config. [prepare] builds that folder and the config
inside the run folder `storage/postlora/<set>/<name>/`; [start_train] then runs
`mflux-train --config` as a subprocess (mflux lives in its own environment, like
for generation; set $DOUBLE_TOUCH_MFLUX_TRAIN if it is not on PATH).

Model: Z-Image-Turbo. mflux applies Ostris' training adapter for it by itself.
The LoRA targets are the ones mflux ships in its own example config.

Training saves checkpoints as zips under `<run>/train/checkpoints/`. [export]
pulls the newest adapter out as `<run>/<name>.safetensors`, which Generate loads
(with the Z-Image family selected). It is done automatically when training
finishes and may be called while it runs to try an intermediate checkpoint.

Command line (no server needed):  python -m double_touch.image_train mccay
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import threading
import time
import uuid
import zipfile
from collections import deque
from pathlib import Path
from typing import Any, Optional

from .antelora import antelora_root, safe_name

COMMAND = "mflux-train"
MODEL = "z-image-turbo"
INSTALL_HINT = (
    f"{COMMAND} was not found. Install mflux 0.22+ in its own environment "
    "(pip install -U mflux) and put it on PATH, or set DOUBLE_TOUCH_MFLUX_TRAIN "
    "to the command's full path."
)

# Z-Image-Turbo's transformer: 30 blocks. Copied from mflux's _example/train.json.
_BLOCKS = {"start": 0, "end": 30}
_BLOCK_MODULES = (
    "layers.{block}.attention.to_q",
    "layers.{block}.attention.to_k",
    "layers.{block}.attention.to_v",
    "layers.{block}.attention.to_out.0",
    "layers.{block}.feed_forward.w1",
    "layers.{block}.feed_forward.w2",
    "layers.{block}.feed_forward.w3",
)
_WHOLE_MODULES = ("cap_embedder.1", "all_final_layer.2-1.linear")

_popen = subprocess.Popen  # seam for tests


class TrainError(Exception):
    """A request that cannot run; the message is meant for the user."""


def lora_root() -> Path:
    """`storage/postlora/` next to `storage/antelora/`."""
    return antelora_root().parent / "postlora"


def find_command() -> Optional[str]:
    explicit = os.environ.get("DOUBLE_TOUCH_MFLUX_TRAIN", "").strip()
    if explicit:
        return explicit
    found = shutil.which(COMMAND)
    if found:
        return found
    from . import image_gen  # the generate command's folder is the likeliest place

    base = image_gen.find_command()
    if base:
        beside = Path(base).with_name(COMMAND)
        if beside.is_file():
            return str(beside)
    return None


def collected_dir(antelora: str, output: str, root: Optional[Path] = None) -> Path:
    return (root or antelora_root()) / safe_name(antelora, "mccay") / "_collected" / safe_name(output, "train")


def default_name(epochs: int, rank: int) -> str:
    return f"z-image-r{rank}-e{epochs}"


def read_captions(folder: Path) -> list[tuple[Path, str]]:
    """(image, caption) for every row of `<folder>/metadata.jsonl` whose image exists."""
    meta = folder / "metadata.jsonl"
    if not meta.is_file():
        raise TrainError(
            f"{folder} has no metadata.jsonl - run Collect Antelora for this set first"
        )
    pairs: list[tuple[Path, str]] = []
    for line in meta.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        name, text = row.get("file_name"), str(row.get("text") or "").strip()
        image = folder / str(name or "")
        if name and text and image.is_file():
            pairs.append((image, text))
    if not pairs:
        raise TrainError(f"{folder} has no captioned images to train on")
    return pairs


def prepare(
    pairs: list[tuple[Path, str]],
    run_dir: Path,
    *,
    epochs: int,
    rank: int,
    learning_rate: float,
    resolution: int,
    trigger: str = "",
    quantize: Optional[int] = None,
    preview: str = "",
) -> Path:
    """Write `<run>/data/` (image + .txt pairs) and `<run>/train.json`; return the config path."""
    data = run_dir / "data"
    if data.exists():
        shutil.rmtree(data)
    data.mkdir(parents=True)
    used: set[str] = set()
    prefix = f"{trigger}, " if trigger else ""
    for image, text in pairs:
        stem = safe_name(image.stem, "img")
        n, unique = 2, stem
        while unique in used:
            unique, n = f"{stem}_{n}", n + 1
        used.add(unique)
        shutil.copyfile(image, data / f"{unique}{image.suffix.lower()}")
        (data / f"{unique}.txt").write_text(prefix + text, encoding="utf-8")
    (data / "preview.txt").write_text(preview.strip() or prefix + pairs[0][1], encoding="utf-8")

    targets: list[dict[str, Any]] = [
        {"module_path": m, "blocks": dict(_BLOCKS), "rank": rank} for m in _BLOCK_MODULES
    ]
    targets += [{"module_path": m, "rank": rank} for m in _WHOLE_MODULES]
    save_every = max(1, len(pairs) * max(1, epochs // 4))  # about four checkpoints
    config = {
        "model": MODEL,
        "data": str(data),
        "seed": 4,
        "steps": 9,
        "guidance": 0.0,
        "quantize": quantize,
        "max_resolution": resolution,
        "low_ram": False,
        "training_loop": {
            "num_epochs": epochs,
            "batch_size": 1,
            "timestep_low": 4,
            "timestep_high": 9,
        },
        "optimizer": {"name": "AdamW", "learning_rate": learning_rate},
        "checkpoint": {"save_frequency": save_every, "output_path": str(run_dir / "train")},
        "monitoring": {
            "preview_width": 768,
            "preview_height": 768,
            "plot_frequency": 20,
            "generate_image_frequency": save_every,
        },
        "lora_layers": {"targets": targets},
    }
    path = run_dir / "train.json"
    path.write_text(json.dumps(config, indent=2), encoding="utf-8")
    return path


def _checkpoints(run_dir: Path) -> list[Path]:
    """Checkpoint zips of the newest training folder, oldest first."""
    zips = sorted(run_dir.glob("train*/checkpoints/*_checkpoint.zip"))
    return sorted(zips, key=lambda p: (p.parent.parent.name, p.name))


def export(run_dir: Path, name: str) -> dict[str, Any]:
    """Extract the newest adapter to `<run>/<name>.safetensors`."""
    zips = _checkpoints(run_dir)
    if not zips:
        raise TrainError("no checkpoint has been saved yet")
    newest = zips[-1]
    with zipfile.ZipFile(newest) as z:
        members = [m for m in z.namelist() if m.endswith("_adapter.safetensors")]
        if not members:
            raise TrainError(f"{newest.name} holds no adapter")
        out = run_dir / f"{name}.safetensors"
        with z.open(members[0]) as src, open(out, "wb") as dst:
            shutil.copyfileobj(src, dst)
    iteration = int(re.match(r"(\d+)_", newest.name).group(1)) if re.match(r"\d+_", newest.name) else 0
    return {"path": str(out), "iteration": iteration}


class _Job:
    def __init__(self, run_dir: Path, name: str, total: int) -> None:
        self.id = uuid.uuid4().hex
        self.run_dir, self.name = run_dir, name
        self.total, self.step = total, 0
        self.status = "running"  # running | done | failed | cancelled
        self.error: Optional[str] = None
        self.adapter = ""
        self.iteration = 0
        self.lines: deque[str] = deque(maxlen=60)
        self.proc: Any = None
        self.cancelled = False
        self.started = time.time()


_jobs: dict[str, _Job] = {}
_BAR = re.compile(r"(\d+)\s*/\s*(\d+)")


def _pump(job: _Job) -> None:
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
            if "%|" in line:
                m = _BAR.search(line.split("|")[-1])
                if m and int(m.group(2)) > 1:
                    # The trainer's own bar is the one counting the whole run; the
                    # short caching bars before it must not shrink the total.
                    if int(m.group(2)) >= job.total or job.step == 0:
                        job.step = int(m.group(1))
    code = job.proc.wait()
    if job.cancelled:
        job.status = "cancelled"
    elif code == 0:
        try:
            got = export(job.run_dir, job.name)
            job.adapter, job.iteration, job.step = got["path"], got["iteration"], job.total
            job.status = "done"
        except TrainError as exc:
            job.status, job.error = "failed", f"training ended but {exc}"
    else:
        tail = " | ".join(list(job.lines)[-3:])
        job.status = "failed"
        job.error = f"{COMMAND} exited with code {code}" + (f": {tail}" if tail else "")


def start_train(
    antelora: str = "mccay",
    output: str = "train",
    name: str = "",
    epochs: int = 20,
    rank: int = 16,
    learning_rate: float = 1e-4,
    resolution: int = 768,
    trigger: str = "",
    quantize: int = 0,
    dataset: str = "",
    command: Optional[str] = None,
    root: Optional[Path] = None,
) -> dict[str, Any]:
    """[dataset], when given, is the Collect Antelora output folder itself (what the
    node receives on its port); otherwise it is found from [antelora] and [output]."""
    if epochs < 1:
        raise TrainError("epochs must be at least 1")
    if not 1 <= rank <= 128:
        raise TrainError("rank must be between 1 and 128")
    if not 0 < learning_rate <= 1e-2:
        raise TrainError("learning rate must be above 0 and at most 0.01")
    if resolution < 256 or resolution > 1536 or resolution % 16:
        raise TrainError("resolution must be a multiple of 16 from 256 to 1536")
    if quantize not in (0, 4, 8):
        raise TrainError("quantize must be 0 (none), 4 or 8")
    if any(j.status == "running" for j in _jobs.values()):
        raise TrainError("an image LoRA is already training - wait for it or cancel it")
    exe = command or find_command()
    if not exe:
        raise TrainError(INSTALL_HINT)

    if dataset.strip():
        folder = Path(dataset.strip()).expanduser()
        set_name = folder.parent.parent.name if folder.parent.name == "_collected" else folder.name
    else:
        folder, set_name = collected_dir(antelora, output, root), antelora
    pairs = read_captions(folder)
    name = safe_name(name, default_name(epochs, rank))
    run_dir = (root.parent / "postlora" if root else lora_root()) / safe_name(set_name, "mccay") / name
    if run_dir.exists():
        stamp = time.strftime("%Y%m%d_%H%M%S")
        name = f"{name}_{stamp}"
        run_dir = run_dir.with_name(name)
    run_dir.mkdir(parents=True)
    config = prepare(
        pairs, run_dir, epochs=epochs, rank=rank, learning_rate=learning_rate,
        resolution=resolution, trigger=safe_name(trigger, "") if trigger else "",
        quantize=quantize or None,
    )
    job = _Job(run_dir, name, total=epochs * len(pairs))
    try:
        job.proc = _popen(
            [exe, "--config", str(config)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT
        )
    except OSError as exc:
        raise TrainError(f"could not start {exe}: {exc}")
    _jobs[job.id] = job
    threading.Thread(target=_pump, args=(job,), daemon=True).start()
    return {
        "run_id": job.id, "adapter": str(run_dir / f"{name}.safetensors"),
        "images": len(pairs), "total": job.total, "run_dir": str(run_dir),
    }


def _job(run_id: str) -> _Job:
    job = _jobs.get(run_id)
    if job is None:
        raise TrainError(f"no such training run: {run_id}")
    return job


def train_status(run_id: str) -> dict[str, Any]:
    job = _job(run_id)
    return {
        "status": job.status, "step": job.step, "total": job.total,
        "adapter": job.adapter or str(job.run_dir / f"{job.name}.safetensors"),
        "iteration": job.iteration, "error": job.error,
        "lines": list(job.lines)[-8:],
        "checkpoints": len(_checkpoints(job.run_dir)),
    }


def export_now(run_id: str) -> dict[str, Any]:
    """Pull the newest checkpoint's adapter out while training is still running."""
    job = _job(run_id)
    got = export(job.run_dir, job.name)
    job.adapter, job.iteration = got["path"], got["iteration"]
    return train_status(run_id)


def cancel_train(run_id: str) -> dict[str, Any]:
    job = _job(run_id)
    if job.status == "running":
        job.cancelled = True
        job.proc.terminate()
    return train_status(run_id)


def main(argv: Optional[list[str]] = None) -> int:
    import argparse

    p = argparse.ArgumentParser(description="Train a Z-Image-Turbo LoRA from a collected antelora.")
    p.add_argument("antelora", nargs="?", default="mccay")
    p.add_argument("--output", default="train", help="Collect Antelora output folder name")
    p.add_argument("--name", default="")
    p.add_argument("--epochs", type=int, default=20)
    p.add_argument("--rank", type=int, default=16)
    p.add_argument("--lr", type=float, default=1e-4)
    p.add_argument("--resolution", type=int, default=768)
    p.add_argument("--trigger", default="", help="word put in front of every caption")
    p.add_argument("-q", "--quantize", type=int, default=0)
    p.add_argument("--prepare-only", action="store_true", help="write data and config, do not train")
    a = p.parse_args(argv)
    try:
        if a.prepare_only:
            pairs = read_captions(collected_dir(a.antelora, a.output))
            name = safe_name(a.name, default_name(a.epochs, a.rank))
            run_dir = lora_root() / safe_name(a.antelora, "mccay") / name
            run_dir.mkdir(parents=True, exist_ok=True)
            cfg = prepare(
                pairs, run_dir, epochs=a.epochs, rank=a.rank, learning_rate=a.lr,
                resolution=a.resolution, trigger=a.trigger, quantize=a.quantize or None,
            )
            print(f"{len(pairs)} images; config {cfg}")
            return 0
        started = start_train(
            a.antelora, a.output, a.name, a.epochs, a.rank, a.lr, a.resolution,
            a.trigger, a.quantize,
        )
        job = _jobs[started["run_id"]]
        print(f"training {started['images']} images, {started['total']} steps -> {started['adapter']}")
        while job.status == "running":
            time.sleep(5)
            print(f"  step {job.step}/{job.total}  {job.lines[-1] if job.lines else ''}")
        print(job.status, job.error or job.adapter)
        return 0 if job.status == "done" else 1
    except TrainError as exc:
        print(f"error: {exc}")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
