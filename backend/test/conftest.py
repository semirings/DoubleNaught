"""Shared pytest fixtures/markers for the double_touch test suite."""

from __future__ import annotations

import os
import subprocess
import sys

import pytest


def _d4m_jl_available() -> bool:
    """Whether D4M.jl actually loads via juliacall right now.

    Run in a subprocess with a hard timeout, not a plain in-process
    try/except: a broken Julia environment doesn't necessarily fail fast — it
    can hang (a stuck precompile lock did exactly this while diagnosing the
    issue this guard exists for). A skip-check that can itself hang would
    block collecting every test file that uses it, which defeats the point.
    """
    try:
        result = subprocess.run(
            [sys.executable, "-c", "from double_touch.d4m_ops import warm; warm()"],
            timeout=30,
            capture_output=True,
        )
        return result.returncode == 0
    except Exception:
        return False


#: Apply to any test that exercises the D4M.jl bridge (`d4m_ops._julia()`),
#: directly or via a helper like `d4m_ops.build_assoc`. Distinct from any
#: `julia_required` marker some test files define for the separate
#: `extract_ast.jl` subprocess dependency (Julia + Arrow.jl on PATH) — that
#: one doesn't exercise this in-process bridge at all.
d4m_jl_required = pytest.mark.skipif(
    not _d4m_jl_available(),
    reason="D4M.jl did not load via juliacall — see d4m_ops._julia(); "
    "skip rather than fail when the Julia environment isn't ready",
)


_exitstatus: int = 0


def pytest_sessionfinish(session, exitstatus):
    """Record the exit status; the actual force-exit happens in unconfigure.

    Same root cause and fix as `app.py`'s `_shutdown_force_exit`: juliacall
    registers an `atexit` hook (`jl_atexit_hook`) that runs Julia's own
    finalizers, and that can hang the interpreter on shutdown depending on
    what Julia-side state is still alive — independent of whether the tests
    themselves passed. `os._exit()` bypasses the atexit chain entirely.

    Deliberately not done here, even with a `hookwrapper` that `yield`s past
    every other `pytest_sessionfinish` implementation first: the terminal
    reporter's own final summary line (`TerminalReporter.pytest_sessionfinish`
    -> `summary_stats()`) writes through a `TerminalWriter` that only flushes
    when explicitly told to — a bare `sys.stdout.flush()` here raced it and
    the summary line never made it out. `pytest_unconfigure` fires later,
    after session teardown has actually finished writing and flushing
    everything, so waiting for it (rather than trying to out-flush the
    terminal reporter by hand) is the reliable option.
    """
    global _exitstatus
    _exitstatus = int(exitstatus)


def pytest_unconfigure(config):
    from double_touch import d4m_ops

    if d4m_ops._d4m_ready:
        sys.stdout.flush()
        sys.stderr.flush()
        os._exit(_exitstatus)
