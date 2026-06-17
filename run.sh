#!/usr/bin/env zsh
# DoubleNaught task runner.
#
# Usage:
#   ./run.sh DV [flutter run args...]   Run the double_vision Flutter app
#
# Examples:
#   ./run.sh DV                         # default device (Flutter prompts/picks)
#   ./run.sh DV -d chrome               # run on Chrome
#   ./run.sh DV -d macos
#   ./run.sh DV --dart-define=SANITY_PROJECT_ID=xxxx --dart-define=SANITY_TOKEN=skxxxx

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
  *)
    print -u2 "Unknown command: $cmd"
    usage
    ;;
esac
