"""Entry point: ``python -m double_touch`` (or the ``double-touch`` script)."""

from __future__ import annotations

import os


def main() -> None:
    import uvicorn

    uvicorn.run(
        "double_touch.app:app",
        host=os.environ.get("DOUBLE_TOUCH_HOST", "127.0.0.1"),
        port=int(os.environ.get("DOUBLE_TOUCH_PORT", "8000")),
        reload=bool(os.environ.get("DOUBLE_TOUCH_RELOAD")),
    )


if __name__ == "__main__":
    main()
