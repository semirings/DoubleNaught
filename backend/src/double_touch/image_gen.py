"""Generate an image with Qwen-Image-2.1 through mflux (Apple Silicon, MLX).

Runs the `mflux-generate-qwen-2.1` command as a subprocess so mflux can live in
its own environment (it pins its own `mlx`; keep it away from other tools).
Point at it with $DOUBLE_TOUCH_MFLUX_QWEN21 if it is not on PATH.

A generation is a job: [start_generate] returns at once; poll [generate_status]
(progress comes from the tqdm bar), fetch the PNG with [generate_result].
Flags used are the ones mflux 0.22's parser defines: --prompt --steps --seed
--width --height -q --output --guidance --lora PATH SCALE --image PATH STRENGTH.

Three modes, by whether and how a start picture is used:

* ``text2img`` (default): no ``--image`` flag at all — a plain prompt-only
  generation on the base txt2img command. This is also what a stray
  ``image_b64`` falls through to if one happens to be wired in without the
  mode being changed, same as before this mode existed; explicitly picking
  ``text2img`` just makes "no picture, on purpose" visible rather than
  implicit.
* ``img2img``: `mflux-generate-qwen-2.1 --image PATH STRENGTH`. The picture is
  noised and repainted, so a HIGH strength keeps the picture and the prompt
  matters less. Requires a start picture — raises if none is given, so an
  explicit choice of this mode can't silently fall back to text2img.
* ``edit``: `mflux-generate-qwen-2.1-edit --image-paths PATH [--strength S]`.
  The picture is a reference and the prompt is an instruction. `--strength` is
  the edit strength, 1.0 = full edit and lower = subtler (the opposite sense).
  Width and height must be multiples of 32 here. Found via
  $DOUBLE_TOUCH_MFLUX_QWEN21_EDIT, PATH, or beside the txt2img command.
"""

from __future__ import annotations

import base64
import binascii
import os
import re
import shutil
import subprocess
import tempfile
import threading
import time
import uuid
from collections import deque
from pathlib import Path
from typing import Any, Optional

from .loraset import loraset_root

COMMAND = "mflux-generate-qwen-2.1"
EDIT_COMMAND = "mflux-generate-qwen-2.1-edit"
ZIMAGE_COMMAND = "mflux-generate-z-image-turbo"
MODES = ("text2img", "img2img", "edit")
# A LoRA only works on the model family it was trained on.
FAMILIES = ("qwen", "z-image")
DEFAULT_MODEL_IDS = {"qwen/qwen-image-2.1", "qwen-image-2.1"}
INSTALL_HINT = (
    f"{COMMAND} was not found. Install mflux 0.22+ in its own environment "
    '(pip install -U mflux) and put it on PATH, or set DOUBLE_TOUCH_MFLUX_QWEN21 '
    "to the command's full path."
)

ZIMAGE_INSTALL_HINT = (
    f"{ZIMAGE_COMMAND} was not found. It ships with mflux 0.22+; put it on PATH, "
    "or set DOUBLE_TOUCH_MFLUX_ZIMAGE to the command's full path."
)

EDIT_INSTALL_HINT = (
    f"{EDIT_COMMAND} was not found. It ships with mflux 0.22+; put it on PATH, "
    "or set DOUBLE_TOUCH_MFLUX_QWEN21_EDIT to the command's full path."
)

_popen = subprocess.Popen  # seam for tests


class GenerateError(Exception):
    """A request that cannot run; the message is meant for the user."""


def output_root() -> Path:
    """`storage/generated/` next to `storage/loraset/`."""
    return loraset_root().parent / "generated"


def find_command() -> Optional[str]:
    explicit = os.environ.get("DOUBLE_TOUCH_MFLUX_QWEN21", "").strip()
    return explicit or shutil.which(COMMAND)


def find_zimage_command() -> Optional[str]:
    explicit = os.environ.get("DOUBLE_TOUCH_MFLUX_ZIMAGE", "").strip()
    if explicit:
        return explicit
    found = shutil.which(ZIMAGE_COMMAND)
    if found:
        return found
    base = find_command()
    if base:
        beside = Path(base).with_name(ZIMAGE_COMMAND)
        if beside.is_file():
            return str(beside)
    return None


def find_edit_command() -> Optional[str]:
    explicit = os.environ.get("DOUBLE_TOUCH_MFLUX_QWEN21_EDIT", "").strip()
    if explicit:
        return explicit
    found = shutil.which(EDIT_COMMAND)
    if found:
        return found
    base = find_command()  # the txt2img command's own folder is the likeliest place
    if base:
        beside = Path(base).with_name(EDIT_COMMAND)
        if beside.is_file():
            return str(beside)
    return None


class _Job:
    def __init__(
        self, output: Path, steps: int, tmp: Optional[Path], label: str = COMMAND
    ) -> None:
        self.id = uuid.uuid4().hex
        self.label = label  # the command's name, for error messages
        self.output = output
        self.steps = steps
        self.tmp = tmp  # init-image temp dir, removed when the job ends
        self.status = "running"  # running | done | failed | cancelled
        self.step = 0
        self.total = steps
        self.error: Optional[str] = None
        self.lines: deque[str] = deque(maxlen=60)
        self.proc: Any = None
        self.cancelled = False
        self.started = time.time()
        self.seconds: Optional[float] = None


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
                if m and int(m.group(2)) > 0:
                    job.step, job.total = int(m.group(1)), int(m.group(2))
    code = job.proc.wait()
    job.seconds = round(time.time() - job.started, 1)
    if job.tmp:
        shutil.rmtree(job.tmp, ignore_errors=True)
    if job.cancelled:
        job.status = "cancelled"
    elif code == 0 and job.output.is_file():
        job.status = "done"
        job.step = job.total
    else:
        job.status = "failed"
        tail = " | ".join(list(job.lines)[-3:])
        job.error = (
            f"{job.label} exited with code {code}" + (f": {tail}" if tail else "")
            if code != 0
            else f"{job.label} finished but wrote no image at {job.output}"
        )


def start_generate(
    prompt: str,
    model: str = "",
    steps: int = 40,
    width: int = 1024,
    height: int = 1024,
    seed: int = 42,
    quantize: int = 8,
    lora: str = "",
    lora_scale: float = 1.0,
    image_b64: str = "",
    image_strength: float = 0.6,
    mode: str = "text2img",
    edit_strength: float = 1.0,
    family: str = "qwen",
    command: Optional[str] = None,
) -> dict[str, Any]:
    if family not in FAMILIES:
        raise GenerateError(f"family must be one of {', '.join(FAMILIES)}")
    zimage = family == "z-image"
    if mode not in MODES:
        raise GenerateError(f"mode must be one of {', '.join(MODES)}")
    edit = mode == "edit"
    if zimage and edit:
        raise GenerateError("Z-Image has no edit mode - use img2img or no start image")
    if mode == "img2img" and not image_b64:
        raise GenerateError("img2img needs a start image on the image input")
    if not prompt.strip():
        raise GenerateError("enter a prompt")
    if steps < 1:
        raise GenerateError("steps must be at least 1")
    grid = 32 if edit else 16
    if width < 64 or height < 64 or width % grid or height % grid:
        raise GenerateError(
            f"width and height must be multiples of {grid}, at least 64"
        )
    if edit and not image_b64:
        raise GenerateError("edit mode needs a start image on the image input")
    if edit and not (0 < edit_strength <= 1):
        raise GenerateError("edit strength must be above 0 and at most 1")
    if quantize not in (0, 4, 8):
        raise GenerateError("quantize must be 0 (none), 4 or 8")
    if lora and not Path(lora).is_file():
        raise GenerateError(f"LoRA not found: {lora}")
    if zimage:
        exe, hint = command or find_zimage_command(), ZIMAGE_INSTALL_HINT
    elif edit:
        exe, hint = command or find_edit_command(), EDIT_INSTALL_HINT
    else:
        exe, hint = command or find_command(), INSTALL_HINT
    if not exe:
        raise GenerateError(hint)

    tmp: Optional[Path] = None
    cmd = [
        exe, "--prompt", prompt.strip(), "--steps", str(steps),
        "--width", str(width), "--height", str(height), "--seed", str(seed),
    ]
    wanted = model.strip()
    # Z-Image's command only accepts its own model names; the Qwen default must not leak in.
    if wanted and wanted.lower() not in DEFAULT_MODEL_IDS and (not zimage or "z-image" in wanted.lower()):
        cmd += ["--model", wanted]
    if quantize:
        cmd += ["-q", str(quantize)]
    if lora:
        cmd += ["--lora", lora, str(lora_scale)]
    if image_b64:
        try:
            raw = base64.b64decode(image_b64, validate=True)
        except (binascii.Error, ValueError):
            raise GenerateError("the init image is not valid base64")
        tmp = Path(tempfile.mkdtemp(prefix="dn-init-"))
        (tmp / "init.png").write_bytes(raw)
        if edit:
            cmd += ["--image-paths", str(tmp / "init.png")]
            if edit_strength < 1:
                cmd += ["--strength", str(edit_strength)]
        else:
            cmd += ["--image", str(tmp / "init.png"), str(image_strength)]

    out_dir = output_root()
    out_dir.mkdir(parents=True, exist_ok=True)
    output = out_dir / f"gen_{int(time.time() * 1000)}_{seed}.png"
    cmd += ["--output", str(output)]

    job = _Job(output, steps, tmp, ZIMAGE_COMMAND if zimage else EDIT_COMMAND if edit else COMMAND)
    try:
        job.proc = _popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    except OSError as exc:
        if tmp:
            shutil.rmtree(tmp, ignore_errors=True)
        raise GenerateError(f"could not start {exe}: {exc}")
    _jobs[job.id] = job
    threading.Thread(target=_pump, args=(job,), daemon=True).start()
    return {"run_id": job.id, "path": str(output)}


def _job(run_id: str) -> _Job:
    job = _jobs.get(run_id)
    if job is None:
        raise GenerateError(f"no such generation: {run_id}")
    return job


def generate_status(run_id: str) -> dict[str, Any]:
    job = _job(run_id)
    return {
        "status": job.status,
        "step": job.step,
        "total": job.total,
        "path": str(job.output),
        "seconds": job.seconds,
        "error": job.error,
        "lines": list(job.lines)[-8:],
    }


def cancel_generate(run_id: str) -> dict[str, Any]:
    job = _job(run_id)
    if job.status == "running":
        job.cancelled = True
        job.proc.terminate()
    return generate_status(run_id)


def generate_result(run_id: str) -> bytes:
    job = _job(run_id)
    if job.status != "done" or not job.output.is_file():
        raise GenerateError("the image is not ready")
    return job.output.read_bytes()
