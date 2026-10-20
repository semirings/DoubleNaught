"""Look inside a LoRA ``.safetensors`` file and say whether Generate can use it.

A safetensors file starts with an 8-byte little-endian length and then a JSON
header naming every tensor and its shape, so the whole check reads a few
kilobytes and never loads the weights.

What "can use it" means is mflux's own rule for Qwen-Image-2.1
(``Qwen21LoRAMapping`` in mflux 0.22): per transformer block it looks for
``attn.to_q/k/v``, ``attn.to_out.0`` and the gated MLP (``img_mlp.proj`` /
``gate_layer`` / ``out``, or a fused ``img_mlp.gate_up``), under a
``transformer.`` or ``diffusion_model.`` prefix or none. A LoRA made for another
model — SDXL, FLUX, the older Qwen-Image — has different names, and mflux
would match few or none of them.

Verdicts:

* ``yes``     attention and the Qwen-Image-2.1 MLP both match.
* ``partial`` some Qwen-style names match but not the MLP (typical of a LoRA
              for the older Qwen-Image); it would load but change less.
* ``no``      nothing matches, so the LoRA would do nothing or fail.
"""

from __future__ import annotations

import json
import re
import struct
from pathlib import Path
from typing import Any

MAX_HEADER = 64 * 1024 * 1024  # a LoRA's header is kilobytes; refuse nonsense

# Anchored: unanchored, "single_transformer_blocks." (FLUX / Z-Image) would match.
_BLOCK = r"^(?:transformer\.|diffusion_model\.)?transformer_blocks\.(\d+)\."
_SUFFIX = r"\.lora_([AB])(?:\.default)?\.weight$"
_ATTN = re.compile(_BLOCK + r"(attn\.to_q|attn\.to_k|attn\.to_v|attn\.to_out\.0)" + _SUFFIX)
# Qwen-Image-2.1's gated MLP. The older Qwen-Image used img_mlp.net.0.proj /
# img_mlp.net.2, which are deliberately not matched.
_MLP = re.compile(_BLOCK + r"(img_mlp\.(?:proj|gate_layer|out|gate_up))" + _SUFFIX)
_OLD_MLP = re.compile(_BLOCK + r"img_mlp\.net\.\d+(?:\.proj)?" + _SUFFIX)

# (pattern on a tensor name, short family id, description). First match wins, so
# the specific ones come first. These are naming conventions, not guarantees: a
# renamed or converted LoRA can look like something it is not.
_OTHER_FAMILIES = (
    (re.compile(r"^lora_unet_(double|single)_blocks_|(^|\.)(double_blocks|single_blocks)\."),
     "flux1", "a FLUX.1 LoRA"),
    (re.compile(r"^lora_te[12]_"), "sdxl", "an SDXL LoRA"),
    (re.compile(r"^lora_te_"), "sd15", "an SD 1.5 LoRA"),
    (re.compile(r"^lora_unet_(down|up|mid)_block|^lora_unet_(input|output|middle)_block"),
     "sd", "an SD 1.5 or SDXL LoRA"),
    (re.compile(r"^unet\.|^text_encoder|(^|\.)(down_blocks|up_blocks|mid_block)\."),
     "sd", "an SD 1.5 or SDXL LoRA"),
    (re.compile(r"(^|\.)single_transformer_blocks\."), "flux-or-zimage", "a FLUX or Z-Image LoRA"),
    (re.compile(r"^lora_unet_"), "kohya", "a kohya-style LoRA for another model"),
)


class LoraFileError(Exception):
    """A file that cannot be read as a safetensors LoRA; the message is for the user."""


def read_header(path: str) -> dict[str, Any]:
    p = Path(path).expanduser()
    if not p.is_file():
        raise LoraFileError(f"file not found: {path}")
    if p.suffix.lower() != ".safetensors":
        raise LoraFileError("a LoRA file ends in .safetensors")
    try:
        with p.open("rb") as f:
            raw = f.read(8)
            if len(raw) < 8:
                raise LoraFileError("not a safetensors file (too short)")
            (size,) = struct.unpack("<Q", raw)
            if size > MAX_HEADER:
                raise LoraFileError("not a safetensors file (header is implausibly large)")
            blob = f.read(size)
        if len(blob) < size:
            raise LoraFileError("the safetensors file is truncated")
        header = json.loads(blob)
    except (OSError, ValueError) as exc:
        raise LoraFileError(f"cannot read {p.name}: {exc}")
    if not isinstance(header, dict):
        raise LoraFileError("not a safetensors file (header is not a JSON object)")
    return header


def inspect_lora(path: str) -> dict[str, Any]:
    p = Path(path).expanduser()
    header = read_header(path)
    meta = header.pop("__metadata__", None)
    names = list(header)

    lora_keys = [n for n in names if ".lora_" in n or n.startswith("lora_")]
    if not lora_keys:
        return _result(p, names, 0, None, "no", "none",
                       "no LoRA tensors in this file (it may be a full model or a checkpoint)", meta)

    attn = [n for n in names if _ATTN.search(n)]
    mlp = [n for n in names if _MLP.search(n)]
    old_mlp = [n for n in names if _OLD_MLP.search(n)]
    rank = _rank(header, names)

    if attn and mlp:
        verdict, family = "yes", "qwen-image-2.1"
        msg = "fits Qwen-Image-2.1 (attention and MLP layers match)"
    elif attn or mlp:
        verdict = "partial"
        family = "qwen-image" if old_mlp else "qwen-like"
        if old_mlp:
            msg = ("looks like a LoRA for the older Qwen-Image: the attention layers match "
                   "but its MLP layers do not, so it will change less than intended")
        else:
            msg = "only some of its layers match Qwen-Image-2.1; expect a weaker effect"
    else:
        verdict = "no"
        hit = next(((f, d) for rx, f, d in _OTHER_FAMILIES
                    for n in lora_keys if rx.search(n)), None)
        family = hit[0] if hit else "unknown"
        msg = (f"this looks like {hit[1]}; none of its layers match Qwen-Image-2.1" if hit
               else "none of its layer names match Qwen-Image-2.1")
    return _result(p, names, len(attn) + len(mlp), rank, verdict, family, msg, meta)


def _rank(header: dict[str, Any], names: list[str]) -> int | None:
    for n in names:
        if ".lora_A" in n:
            shape = header[n].get("shape") if isinstance(header[n], dict) else None
            if shape and len(shape) == 2:
                return int(min(shape))  # A is (rank, in)
    return None


def _result(p: Path, names, matched, rank, verdict, family, message, meta) -> dict[str, Any]:
    base = (meta or {}).get("ss_base_model_version") or (meta or {}).get("modelspec.architecture")
    return {
        "path": str(p),
        "name": p.name,
        "tensors": len(names),
        "matched": matched,
        "rank": rank,
        "compatible": verdict,
        "family": family,
        "message": message,
        "base_model": str(base) if base else None,
    }


if __name__ == "__main__":  # python -m double_touch.lora_files FILE_OR_FOLDER ...
    import sys

    files: list[Path] = []
    for arg in sys.argv[1:]:
        q = Path(arg).expanduser()
        files += sorted(q.rglob("*.safetensors")) if q.is_dir() else [q]
    if not files:
        sys.exit("usage: python -m double_touch.lora_files FILE_OR_FOLDER ...")
    for f in files:
        try:
            r = inspect_lora(str(f))
            print(f"{r['compatible']:<8}{r['family']:<16}rank {r['rank'] or '?':<4} {f.name}\n"
                  f"        {r['message']}")
        except LoraFileError as exc:
            print(f"error   {f.name}: {exc}")
