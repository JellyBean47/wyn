#!/bin/bash
# Reliable Connect launch on the fast present path.
#
# Connect intermittently wedges during CEF startup: `ConnectView.cpp — Using CEF with
# native rendering` is logged, then two `UplayWebCore --type=renderer` processes peg at
# ~80% CPU and `StartView.cpp` never appears. The window that does show up is an empty
# transparent splash-sized frame (~714x454) that never grows to the 1454x934 hub — the
# transparency is a *consequence* of the wedge, not a present bug: StartView never runs,
# so there is nothing to paint.
#
# A healthy launch reaches StartView in 3-5 s, so a launch that has not logged it within
# ~15 s never will. This wrapper watches for that one line and, if it does not come, tears
# the session down and launches again. Each retry goes through present-fast-run.sh, which
# drains the dying processes and unlinks the stale FLY4 surface first.
#
# Roughly 1 in 4 launches wedges through no fault of ours, so retrying quickly is the
# whole strategy -- expect it to take a few attempts and about a minute.
#
# Fallback if the fast path itself misbehaves:
#   bash ~/Desktop/wyn/Tools/present-win32u-bridge-run.sh
#
# All paths below are absolute, so this runs from any working directory. Invoke it by
# absolute path too — `bash Tools/...` only works from the repo root.
set -eu

FLY="$(cd "$(dirname "$0")/.." && pwd)"
BOTTLE="$HOME/Library/Containers/com.fly.gaming/Bottles/32050D6B-F756-491C-8CBF-8C4CAC1B5ECF"
WS="$HOME/Library/Application Support/com.fly.gaming/Libraries.steam/Wine/bin/wineserver"
LL="$BOTTLE/drive_c/Program Files (x86)/Ubisoft/Ubisoft Game Launcher/logs/launcher_log.txt"

ATTEMPTS="${FLY_LAUNCH_ATTEMPTS:-12}"
SV_TIMEOUT="${FLY_STARTVIEW_TIMEOUT:-40}"   # hard cap: how long to wait for the CEF line
SV_GRACE="${FLY_STARTVIEW_GRACE:-10}"       # how long StartView gets once CEF is up
BLIT_TIMEOUT="${FLY_BLIT_TIMEOUT:-60}"
CONNECT_PROCS='upc\.exe|UplayWebCore\.exe|UplayService\.exe'
# Retuned 11 Aug from all 73 launches in launcher_log.txt (see HANDOFF §2.27):
#   * Every one of the 20 successes logged StartView 3-5 s after "Using CEF" (5-8 s
#     after process start), never later, so a verdict 10 s past CEF is already
#     generous; the old flat 50 s just burned ~45 s of dead time per wedge.
#   * Success is ~27% per attempt and roughly FLAT against retry spacing (22% under
#     60 s vs 27% overall). The wedge is a per-attempt coin flip, not a sticky state
#     that needs to drain -- so many cheap attempts beat waiting.
#   * The old 60/120/240 schedule was actively harmful: it placed nearly every retry
#     in the 120-300 s band, which measured *worst* of all (8%, 2/26).
# Net effect: expected time-to-hub drops from ~10 min (usually failing) to ~1-2 min.
BACKOFF="${FLY_LAUNCH_BACKOFF:-0 5 5 5 5 5 5 5 5 5 5 5}"

renderer_cpu() {
  ps -axo pid,%cpu,command 2>/dev/null | awk '/UplayWebCore.exe --type=renderer/ {printf "%s ", $2}'
}

teardown() {
  WINEPREFIX="$BOTTLE" "$WS" -k 2>/dev/null || true
  sleep 3
}

for attempt in $(seq 1 "$ATTEMPTS"); do
  wait_s=$(echo "$BACKOFF" | awk -v n="$attempt" '{print ($n == "" ? 5 : $n)}')
  if [ "${wait_s:-0}" -gt 0 ] 2>/dev/null; then
    echo "--- ${wait_s}s pause before attempt $attempt ---"
    sleep "$wait_s"
  fi
  echo "=== launch attempt $attempt/$ATTEMPTS ($(date +%H:%M:%S)) ==="

  # Only ever look at launcher_log content this attempt appended, so a StartView line
  # from an earlier session can never be mistaken for success.
  off=0
  [ -f "$LL" ] && off=$(wc -c < "$LL" | tr -d ' ')

  launchlog=$(mktemp -t fly-launch)
  bash "$FLY/Tools/present-fast-run.sh" > "$launchlog" 2>&1 || true
  grep -E 'drain:|http2:|OUT=' "$launchlog" | sed 's/^/  /' || true
  OUT=$(grep '^OUT=' "$launchlog" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  rm -f "$launchlog"

  # Two-phase verdict. A flat timer started here is unreliable because the launch
  # overhead (present-fast-run.sh + wine start) varies 8-16 s, so a short window can
  # expire before upc.exe has even reached CEF and report a wedge that never happened.
  # Instead: wait for the CEF line, which proves the process is really up, and only
  # then time StartView against it. Measured across 20 successes, StartView follows
  # CEF by 3-5 s and START by 5-8 s, so SV_GRACE=10 s after CEF is a safe verdict.
  started=0; cef=0; gaveup=""
  for i in $(seq 1 "$SV_TIMEOUT"); do
    chunk=$(tail -c "+$((off + 1))" "$LL" 2>/dev/null || true)
    case "$chunk" in *StartView.cpp*) started=$i; break;; esac
    if [ "$cef" = "0" ]; then
      case "$chunk" in *"Using CEF with native rendering"*) cef=$i;; esac
    elif [ $((i - cef)) -ge "$SV_GRACE" ]; then
      gaveup="CEF reached at ${cef}s but no StartView in the ${SV_GRACE}s after it"
      break
    fi
    if ! pgrep -f "$CONNECT_PROCS" >/dev/null 2>&1; then
      gaveup="Connect exited after ${i}s without reaching StartView"
      break
    fi
    sleep 1
  done

  if [ "$started" = "0" ]; then
    [ -n "$gaveup" ] || gaveup="never reached CEF in ${SV_TIMEOUT}s"
    echo "  WEDGED — $gaveup (renderer cpu: $(renderer_cpu))"
    teardown
    continue
  fi

  echo "  StartView reached in ${started}s — CEF is alive"

  blits=0
  for j in $(seq 1 "$BLIT_TIMEOUT"); do
    if [ -n "$OUT" ] && grep -q 'FAST blit/s=[1-9]' "$OUT/spy.log" 2>/dev/null; then
      blits=$j
      break
    fi
    sleep 1
  done

  echo
  if [ "$blits" != "0" ]; then
    echo "LAUNCHED on attempt $attempt — first window blit at +${blits}s"
  else
    # CEF started, so this is not the wedge; the present path is worth inspecting
    # rather than retrying, because a retry cannot fix a present-side problem.
    echo "LAUNCHED on attempt $attempt, but no window blit within ${BLIT_TIMEOUT}s."
    echo "CEF is up, so this is NOT the startup wedge — check the present path:"
    echo "  grep -E 'FAST_CLAIM|FAST_LOCK|FAST_BLIT|FAST ' \"$OUT/spy.log\" | tail -20"
  fi
  echo "OUT=$OUT"
  echo "Watch:  grep 'FAST ' \"$OUT/spy.log\" | tail -5"
  exit 0
done

echo
echo "FAILED — CEF wedged on all $ATTEMPTS attempts."
echo "This is Connect's own StartView wedge, NOT the present path: a control launch with"
echo "no hook injected at all (Tools/connect-nohook-control.sh) wedges identically, with"
echo "the same two renderers at ~70% CPU. Nothing in our code can fix it from here."
echo "At the measured ~27% per-attempt success rate, $ATTEMPTS straight wedges is unlikely"
echo "(about 1 in $(awk -v n="$ATTEMPTS" 'BEGIN{printf "%.0f", 1/(0.73^n)}')), so something has probably changed — check that the network is up"
echo "and that upc.exe is not being throttled, rather than simply retrying forever."
echo "To keep trying anyway:"
echo "  FLY_LAUNCH_ATTEMPTS=24 bash $FLY/Tools/present-fast-launch.sh"
exit 1
