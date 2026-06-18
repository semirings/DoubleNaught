"""DoubleTouch — the SAM3 segmentation backend for DoubleNaught.

Exposes three interaction modalities (text / box / point) over a clean FastAPI
surface whose JSON payloads use camelCase keys, per the DoubleNaught design doc.
Inference is delegated to a pluggable :class:`InferenceEngine`; the bundled
:class:`StubInferenceEngine` returns deterministic placeholder results so the
service runs end-to-end before the real MLX SAM3 model is wired in.
"""

__all__ = ["__version__"]
__version__ = "0.1.0"
