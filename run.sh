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
  print -u2 ""
  print -u2 "  up [--cold] [--no-sf] [--no-fe] [flutter run args...]"
  print -u2 "                             Start both backends as launchd user"
  print -u2 "                             agents, then run the DN frontend in the"
  print -u2 "                             foreground (--no-fe starts backends only)"
  print -u2 "  dn                         Stop both BACKENDS, never the app"
  print -u2 "                             (alias: down)"
  print -u2 "  status                     Per-service loaded/pid/port/health report"
  print -u2 "  logs [dn|sf]               tail -F the service logs (default: both)"
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

# ─────────────────────────────────────────────────────────────────────────────
# launchd-managed backends (up / dn / status / logs)
#
# Everything above this line is untouched: FE, BE and all still work exactly as
# before, and `free_port` is still theirs. This block adds a second, parallel
# way to run the two BACKENDS — as launchd user agents, so they survive the
# terminal that started them and are stoppable by name rather than by hunting
# pids.
#
# Why launchd and not `BE &`: an orphaned backend outliving its shell is the
# specific failure that cost SegForge most of a working day — a Sept-30 uvicorn
# held 8401 and served two-day-old code through every "restart". launchd gives
# the pair a name and a supervisor, and `status` can now say out loud when a
# port is held by something launchd does NOT manage.
#
# User domain only (gui/$uid): these are developer services that want the
# user's keychain, HOME and Julia depot. Nothing here needs or asks for root.
# ─────────────────────────────────────────────────────────────────────────────

# Both repos live side by side; derive SegForge from this script's own location
# so nothing here hardcodes a user name. (The Seg Forge NODE WIDGET does
# hardcode /Users/gcr — see the report; deliberately not changed.)
SF_ROOT="${ROOT:h}/SegForge"
SF_PORT="${SEGFORGE_PORT:-8401}"

LOG_DIR="$ROOT/logs"
AGENT_DIR="$HOME/Library/LaunchAgents"
LAUNCH_DOMAIN="gui/$(id -u)"

DN_LABEL="com.populi.dn-backend"
SF_LABEL="com.populi.sf-backend"

# Readiness budget, set from measurement on this machine rather than guessed:
#
#   SF  `up --cold`  10.5s   (first run, replacing a 4-day-old process)
#       `up --cold`  10.1s   (repeat)
#       kickstart -k  4.9s   (warm, x4 runs, no spread)
#   DN  cold          5.0s / 4.4s / 4.6s
#
# Both are far under these limits on purpose. The measured numbers all had a
# warm page cache for SAM3's weights; a genuinely cold read of them (fresh
# boot, or after heavy memory pressure) is the case the headroom is for, and
# the asymmetry in cost is what settles the size: an over-generous timeout only
# makes a BROKEN start take longer to report, while a tight one fails a healthy
# cold boot and sends you chasing a non-problem.
HEALTH_TIMEOUT_SF=180
HEALTH_TIMEOUT_DN=60

zmodload zsh/datetime 2>/dev/null || true

# ── service table ────────────────────────────────────────────────────────────
# Four tiny accessors instead of parallel arrays, so adding a third service is
# one arm in each.

svc_label() { [[ "$1" == dn ]] && print -r -- "$DN_LABEL" || print -r -- "$SF_LABEL" }
svc_port()  { [[ "$1" == dn ]] && print -r -- "$BE_PORT"  || print -r -- "$SF_PORT" }
svc_name()  { [[ "$1" == dn ]] && print -r -- "DoubleNaught" || print -r -- "SegForge" }
svc_log()   { print -r -- "$LOG_DIR/$1-backend.log" }
svc_timeout() { [[ "$1" == dn ]] && print -r -- "$HEALTH_TIMEOUT_DN" || print -r -- "$HEALTH_TIMEOUT_SF" }

# WorkingDirectory: exactly what each service is launched from today.
#   DN  — `BE` does `cd "$ROOT/backend"` before `python -m double_touch`.
#   SF  — SF's own run.sh does `cd "$BACKEND_DIR"` before uvicorn, and
#         `main:app` is only importable from there.
svc_dir() {
  [[ "$1" == dn ]] && print -r -- "$ROOT/backend" || print -r -- "$SF_ROOT/backend"
}

# Program + args, by absolute path. Note SF's venv is at its PROJECT root, not
# under backend/, and that `--reload` is deliberately absent: a reloader under
# launchd would fork children launchd does not know about, and the staleness
# check in SF's own /health is what covers "serving old code" instead.
svc_args() {
  case "$1" in
    dn) SVC_ARGS=("$ROOT/backend/.venv/bin/python" -m double_touch) ;;
    sf) SVC_ARGS=("$SF_ROOT/.venv/bin/uvicorn" main:app
                  --host 127.0.0.1 --port "$SF_PORT") ;;
  esac
}

# The PATH to bake, minus any `*/.venv/bin` entry.
#
# launchd hands an agent a bare PATH (/usr/bin:/bin:/usr/sbin:/sbin), which has
# no ~/.juliaup/bin — and that is the ONLY way `julia` is reachable on this
# machine, so juliacall (D4M.jl, both backends' persistence layer) would fail to
# find it. Baking the invoking shell's PATH fixes that.
#
# The .venv filter is a deliberate deviation from "bake it verbatim": whichever
# venv happens to be active in the shell that ran `up` is an accident of that
# shell, and leaving it first on PATH would make a bare `python` inside EITHER
# service resolve to the OTHER project's interpreter. Each service already names
# its own interpreter absolutely, so dropping these entries loses nothing.
baked_path() {
  local -a parts keep
  local p
  parts=("${(@s/:/)PATH}")
  for p in $parts; do
    [[ "$p" == */.venv/bin ]] && continue
    keep+=("$p")
  done
  print -r -- "${(j/:/)keep}"
}

# Environment to bake, per service. Kept as small as it can be, because every
# variable here is one that stops being the shell's business and starts being
# this script's to keep current.
#
# Both:  PATH (above) and HOME. HOME is what makes ~/.julia, ~/.juliaup and
#        ~/.cache/huggingface resolve; launchd does set it for user agents, but
#        baking it keeps the plist self-describing.
# DN:    the three Julia vars its run.sh exports at the top. JULIA_PROJECT is
#        `$(pwd)` there, which is the repo root in normal use — and that is
#        where DN's Project.toml/Manifest.toml actually live, so "$ROOT" is
#        both faithful and no longer dependent on where you stood.
# SF:    nothing extra. SF's run.sh exports no Julia vars at all, so it relies
#        on juliacall's own discovery via PATH; mirroring that exactly.
#
# NOT baked, on purpose — each backend already loads these itself, so baking
# them would create a second, silently diverging copy of a secret:
#   DN  __main__.py load_dotenv(~/.gemini/.env) then ./.env  (GEMINI_API_KEY)
#   SF  main.py load_dotenv() walks up from backend/ to SegForge/.env
#       (CHATGPT_API_KEY, HUGGING_FACE_HUB_TOKEN, GEMINI_API_KEY)
svc_env() {
  local bp; bp="$(baked_path)"
  case "$1" in
    dn) SVC_ENV=(
          PATH "$bp"
          HOME "$HOME"
          PYTHON_JULIACALL_EXE "${JULIA_EXE:-}"
          JULIA_PROJECT "$ROOT"
          PYTHON_JULIACALL_PROJECT "$ROOT"
        ) ;;
    sf) SVC_ENV=(
          PATH "$bp"
          HOME "$HOME"
        ) ;;
  esac
}

# ── plist generation ─────────────────────────────────────────────────────────

# Minimal XML escaping. Paths here come from this script's location and from
# PATH, neither of which is guaranteed free of `&`.
xml_esc() {
  local s="$1"
  s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"
  print -r -- "$s"
}

# Write the plist fresh on every `up`, so it can never describe a path or an
# environment that has since moved. The file is an artifact of this script, not
# something to hand-edit.
write_plist() {
  local svc="$1"
  local label plist
  label="$(svc_label "$svc")"
  plist="$AGENT_DIR/$label.plist"

  svc_args "$svc"
  svc_env "$svc"

  mkdir -p "$AGENT_DIR" "$LOG_DIR"

  {
    print -r -- '<?xml version="1.0" encoding="UTF-8"?>'
    print -r -- '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    print -r -- '<plist version="1.0">'
    print -r -- '<dict>'
    print -r -- "  <key>Label</key><string>$(xml_esc "$label")</string>"
    print -r -- '  <key>ProgramArguments</key>'
    print -r -- '  <array>'
    local a
    for a in "${SVC_ARGS[@]}"; do
      print -r -- "    <string>$(xml_esc "$a")</string>"
    done
    print -r -- '  </array>'
    print -r -- "  <key>WorkingDirectory</key><string>$(xml_esc "$(svc_dir "$svc")")</string>"
    print -r -- '  <key>EnvironmentVariables</key>'
    print -r -- '  <dict>'
    local i=1
    while (( i < ${#SVC_ENV[@]} )); do
      print -r -- "    <key>$(xml_esc "${SVC_ENV[$i]}")</key><string>$(xml_esc "${SVC_ENV[$((i+1))]}")</string>"
      (( i += 2 ))
    done
    print -r -- '  </dict>'
    print -r -- '  <key>RunAtLoad</key><true/>'
    # KeepAlive false on purpose: a backend that dies should STAY dead and be
    # visible in `status`, not be resurrected into a loop that hides the crash.
    print -r -- '  <key>KeepAlive</key><false/>'
    print -r -- "  <key>StandardOutPath</key><string>$(xml_esc "$(svc_log "$svc")")</string>"
    print -r -- "  <key>StandardErrorPath</key><string>$(xml_esc "$(svc_log "$svc")")</string>"
    print -r -- '  <key>ProcessType</key><string>Interactive</string>'
    print -r -- '</dict>'
    print -r -- '</plist>'
  } > "$plist"

  print -r -- "$plist"
}

# ── launchd + health probes ──────────────────────────────────────────────────

svc_loaded() {
  launchctl print "$LAUNCH_DOMAIN/$(svc_label "$1")" >/dev/null 2>&1
}

# The pid launchd believes it is supervising, or empty when it has none (a
# loaded-but-exited service prints no pid line).
svc_pid() {
  launchctl print "$LAUNCH_DOMAIN/$(svc_label "$1")" 2>/dev/null \
    | awk '/^[[:space:]]*pid = /{print $3; exit}' || true
}

port_pids() { lsof -ti:"$1" 2>/dev/null || true }

svc_health_body() {
  curl -fsS -m 3 "http://127.0.0.1:$(svc_port "$1")/health" 2>/dev/null || true
}

# Ready in the sense the caller actually needs:
#   DN  — answers /health at all.
#   SF  — answers, has its model loaded (/upload 503s until then), and is NOT
#         stale. Staleness is part of readiness here precisely because a stale
#         backend answers a liveness probe exactly like a current one.
svc_healthy() {
  local body; body="$(svc_health_body "$1")"
  [[ -z "$body" ]] && return 1
  if [[ "$1" == sf ]]; then
    print -r -- "$body" | grep -q '"model_loaded"[[:space:]]*:[[:space:]]*true' || return 1
    print -r -- "$body" | grep -q '"stale"[[:space:]]*:[[:space:]]*false'       || return 1
  fi
  return 0
}

now_s() { print -r -- "${EPOCHREALTIME:-$(date +%s)}" }

elapsed_s() {
  local t0="$1" t1
  t1="$(now_s)"
  printf '%.1f' "$(( t1 - t0 ))" 2>/dev/null || print -r -- '?'
}

# Poll until ready, and never claim success without one passing check.
wait_healthy() {
  local svc="$1" timeout; timeout="$(svc_timeout "$svc")"
  local t0; t0="$(now_s)"
  local deadline=$(( timeout * 10 ))
  local n=0
  print -n "  waiting for /health"
  while (( n < deadline )); do
    if svc_healthy "$svc"; then
      print " ok (${$(elapsed_s "$t0")}s)"
      return 0
    fi
    (( n % 10 == 0 )) && print -n "."
    sleep 0.1
    (( n += 1 ))
  done
  print " TIMEOUT after ${$(elapsed_s "$t0")}s"
  return 1
}

# Kill whatever holds a port, naming it first.
#
# lsof-based, not pidfile-based, for the same reason `free_port` above is: a
# pidfile records intent and lies the moment its process is killed hard or
# orphaned. This is also what catches backends started before launchd was in
# the picture at all.
sweep_port() {
  local port="$1" pids pid
  pids="$(port_pids "$port")"
  [[ -z "$pids" ]] && return 0
  for pid in ${(f)pids}; do
    print -r -- "  freeing port $port — pid $pid: $(ps -o command= -p "$pid" 2>/dev/null | cut -c1-110)"
  done
  print -r -- "$pids" | xargs kill 2>/dev/null || true
  local waited=0
  while (( waited < 50 )) && [[ -n "$(port_pids "$port")" ]]; do
    sleep 0.1; (( waited += 1 ))
  done
  pids="$(port_pids "$port")"
  if [[ -n "$pids" ]]; then
    print -r -- "  port $port ignored SIGTERM; sending SIGKILL"
    print -r -- "$pids" | xargs kill -9 2>/dev/null || true
    sleep 0.5
  fi
}

svc_bootout() {
  launchctl bootout "$LAUNCH_DOMAIN/$(svc_label "$1")" >/dev/null 2>&1 || true
}

# Print the tail of a service log, for a failure the caller is about to report.
log_tail() {
  local f; f="$(svc_log "$1")"
  if [[ -s "$f" ]]; then
    print -u2 ""
    print -u2 "── last 30 lines of $f ──"
    tail -n 30 "$f" >&2 || true
  else
    print -u2 "(no log output at $(svc_log "$1"))"
  fi
}

# ── up ──────────────────────────────────────────────────────────────────────

svc_up() {
  local svc="$1" cold="$2"
  local label; label="$(svc_label "$svc")"
  local port; port="$(svc_port "$svc")"
  local plist

  print ""
  print -r -- "── $(svc_name "$svc") backend — $label (port $port)"

  plist="$(write_plist "$svc")"
  print -r -- "  plist: $plist"

  if [[ "$cold" == 1 ]]; then
    print -r -- "  cold: booting out and sweeping the port"
    svc_bootout "$svc"
    sweep_port "$port"
    launchctl bootstrap "$LAUNCH_DOMAIN" "$plist" 2>&1 | sed 's/^/  launchctl: /' || true
  elif svc_loaded "$svc"; then
    if svc_healthy "$svc"; then
      print -r -- "  already loaded and healthy (pid ${$(svc_pid "$svc"):-none}) — leaving it"
      return 0
    fi
    # Loaded but not ready: stale code, or dead, or still starting. kickstart -k
    # restarts in place and keeps launchd's supervision, which is the whole
    # reason to prefer it over bootout+bootstrap here.
    print -r -- "  loaded but not healthy (pid ${$(svc_pid "$svc"):-none}) — kickstart -k"
    launchctl kickstart -k "$LAUNCH_DOMAIN/$label" 2>&1 | sed 's/^/  launchctl: /' || true
  else
    # Not loaded. Free the port FIRST: anything holding it now is by definition
    # outside launchd, and bootstrap would otherwise start a service that dies
    # on bind with a confusing "address already in use" in its log.
    sweep_port "$port"
    launchctl bootstrap "$LAUNCH_DOMAIN" "$plist" 2>&1 | sed 's/^/  launchctl: /' || true
  fi

  if ! svc_loaded "$svc"; then
    print -u2 "  FAILED: $label did not load."
    log_tail "$svc"
    return 1
  fi

  if ! wait_healthy "$svc"; then
    print -u2 "  FAILED: $(svc_name "$svc") did not become healthy."
    if [[ "$svc" == sf ]]; then
      local body; body="$(svc_health_body sf)"
      [[ -n "$body" ]] && print -u2 "  last /health: $body"
    fi
    log_tail "$svc"
    return 1
  fi

  print -r -- "  pid $(svc_pid "$svc") — ready"
  return 0
}

cmd_up() {
  local cold=0 want_sf=1 want_fe=1 a
  # Anything not a recognised flag is passed through to `flutter run`, the same
  # way `all [flutter run args...]` does. Flutter rejects what it does not know,
  # so a mistyped flag still surfaces rather than being swallowed.
  local -a fe_args; fe_args=()
  for a in "$@"; do
    case "$a" in
      --cold)  cold=1 ;;
      --no-sf) want_sf=0 ;;
      --no-fe) want_fe=0 ;;
      *) fe_args+=("$a") ;;
    esac
  done
  if (( ! want_fe )) && (( ${#fe_args[@]} )); then
    print -u2 "up: --no-fe given, ignoring frontend args: ${fe_args[*]}"
  fi

  # Resolved once, the same way DN's run.sh resolves it at the top.
  JULIA_EXE="$(command -v julia 2>/dev/null || true)"
  if [[ -z "$JULIA_EXE" ]]; then
    print -u2 "Warning: no julia on PATH; DN's PYTHON_JULIACALL_EXE will be empty."
  fi

  if [[ ! -x "$ROOT/backend/.venv/bin/python" ]]; then
    print -u2 "backend/.venv not found. Create it with:"
    print -u2 "  python3 -m venv backend/.venv"
    print -u2 "  backend/.venv/bin/pip install -e 'backend[dev]'"
    exit 1
  fi
  if (( want_sf )) && [[ ! -x "$SF_ROOT/.venv/bin/uvicorn" ]]; then
    print -u2 "SegForge venv not found at $SF_ROOT/.venv — run up --no-sf, or create it."
    exit 1
  fi

  local -a services; services=(dn)
  (( want_sf )) && services+=(sf)

  local rc=0 svc
  for svc in $services; do
    svc_up "$svc" "$cold" || rc=1
  done

  print ""
  if (( rc )); then
    print -u2 "up: at least one service is not healthy (see above)."
    exit 1
  fi
  print "up: all services healthy."

  (( want_fe )) || return 0

  # ── frontend, in the foreground ───────────────────────────────────────────
  #
  # Same invocation as `all` and `FE`: flutter run -d macos from frontend/,
  # with DN_STORAGE_DIR pointed at the repo's storage/. Foreground on purpose,
  # so the terminal stays attached to Flutter's output and hot reload works.
  #
  # NO TRAP, and that is the whole difference from `all`. `all` owns the
  # backend it started as a child, so it traps EXIT/INT/TERM to kill it and
  # avoid stranding one. Here launchd owns the backends: quitting the app or
  # pressing Ctrl-C must end the frontend and NOTHING else, so there is
  # deliberately nothing to tear down here. Use `./run.sh dn` to stop them.
  #
  # Only DN's frontend. SegForge's is opened on demand by DN's Seg Forge node
  # (which spawns it against the backend already running on 8401); SF's own
  # `run.sh FE` remains for standalone use.
  if ! command -v flutter >/dev/null 2>&1; then
    print -u2 ""
    print -u2 "up: flutter not found on PATH — cannot start the frontend."
    print -u2 "up: the backends are up and staying up (./run.sh dn to stop them)."
    exit 1
  fi

  print ""
  print "Starting DN frontend (backends stay up under launchd; Ctrl-C or quit ends only the app)."
  cd "$ROOT/frontend"
  local fe_rc=0
  flutter run -d macos --dart-define=DN_STORAGE_DIR="$ROOT/storage" "${fe_args[@]}" \
    || fe_rc=$?

  # 0 is a clean quit; 130 is Ctrl-C, which is a normal way to end a foreground
  # `flutter run` and not a failure to report as one.
  if (( fe_rc != 0 && fe_rc != 130 )); then
    print -u2 ""
    print -u2 "up: frontend exited non-zero ($fe_rc) — see Flutter's output above."
    print -u2 "up: the backends are up and staying up (./run.sh dn to stop them)."
    exit "$fe_rc"
  fi
  return 0
}

# ── dn (stop) ───────────────────────────────────────────────────────────────

cmd_down() {
  local -a stopped
  # Declared once, outside the loops: a second `local x` on an already-set
  # local makes zsh echo `x=<value>` into the output.
  local svc label pid port pids pid2 waited rc s

  # bootout first so launchd stops trying to own these, and so it cannot race
  # the signals below by restarting anything.
  for svc in dn sf; do
    label="$(svc_label "$svc")"
    if svc_loaded "$svc"; then
      pid="$(svc_pid "$svc")"
      svc_bootout "$svc"
      stopped+=("$label (was pid ${pid:-none})")
    else
      print -r -- "$label: not loaded"
    fi
  done

  # Then the ports, for anything launchd never owned — a pre-launchd orphan, or
  # a backend the Seg Forge node widget spawned detached (it does; see report).
  #
  # BACKENDS ONLY. Flutter apps are never touched, by construction: the only
  # things considered here are the two labels above and whatever holds 8400 or
  # 8401. A running DN or SegForge frontend binds neither, so `dn` leaves a
  # foregrounded `up` frontend alive and talking to backends that are gone —
  # which is the intended split, not an oversight.
  for port in "$BE_PORT" "$SF_PORT"; do
    pids="$(port_pids "$port")"
    [[ -z "$pids" ]] && continue
    for pid in ${(f)pids}; do
      print -r -- "port $port still held by pid $pid: $(ps -o command= -p "$pid" 2>/dev/null | cut -c1-110)"
      stopped+=("pid $pid on port $port")
    done
    print -r -- "$pids" | xargs kill 2>/dev/null || true
  done

  # One 5s grace for every TERM above, then SIGKILL the holdouts.
  waited=0
  while (( waited < 50 )); do
    [[ -z "$(port_pids "$BE_PORT")$(port_pids "$SF_PORT")" ]] && break
    sleep 0.1; (( waited += 1 ))
  done
  for port in "$BE_PORT" "$SF_PORT"; do
    pids="$(port_pids "$port")"
    if [[ -n "$pids" ]]; then
      print -r -- "port $port ignored SIGTERM; sending SIGKILL to ${pids//$'\n'/ }"
      print -r -- "$pids" | xargs kill -9 2>/dev/null || true
    fi
  done
  sleep 0.5

  print ""
  if (( ${#stopped[@]} )); then
    print "Stopped:"
    for s in "${stopped[@]}"; do print -r -- "  $s"; done
  else
    print "Nothing was running."
  fi

  # Verify, rather than assume, that the ports are actually free.
  rc=0
  for port in "$BE_PORT" "$SF_PORT"; do
    pids="$(port_pids "$port")"
    if [[ -n "$pids" ]]; then
      print -u2 "port $port is STILL held by ${pids//$'\n'/ }"
      rc=1
    else
      print -r -- "port $port: free"
    fi
  done
  (( rc )) && exit 1
  return 0
}

# ── status ──────────────────────────────────────────────────────────────────

cmd_status() {
  # Every local is declared ONCE, here, rather than inside the loop: re-running
  # `local x` on an already-set local in the same function scope makes zsh echo
  # `x=<value>` into the report.
  local svc label port pid holders body h tag stale ml
  for svc in dn sf; do
    label="$(svc_label "$svc")"
    port="$(svc_port "$svc")"
    print ""
    print -r -- "── $(svc_name "$svc") backend — $label (port $port)"

    if svc_loaded "$svc"; then
      pid="$(svc_pid "$svc")"
      print -r -- "  launchd: loaded, pid ${pid:-none (loaded but not running)}"
    else
      pid=""
      print -r -- "  launchd: not loaded"
    fi

    holders="$(port_pids "$port")"
    if [[ -z "$holders" ]]; then
      print -r -- "  port:    free"
    else
      for h in ${(f)holders}; do
        tag=""
        # An orphan is a process holding the service's port that launchd is not
        # supervising — exactly the state that let a days-old backend keep
        # answering every restart attempt.
        if [[ -n "$pid" && "$h" == "$pid" ]]; then
          tag="launchd-managed"
        else
          tag="ORPHAN — not managed by launchd"
        fi
        print -r -- "  port:    pid $h [$tag]"
        print -r -- "           $(ps -o command= -p "$h" 2>/dev/null | cut -c1-96)"
      done
    fi

    body="$(svc_health_body "$svc")"
    if [[ -z "$body" ]]; then
      print -r -- "  health:  no answer"
    elif [[ "$svc" == sf ]]; then
      stale=$(print -r -- "$body" | grep -o '"stale"[^,}]*' | head -1)
      ml=$(print -r -- "$body" | grep -o '"model_loaded"[^,}]*' | head -1)
      print -r -- "  health:  ${ml:-model_loaded?}, ${stale:-stale?}"
      print -r -- "$body" | grep -q '"stale"[[:space:]]*:[[:space:]]*true' \
        && print -r -- "           STALE — serving code that has since changed; up will restart it"
    else
      print -r -- "  health:  $(print -r -- "$body" | cut -c1-96)"
    fi

    print -r -- "  log:     $(svc_log "$svc")"
  done
  print ""
}

# ── logs ────────────────────────────────────────────────────────────────────

cmd_logs() {
  local -a files
  case "${1:-both}" in
    dn) files=("$(svc_log dn)") ;;
    sf) files=("$(svc_log sf)") ;;
    both) files=("$(svc_log dn)" "$(svc_log sf)") ;;
    *) print -u2 "logs: expected dn, sf, or nothing"; exit 1 ;;
  esac
  mkdir -p "$LOG_DIR"
  local f; for f in "${files[@]}"; do [[ -e "$f" ]] || : > "$f"; done
  print -r -- "tail -F ${files[*]}"
  exec tail -F "${files[@]}"
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
  up)     cmd_up "$@" ;;
  dn|down) cmd_down ;;
  status) cmd_status ;;
  logs)   cmd_logs "$@" ;;
  *)
    print -u2 "Unknown command: $cmd"
    usage
    ;;
esac
