"""Auto-imported by every python3.11 invocation in this image (the standard
`sitecustomize` hook, guaranteed to be found via the /opt/pysitecustomize
PYTHONPATH entry set in the Dockerfile -- not relying on sysconfig's purelib
guess, which turned out not to match where Debian/deadsnakes python actually
puts things on sys.path at runtime: the previous version of this file never
actually got imported, confirmed live by the patched dict not showing up in
a later error's own printed SUPPORTED_RETURN_TYPES) - including entrypoint.py's
`subprocess.call(["python3.11", "run.py", ...])`, a separate process a plain
monkeypatch in entrypoint.py itself wouldn't reach.

The cu124 wheel index tops out at torch 2.6.0 (confirmed live: no 2.7+
published there), so getting a newer torch means switching CUDA wheel series
entirely (cu126/cu128) - reopening the whole base-image-compatibility chain
documented in the Dockerfile for what's actually a one-line Python gap:
2.6.0's torch.library.infer_schema doesn't recognize a bare `list[Tensor]`
return annotation, only `typing.List[Tensor]` (confirmed against the real
torch v2.6.0 source: torch/_library/infer_schema.py's SUPPORTED_RETURN_TYPES
dict has no bare-generic entry). diffusers' pinned dev commit uses the bare
form in several `forward` methods (e.g. models/adapter.py), raising
"infer_schema(func): Return has unsupported type list[torch.Tensor]" at
custom-op registration time (confirmed live).

Prints to stdout either way, so a failure here shows up in Cloud Logging
instead of silently no-op'ing again.
"""
try:
    import torch
    from torch._library.infer_schema import SUPPORTED_RETURN_TYPES

    SUPPORTED_RETURN_TYPES.setdefault(list[torch.Tensor], "Tensor[]")
    print(
        f"[sitecustomize] patched torch._library.infer_schema.SUPPORTED_RETURN_TYPES "
        f"(torch {torch.__version__}); list[Tensor] now present: "
        f"{list[torch.Tensor] in SUPPORTED_RETURN_TYPES}"
    )
except Exception as exc:  # noqa: BLE001 - deliberately broad, see module docstring
    print(f"[sitecustomize] FAILED to patch infer_schema: {exc!r}")
