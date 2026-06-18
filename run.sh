#!/usr/bin/env zsh
# DoubleNaught task runner.
#
# Usage:
#   ./run.sh DV [flutter run args...]   Run the double_vision Flutter app
#   ./run.sh DT [uvicorn args...]       Run the double_touch SAM3 backend
#
# Examples:
#   ./run.sh DV                         # default device (Flutter prompts/picks)
#   ./run.sh DV -d chrome               # run on Chrome
#   ./run.sh DV -d macos
#   ./run.sh DV --dart-define=SANITY_PROJECT_ID=xxxx --dart-define=SANITY_TOKEN=skxxxx
#   ./run.sh DT                         # SAM3 backend on http://127.0.0.1:8000

set -e

# Absolute path to this script's directory, so it works from anywhere.
ROOT="${0:A:h}"
# Program name for messages ($0 is rebound to the function name inside funcs).
PROG="${0:t}"

usage() {
  print -u2 "Usage: $PROG <command> [args...]"
  print -u2 ""
  print -u2 "Commands:"
  print -u2 "  DV [flutter run args...]   Run the double_vision Flutter app"
  print -u2 "  DT [uvicorn args...]       Run the double_touch SAM3 backend"
  exit 1
}

cmd="$1"
[[ -z "$cmd" ]] && usage
shift

case "$cmd" in
  DV)
    cd "$ROOT/double_vision"
    exec flutter run "$@"
    ;;
  DT)
    cd "$ROOT/double_touch"
    # Use the dedicated, isolated venv so backend deps never touch the base env.
    if [[ ! -x ".venv/bin/python" ]]; then
      print -u2 "double_touch/.venv not found. Create it with:"
      print -u2 "  python3 -m venv double_touch/.venv"
      print -u2 "  double_touch/.venv/bin/pip install -e 'double_touch[dev]'"
      exit 1
    fi
    exec .venv/bin/python -m double_touch "$@"
    ;;
  *)
    print -u2 "Unknown command: $cmd"
    usage
    ;;
esac
