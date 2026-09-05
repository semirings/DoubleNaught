"""Entry point: ``python -m double_touch`` (or the ``double-touch`` script)."""

from __future__ import annotations

import os
from pathlib import Path
from dotenv import load_dotenv


def main() -> None:
    # 1. Define paths to local and global env files
    local_env = Path(".env")
    global_env = Path.home() / ".gemini" / ".env"

    # 2. Load global env first, then override with local env if present
    if global_env.exists():
        load_dotenv(dotenv_path=global_env)

    if local_env.exists():
        load_dotenv(dotenv_path=local_env, override=True)

    import uvicorn

    # 8400 keeps DoubleNaught clear of SegForge, which serves its own FastAPI
    # backend on 8401 so the two can run side by side. The frontend default
    # lives in double_vision/lib/backend_config.dart; keep the two in step.
    uvicorn.run(
        "double_touch.app:app",
        host=os.environ.get("DOUBLE_TOUCH_HOST", "127.0.0.1"),
        port=int(os.environ.get("DOUBLE_TOUCH_PORT", "8400")),
        reload=bool(os.environ.get("DOUBLE_TOUCH_RELOAD")),
    )


if __name__ == "__main__":
    main()
