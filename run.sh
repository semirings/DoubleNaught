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
  print -u2 "  all [flutter run args...]  Free the BE port, start BE, wait for"
  print -u2 "                             /health, then run FE"
  exit 1
}

# The port the backend will bind, resolved the same way __main__.py resolves it
# so the two can never disagree.
BE_PORT="${DOUBLE_TOUCH_PORT:-8400}"

# Free a port by asking the OS what is actually bound to it.
#
# Deliberately lsof-based rather than pidfile-based: a pidfile records what was
# *intended* to be running and silently lies the moment that process is killed
# hard, crashes, or is orphaned to init when its launching shell dies. SegForge
# lost most of a working day to exactly that — a stale .sfbe.pid naming a dead
# pid, while the real, orphaned uvicorn kept the port and served two-day-old
# code through every "restart". The kernel's view of who holds the port cannot
# drift in that way.
free_port() {
  local port="$1"
  # `|| true` throughout: lsof exits non-zero when nothing matches, which is the
  # ordinary "port was already free" case and must not trip `set -e`.
  local pids
  pids=$(lsof -ti:"$port" 2>/dev/null || true)
  if [[ -n "$pids" ]]; then
    print "Freeing port $port (pids: ${pids//$'\n'/ })"
    print "$pids" | xargs kill 2>/dev/null || true
    # Give them a moment to release the socket before rebinding.
    local waited=0
    while [[ $waited -lt 50 ]] && lsof -ti:"$port" >/dev/null 2>&1; do
      sleep 0.1
      (( waited += 1 ))
    done
    # Anything still holding the port after 5s ignored SIGTERM.
    pids=$(lsof -ti:"$port" 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
      print "Port $port still held; sending SIGKILL"
      print "$pids" | xargs kill -9 2>/dev/null || true
      sleep 0.5
    fi
  fi
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
  all)
    # One-command launch: BE in the background, then FE in the foreground once
    # the backend actually answers. Purely additive — FE and BE above are
    # untouched and still work exactly as before.
    if [[ ! -x "$ROOT/backend/.venv/bin/python" ]]; then
      print -u2 "backend/.venv not found. Create it with:"
      print -u2 "  python3 -m venv backend/.venv"
      print -u2 "  backend/.venv/bin/pip install -e 'backend[dev]'"
      exit 1
    fi

    free_port "$BE_PORT"

    print "Starting backend on http://127.0.0.1:$BE_PORT"
    (
      cd "$ROOT/backend"
      exec .venv/bin/python -m double_touch
    ) &
    be_pid=$!
    # Kill the backend if this script exits before FE takes over (failed health
    # check, Ctrl-C during startup) so `all` can never strand a backend the way
    # an orphaned process strands a port.
    trap 'kill $be_pid 2>/dev/null || true' EXIT INT TERM

    # The backend's own /health endpoint (double_touch/app.py) — not a new
    # readiness notion invented here.
    print -n "Waiting for /health"
    healthy=0
    for _ in {1..120}; do
      if ! kill -0 $be_pid 2>/dev/null; then
        print ""
        print -u2 "Backend exited during startup."
        wait $be_pid || true
        exit 1
      fi
      if curl -fsS -m 2 "http://127.0.0.1:$BE_PORT/health" >/dev/null 2>&1; then
        healthy=1
        break
      fi
      print -n "."
      sleep 0.5
    done
    print ""
    if [[ $healthy -ne 1 ]]; then
      print -u2 "Backend did not become healthy within 60s."
      exit 1
    fi
    print "Backend healthy."

    # FE runs in the foreground and owns the terminal from here. Hand the
    # backend off: it should outlive this script's EXIT trap, and quitting the
    # app should not leave it running either, so stop it when FE returns.
    trap - EXIT INT TERM
    trap 'kill $be_pid 2>/dev/null || true' EXIT INT TERM
    cd "$ROOT/frontend"
    flutter run -d macos --dart-define=DN_STORAGE_DIR="$ROOT/storage" "$@"
    ;;
  *)
    print -u2 "Unknown command: $cmd"
    usage
    ;;
esac
