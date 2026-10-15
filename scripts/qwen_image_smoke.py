#!/usr/bin/env python3
"""One-image smoke test: does Qwen-Image-2.1 run on this Mac?

Run it in its OWN virtualenv, not the DoubleNaught backend one:

    python3 -m venv ~/qwen-test && source ~/qwen-test/bin/activate
    pip install torch torchvision "transformers>=5.17" accelerate pillow safetensors
    pip install git+https://github.com/huggingface/diffusers
    python scripts/qwen_image_smoke.py

The first run downloads the model from Hugging Face (large). Start small: the
defaults are 512x512 and 8 steps, to find out *whether* it works and how fast.
Add --lora some.safetensors to test a LoRA. It prints one clear verdict at the
end and never raises past it, so paste the output back if it fails.
"""

import argparse
import os
import sys
import time
import traceback

os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")  # CPU for unsupported MPS ops

MODEL = "Qwen/Qwen-Image-2.1"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--prompt", default="a small boy asleep in an enormous ornate bed, "
                                        "early 1900s newspaper comic, fine pen linework")
    ap.add_argument("--steps", type=int, default=8)
    ap.add_argument("--size", type=int, default=512)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--dtype", choices=["bfloat16", "float16", "float32"], default="bfloat16")
    ap.add_argument("--lora", default="", help="optional LoRA .safetensors to load")
    ap.add_argument("--out", default="qwen_smoke.png")
    a = ap.parse_args()

    try:
        import torch
        import transformers
        import diffusers
    except ImportError as e:
        print(f"VERDICT: missing package: {e}")
        return 1

    print(f"torch {torch.__version__}  transformers {transformers.__version__}  "
          f"diffusers {diffusers.__version__}")
    if not torch.backends.mps.is_available():
        print("VERDICT: MPS (the Mac GPU) is not available to this torch build.")
        return 1
    if not hasattr(diffusers, "QwenImage21Pipeline"):
        print("VERDICT: this diffusers has no QwenImage21Pipeline — install it from GitHub:\n"
              "  pip install --upgrade git+https://github.com/huggingface/diffusers")
        return 1

    dtype = getattr(torch, a.dtype)
    t0 = time.time()
    try:
        print(f"loading {MODEL} as {a.dtype} (first run downloads; be patient) …")
        pipe = diffusers.QwenImage21Pipeline.from_pretrained(MODEL, torch_dtype=dtype)
        pipe.to("mps")
        print(f"loaded in {time.time() - t0:.0f}s")
        if a.lora:
            print(f"loading LoRA {a.lora}")
            pipe.load_lora_weights(a.lora)

        t1 = time.time()
        gen = torch.Generator("cpu").manual_seed(a.seed)
        image = pipe(
            prompt=a.prompt,
            num_inference_steps=a.steps,
            height=a.size,
            width=a.size,
            generator=gen,
        ).images[0]
        image.save(a.out)
        secs = time.time() - t1
        mem = ""
        if hasattr(torch.mps, "driver_allocated_memory"):
            mem = f", GPU memory in use ≈ {torch.mps.driver_allocated_memory() / 2**30:.1f} GiB"
        print(f"VERDICT: OK — {a.size}x{a.size}, {a.steps} steps in {secs:.0f}s "
              f"({secs / a.steps:.1f}s/step){mem}. Saved {a.out}")
        return 0
    except Exception as e:  # report, don't crash: the failure mode is the answer
        traceback.print_exc()
        hint = ""
        if "bfloat16" in str(e).lower() or "bf16" in str(e).lower():
            hint = " Try --dtype float16."
        elif "out of memory" in str(e).lower():
            hint = " Out of memory: try --size 384, or --dtype float16."
        print(f"VERDICT: FAILED after {time.time() - t0:.0f}s — {type(e).__name__}: {e}.{hint}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
