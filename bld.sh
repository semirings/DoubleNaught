#!/usr/bin/env zsh
# Clean and build DoubleNaught and SegForge, frontend and backend.
#
# Usage:
#   ./bld.sh [dn|sf|all] [--fe] [--be] [--no-clean] [--restart] [--dry-run]
#
#   dn | sf | all   which project (default: all)
#   --fe / --be     only the frontend / only the backend (default: both)
#   --no-clean      skip `flutter clean` and the __pycache__ sweep
#   --restart       after building, restart both backends (./run.sh dn, then
#                   ./run.sh up --no-fe). Without it, running backends keep
#                   serving the OLD code until you restart them yourself.
#   --dry-run       print what would run; change nothing
#
# What "build" means here
#   Frontend  flutter clean, pub get, then `flutter build macos --debug`.
#             Debug on purpose: DN's Seg Forge node launches
#             SegForge/frontend/build/macos/Build/Products/Debug/frontend.app,
#             and run.sh's `up` runs DN's own app out of its build tree. DN does
#             not build SF; if this isn't run, DN opens whatever SF app was last
#             built. (SegForge/bld.sh is the separate WEB build, served by SF's
#             backend at /web/; this script does not touch it.)
#   Backend   Python has nothing to compile, so: drop stale __pycache__ and
#             .pytest_cache, then `uv sync --inexact` so the venv matches
#             pyproject/uv.lock. --frozen: install EXACTLY what uv.lock says and
#             never rewrite it (a plain sync re-resolves and silently bumps
#             packages, e.g. polars 1->2, and dirties uv.lock). --inexact is deliberate: it installs what is
#             missing but does NOT remove packages that are in the venv and not
#             in pyproject — e.g. mlx-vlm[train], which the captioner needs and
#             which was pip-installed by hand.
#
# Never builds over a running app: a Flutter clean under a live app deletes the
# binary it is executing. Quit the app first (the script tells you).

set -e

# An activated venv (this shell may have one from either project) makes uv warn
# and can steer it at the wrong environment. Each project's own is used.
unset VIRTUAL_ENV

ROOT="${0:A:h}"
SF_ROOT="${ROOT:h}/SegForge"

WHICH=all
DO_FE=1; DO_BE=1; CLEAN=1; RESTART=0; DRY=0
EXPLICIT=0
for arg in "$@"; do
  case "$arg" in
    dn|sf|all) WHICH="$arg" ;;
    --fe) [[ $EXPLICIT == 0 ]] && { DO_FE=0; DO_BE=0; }; EXPLICIT=1; DO_FE=1 ;;
    --be) [[ $EXPLICIT == 0 ]] && { DO_FE=0; DO_BE=0; }; EXPLICIT=1; DO_BE=1 ;;
    --no-clean) CLEAN=0 ;;
    --restart) RESTART=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) print -u2 "bld: unknown argument '$arg' (try --help)"; exit 2 ;;
  esac
done

say() { print -r -- "==> $*"; }
run() {
  if (( DRY )); then print -r -- "    [dry-run] (cd ${PWD/#$HOME/~} && $*)"; else "$@"; fi
}

projects=()
[[ $WHICH == dn  || $WHICH == all ]] && projects+=(dn)
[[ $WHICH == sf  || $WHICH == all ]] && projects+=(sf)

root_of() { [[ "$1" == dn ]] && print -r -- "$ROOT" || print -r -- "$SF_ROOT"; }
name_of() { [[ "$1" == dn ]] && print -r -- "DoubleNaught" || print -r -- "SegForge"; }
# DN's venv/project lives under backend/; SF's at the project root.
be_dir_of() { [[ "$1" == dn ]] && print -r -- "$ROOT/backend" || print -r -- "$SF_ROOT"; }

# ── Preflight: fail before changing anything ─────────────────────────────────
for p in $projects; do
  [[ -d "$(root_of $p)" ]] || { print -u2 "bld: $(name_of $p) not found at $(root_of $p)"; exit 1; }
done
if (( DO_FE && ! DRY )); then
  command -v flutter >/dev/null 2>&1 || { print -u2 "bld: flutter not found on PATH"; exit 1; }
  for p in $projects; do
    # An app executing out of this build tree must not have its tree cleaned.
    if pgrep -f "$(root_of $p)/frontend/build/macos/.*[.]app/Contents/MacOS/" >/dev/null 2>&1; then
      print -u2 "bld: the $(name_of $p) app is running. Quit it, then run bld.sh again."
      exit 1
    fi
  done
fi
if (( DO_BE )); then
  command -v uv >/dev/null 2>&1 || (( DRY )) || { print -u2 "bld: uv not found on PATH"; exit 1; }
fi

failed=()

# ── Frontends ────────────────────────────────────────────────────────────────
if (( DO_FE )); then
  for p in $projects; do
    say "$(name_of $p) frontend"
    # Keep the last good app: a clean that is followed by a failed build would
    # otherwise leave NO app (DN's Open Forge launches this exact path).
    app_dir="$(root_of $p)/frontend/build/macos/Build/Products/Debug"
    bak="$HOME/.cache/bld-backup/$p"
    have_bak=0
    if (( ! DRY )) && [[ -n "$(print -rl -- $app_dir/*.app(N))" ]]; then
      rm -rf "$bak"; mkdir -p "$bak"; cp -R $app_dir/*.app "$bak/" && have_bak=1
    fi
    (
      cd "$(root_of $p)/frontend"
      if (( CLEAN )); then run flutter clean || exit 1; fi
      run flutter pub get || exit 1
      run flutter build macos --debug || exit 1
    ) || {
      failed+=("$(name_of $p) frontend")
      if (( have_bak )); then
        mkdir -p "$app_dir"; rm -rf $app_dir/*.app; cp -R "$bak"/*.app "$app_dir/" \
          && print -u2 "bld: build failed; restored the previous $(name_of $p) app."
      fi
    }
  done
fi

# ── Backends ─────────────────────────────────────────────────────────────────
if (( DO_BE )); then
  for p in $projects; do
    say "$(name_of $p) backend"
    (
      cd "$(be_dir_of $p)"
      if (( CLEAN )); then
        if (( DRY )); then
          print -r -- "    [dry-run] remove __pycache__ and .pytest_cache under ${PWD/#$HOME/~}"
        else
          find . \( -path ./.venv -o -path ./node_modules \) -prune -o \
            \( -name __pycache__ -o -name .pytest_cache \) -type d -exec rm -rf {} + 2>/dev/null || true
        fi
      fi
      run uv sync --inexact --frozen || exit 1
    ) || failed+=("$(name_of $p) backend")
  done
fi

# ── Result ───────────────────────────────────────────────────────────────────
if (( ${#failed} )); then
  print -u2 ""
  print -u2 "bld: FAILED: ${(j:, :)failed}"
  exit 1
fi

if (( RESTART && DO_BE )); then
  say "restarting backends"
  run "$ROOT/run.sh" dn
  run "$ROOT/run.sh" up --no-fe
elif (( DO_BE )); then
  print ""
  print "Backends were NOT restarted; running ones still serve the old code."
  print "Restart with: ./bld.sh --restart   (or ./run.sh dn && ./run.sh up --no-fe)"
fi
say "done"
