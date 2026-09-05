#!/usr/bin/env zsh
# DoubleNaught task runner.
#
# Usage:
#   ./run.sh FE [flutter run args...]   Run the double_vision Flutter app (macOS)
#   ./run.sh BE [uvicorn args...]       Run the double_touch SAM3 backend
#
# Examples:
#   ./run.sh FE                         # runs on macOS (no device prompt)
#   ./run.sh FE --dart-define=SANITY_PROJECT_ID=xxxx --dart-define=SANITY_TOKEN=skxxxx
#   ./run.sh BE                         # SAM3 backend on http://127.0.0.1:8400
#
# Layout mirrors SegForge: frontend/ holds the Flutter app (Dart package
# `double_vision`), backend/ holds the FastAPI service (Python package
# `double_touch`). The directories are named for their role, the packages keep
# their distinctive names.
#
# Note: FE always passes `-d macos`. To run on another device, invoke
# `flutter run -d <device>` directly from the frontend/ directory.
#
# Ports: DoubleNaught uses 8400, SegForge uses 8401, so both can run at once.
# Override the backend with DOUBLE_TOUCH_PORT, and the frontend's view of it
# with `./run.sh FE --dart-define=DN_BACKEND_URL=http://127.0.0.1:<port>`.

set -e
# Correct configuration for run.sh
unset PYTHON_JULIACALL_EXE
export PYTHON_JULIACALL_EXE="$(which julia)"
export JULIA_PROJECT="$(pwd)"
export PYTHON_JULIACALL_PROJECT="$(pwd)"

# Absolute path to this script's directory, so it works from anywhere.
ROOT="${0:A:h}"
# Program name for messages ($0 is rebound to the function name inside funcs).
PROG="${0:t}"

usage() {
  print -u2 "Usage: $PROG <command> [args...]"
  print -u2 ""
  print -u2 "Commands:"
  print -u2 "  FE [flutter run args...]   Run the double_vision Flutter app"
  print -u2 "  BE [uvicorn args...]       Run the double_touch SAM3 backend"
  exit 1
}

cmd="$1"
[[ -z "$cmd" ]] && usage
shift

case "$cmd" in
  FE)
    cd "$ROOT/frontend"
    # Always target macOS so Flutter doesn't prompt for a device, and point
    # local JSON persistence (Inventory) at the repo's storage/ directory.
    exec flutter run -d macos \
      --dart-define=DN_STORAGE_DIR="$ROOT/storage" "$@"
    ;;
  BE)
    cd "$ROOT/backend"
    # Use the dedicated, isolated venv so backend deps never touch the base env.
    if [[ ! -x ".venv/bin/python" ]]; then
      print -u2 "backend/.venv not found. Create it with:"
      print -u2 "  python3 -m venv backend/.venv"
      print -u2 "  backend/.venv/bin/pip install -e 'backend[dev]'"
      exit 1
    fi
    exec .venv/bin/python -m double_touch "$@"
    ;;
  *)
    print -u2 "Unknown command: $cmd"
    usage
    ;;
esac
