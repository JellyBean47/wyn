#!/usr/bin/env bash
# Capture Instruments traces against pure-Fly Satisfactory (combo B).
#
# Goal: attribute in-world freezes where Metal HUD Frame Interval ≫ GPU.
#
# Usage:
#   Tools/instruments-fly-hitch.sh --launch          # kill others, start fly play
#   Tools/instruments-fly-hitch.sh --wait             # wait for Shipping PID
#   Tools/instruments-fly-hitch.sh --watch [mins]     # launch + auto-record for N mins (default 7)
#   Tools/instruments-fly-hitch.sh --record [secs]    # attach Metal System Trace (default 20s)
#   Tools/instruments-fly-hitch.sh --record-cpu [secs]# attach Time Profiler
#   Tools/instruments-fly-hitch.sh --record-hitches [secs]  # Animation Hitches
#   Tools/instruments-fly-hitch.sh --open PATH.trace  # open in Instruments.app
#   Tools/instruments-fly-hitch.sh --kill-all
#
# Owner flow (manual):
#   1) --launch → get in-world → --record 20
#
# Owner flow (hands-off):
#   Tools/instruments-fly-hitch.sh --watch 10
#   Just play into the world; script waits through load screens then auto-captures.
#   Default templates: Time Profiler + Animation Hitches.
#   Metal System Trace: on when traces go to SSD (or force with WATCH_USE_METAL=1).
#   Traces default to /Volumes/SSD1TB/Fly-instruments/ when that volume is mounted
#   (internal disk filled up previously — override with FLY_TRACE_DIR).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -z "${FLY_TRACE_DIR:-}" ]]; then
  if [[ -d /Volumes/SSD1TB ]]; then
    FLY_TRACE_DIR="/Volumes/SSD1TB/Fly-instruments"
  else
    FLY_TRACE_DIR="$HOME/Library/Logs/com.fly.gaming/instruments"
  fi
fi
OUT_DIR="$FLY_TRACE_DIR"
FLY_BIN="${FLY_BIN:-$ROOT/.build/release/wyn}"
PROFILE="${FLY_PROFILE:-satisfactory}"
SHIPPING_RE='FactoryGameSteam-Win64-Shipping'
BOTTLE="${FLY_BOTTLE:-$HOME/Library/Containers/com.fly.gaming/Bottles/32050D6B-F756-491C-8CBF-8C4CAC1B5ECF}"
GAME_LOG="$BOTTLE/drive_c/users/crossover/AppData/Local/FactoryGame/Saved/Logs/FactoryGame.log"
WATCH_LOG="${WATCH_LOG:-$OUT_DIR/watch.log}"

METAL_TEMPLATE="Metal System Trace"
CPU_TEMPLATE="Time Profiler"
HITCH_TEMPLATE="Animation Hitches"

mkdir -p "$OUT_DIR"

shipping_pid() {
  pgrep -f "$SHIPPING_RE" | head -1 || true
}

cmd_kill_all() {
  if [[ -x "$ROOT/Tools/wine-host-ab.sh" ]]; then
    "$ROOT/Tools/wine-host-ab.sh" --kill-all || true
  fi
  # Belt-and-suspenders for leftover shipping
  pkill -f "$SHIPPING_RE" 2>/dev/null || true
  pkill -f 'FactoryGameSteam.exe' 2>/dev/null || true
  echo "Killed game-host wine + Shipping (best effort)."
}

cmd_launch() {
  if [[ ! -x "$FLY_BIN" ]]; then
    echo "Missing $FLY_BIN — build first: cd $ROOT && swift build -c release" >&2
    exit 1
  fi
  cmd_kill_all
  sleep 1
  local debug_args=()
  if [[ "${FLY_PLAY_DEBUG:-0}" == "1" ]]; then
    debug_args=(--debug)
  fi
  local launch_log="${LAUNCH_LOG:-$OUT_DIR/launch.log}"
  if ((${#debug_args[@]})); then
    echo "Launching: $FLY_BIN play $PROFILE --debug"
  else
    echo "Launching: $FLY_BIN play $PROFILE (no --debug)"
  fi
  echo "Log: $launch_log"
  nohup "$FLY_BIN" play "$PROFILE" ${debug_args[@]+"${debug_args[@]}"} >"$launch_log" 2>&1 &
  echo "fly launcher pid $!"
  cmd_wait
}

cmd_wait() {
  echo "Waiting for $SHIPPING_RE …"
  for i in $(seq 1 120); do
    pid="$(shipping_pid)"
    if [[ -n "$pid" ]]; then
      echo "SHIPPING_PID=$pid (${i}s)"
      ps -p "$pid" -o pid=,etime=,command= | head -c 400; echo
      echo "Get in-world, confirm Metal HUD FI ≫ GPU freezes, then:"
      echo "  Tools/instruments-fly-hitch.sh --record 20"
      return 0
    fi
    sleep 1
  done
  echo "Shipping never appeared. Tail launch log:" >&2
  tail -40 /tmp/fly-instruments-launch.log 2>/dev/null || true
  exit 1
}

need_shipping() {
  pid="$(shipping_pid)"
  if [[ -z "$pid" ]]; then
    echo "No $SHIPPING_RE process. Run --launch / --wait first." >&2
    exit 1
  fi
  echo "$pid"
}

stamp() { date +%Y%m%d-%H%M%S; }

cmd_record() {
  local secs="${1:-20}"
  local template="${2:-$METAL_TEMPLATE}"
  local tag="${3:-metal}"
  local pid
  pid="$(need_shipping)"
  local out="$OUT_DIR/fly-${tag}-$(stamp).trace"
  echo "Recording '$template' on pid $pid for ${secs}s → $out"
  echo "Play through freezes now…"
  # Needs full Instruments packages (Xcode.app); skip prompts.
  xcrun xctrace record \
    --template "$template" \
    --attach "$pid" \
    --time-limit "${secs}s" \
    --output "$out" \
    --no-prompt
  echo "DONE: $out"
  echo "Open: Tools/instruments-fly-hitch.sh --open \"$out\""
  ls -lh "$out"
}

cmd_open() {
  local path="${1:-}"
  if [[ -z "$path" || ! -e "$path" ]]; then
    echo "Usage: --open /path/to/file.trace" >&2
    echo "Recent:" >&2
    ls -lt "$OUT_DIR"/*.trace 2>/dev/null | head -8 || echo "(none yet)" >&2
    exit 1
  fi
  open -a Instruments "$path"
}

log_suggests_in_world() {
  # Strict heuristics — avoid menu/boot false positives (bare "LoadMap" / World_Data).
  [[ -f "$GAME_LOG" ]] || return 1
  local baseline="${1:-0}"
  local size
  size=$(wc -c <"$GAME_LOG" | tr -d ' ')
  (( size > baseline )) || return 1
  local chunk=$(( size - baseline ))
  (( chunk > 0 )) || return 1
  # Cap read so we don't scan huge logs
  (( chunk > 2000000 )) && chunk=2000000
  tail -c "$chunk" "$GAME_LOG" 2>/dev/null \
    | rg -qi 'Persistent_Level|Took .* seconds to LoadMap|Bringing World up for play|LogWorld: Display: Bringing|Game Thread Hitch|Hitch detected' \
    && return 0
  return 1
}

cmd_watch() {
  local mins="${1:-10}"
  local watch_secs=$(( mins * 60 ))
  local cpu_secs="${WATCH_CPU_SECS:-25}"
  local hitch_secs="${WATCH_HITCH_SECS:-25}"
  # Do not fire on log signals before this (menu LoadMap alone can be ~52s+).
  local min_log_after="${WATCH_MIN_LOG_AFTER:-240}"
  # Fallback first capture — after load screens (default 5 min).
  local fallback_after="${WATCH_FALLBACK_AFTER:-300}"
  # Second capture window (default 7 min).
  local second_after="${WATCH_SECOND_AFTER:-420}"
  local use_metal="${WATCH_USE_METAL:-}"
  # Default Metal ON when writing to the big SSD; OFF on internal (disk-fill risk).
  if [[ -z "$use_metal" ]]; then
    if [[ "$OUT_DIR" == /Volumes/SSD1TB/* ]]; then
      use_metal=1
    else
      use_metal=0
    fi
  fi

  : >"$WATCH_LOG"
  exec > >(tee -a "$WATCH_LOG") 2>&1

  echo "======== AUTO-WATCH ${mins}m ========"
  echo "Take your time through menus/loading — no need to say go."
  echo "Captures: Time Profiler ${cpu_secs}s + Animation Hitches ${hitch_secs}s"
  echo "  first @ log(in-world, after +${min_log_after}s) OR fallback +${fallback_after}s"
  echo "  second @ +${second_after}s"
  if [[ "$use_metal" == "1" ]]; then
    echo "  Metal System Trace ON (${WATCH_METAL_SECS:-25}s) — output on large volume"
  else
    echo "  Metal System Trace OFF (set WATCH_USE_METAL=1 or use SSD path to enable)"
  fi
  echo "Watch log: $WATCH_LOG"
  echo "Traces: $OUT_DIR"
  local avail_mb
  avail_mb=$(df -m "$OUT_DIR" 2>/dev/null | awk 'NR==2{print $4}')
  echo "Free on output volume: ${avail_mb:-?} MB"
  # Only enforce a tight floor when writing to the internal Data volume.
  if [[ "$OUT_DIR" != /Volumes/* ]] && [[ -n "$avail_mb" ]] && (( avail_mb < 3000 )); then
    echo "ERROR: need ≥3 GB free on internal for Instruments (have ${avail_mb} MB)." >&2
    echo "Mount SSD1TB or set FLY_TRACE_DIR to a large volume." >&2
    exit 1
  fi
  echo

  cmd_launch

  local pid baseline start now elapsed did1=0 did2=0
  pid="$(shipping_pid)"
  [[ -n "$pid" ]] || { echo "No Shipping after launch"; exit 1; }
  baseline=0
  [[ -f "$GAME_LOG" ]] && baseline=$(wc -c <"$GAME_LOG" | tr -d ' ')
  start=$(date +%s)

  echo "Watching Shipping pid=$pid for ${watch_secs}s (log baseline=$baseline)…"

  record_pair() {
    local tag="$1"
    local reason="$2"
    local el="$3"
    pid="$(shipping_pid)"
    [[ -n "$pid" ]] || { echo "Shipping gone before $tag"; return 1; }
    echo ">>> TRIGGER $tag ($reason) t=${el}s pid=$pid"
    cmd_record "$cpu_secs" "$CPU_TEMPLATE" "cpu-${tag}" || echo "WARN: Time Profiler failed"
    pid="$(shipping_pid)"
    if [[ -n "$pid" ]]; then
      cmd_record "$hitch_secs" "$HITCH_TEMPLATE" "hitches-${tag}" || echo "WARN: Animation Hitches failed"
    fi
    if [[ "$use_metal" == "1" ]]; then
      pid="$(shipping_pid)"
      if [[ -n "$pid" ]]; then
        echo ">>> Metal System Trace (opt-in)…"
        cmd_record "${WATCH_METAL_SECS:-20}" "$METAL_TEMPLATE" "metal-${tag}" || echo "WARN: Metal failed"
      fi
    fi
    [[ -f "$GAME_LOG" ]] && baseline=$(wc -c <"$GAME_LOG" | tr -d ' ')
    return 0
  }

  while true; do
    now=$(date +%s)
    elapsed=$(( now - start ))
    if (( elapsed >= watch_secs )); then
      echo "Watch window ended (${elapsed}s)."
      break
    fi

    pid="$(shipping_pid)"
    if [[ -z "$pid" ]]; then
      echo "Shipping exited at t=${elapsed}s — stopping watch."
      break
    fi

    if (( did1 == 0 )); then
      local reason=""
      if (( elapsed >= min_log_after )) && log_suggests_in_world "$baseline"; then
        reason="log in-world/hitch (after +${min_log_after}s gate)"
      elif (( elapsed >= fallback_after )); then
        reason="fallback +${fallback_after}s"
      fi
      if [[ -n "$reason" ]]; then
        record_pair "1" "$reason" "$elapsed" || true
        did1=1
      fi
    elif (( did2 == 0 && elapsed >= second_after )); then
      record_pair "2" "second window +${second_after}s" "$elapsed" || true
      did2=1
    fi

    sleep 5
  done

  echo
  echo "======== WATCH SUMMARY ========"
  echo "capture1=$did1 capture2=$did2 elapsed=${elapsed:-?}s"
  ls -lt "$OUT_DIR"/*.trace 2>/dev/null | head -12 || echo "(no traces)"
  du -sh "$OUT_DIR"/* 2>/dev/null | head -12 || true
  echo "Done. Open: Tools/instruments-fly-hitch.sh --open <path.trace>"
}

usage() {
  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
}

main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    --launch) cmd_launch ;;
    --wait) cmd_wait ;;
    --watch) cmd_watch "${1:-10}" ;;
    --kill-all) cmd_kill_all ;;
    --record) cmd_record "${1:-20}" "$METAL_TEMPLATE" metal ;;
    --record-cpu) cmd_record "${1:-15}" "$CPU_TEMPLATE" cpu ;;
    --record-hitches) cmd_record "${1:-20}" "$HITCH_TEMPLATE" hitches ;;
    --open) cmd_open "${1:-}" ;;
    -h|--help|"") usage ;;
    *) echo "Unknown: $cmd" >&2; usage; exit 1 ;;
  esac
}

main "$@"
