# DoubleTouch — SAM3 segmentation backend

The SAM3 service for DoubleNaught (`DoubleTouch` in the module map). Exposes the
three interaction modalities used by `double_vision`'s `Sam3ControlPanel`, with
**camelCase JSON** on the wire per `double_vision/DESIGN.md`.

## Run

```sh
cd double_touch
pip install -e '.[dev]'
python -m double_touch          # serves on http://127.0.0.1:8000
# or, from the repo root:
../run.sh DT
```

Env: `DOUBLE_TOUCH_HOST`, `DOUBLE_TOUCH_PORT` (default `8000`), `DOUBLE_TOUCH_RELOAD=1`.

## Endpoints

| Method | Path             | Body / params                                   |
|--------|------------------|-------------------------------------------------|
| GET    | `/health`        | —                                               |
| POST   | `/session`       | `?width&height` — mint a session for testing    |
| POST   | `/upload`        | multipart `file` (+ optional `width`/`height`)  |
| POST   | `/segment/text`  | `{ sessionId, prompt }`                         |
| POST   | `/segment/box`   | `{ sessionId, box:[cx,cy,w,h], include }`       |
| POST   | `/segment/point` | `{ sessionId, point:[x,y], include }`           |

`box`/`point` are normalized to 0..1. `include` is the include/exclude tag
(`true` = include).

### Response shape (camelCase)

```jsonc
{
  "sessionId": "…",
  "promptKind": "text | box | point",
  "results": {
    "originalWidth": 800, "originalHeight": 600,
    "segmentMask": [ { "format": "bboxPlaceholder", "size": [h,w], "bbox": [..] } ],
    "boxes": [[x0,y0,x1,y1]], "scores": [0.5],
    "promptedRegions": [ { "box": [..], "include": true, "isPoint": false } ]
  },
  "inferenceMetrics": { "processingTimeMs": 1.2, "peakMemoryMb": null, "maskCount": 1 }
}
```

## Inference engine

Routes delegate to an `InferenceEngine` (`inference.py`). The default
`StubInferenceEngine` returns **deterministic bounding-box placeholder masks**
(`format == "bboxPlaceholder"`) so the service and the Flutter client work
end-to-end without model weights. To wire the real model, port the `mlx_sam3`
`processor` + `serialize_state` behind this interface and assign it to
`app.engine`.

## Test

```sh
pytest        # asserts the camelCase contract
```
