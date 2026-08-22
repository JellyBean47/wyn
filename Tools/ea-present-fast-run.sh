#!/bin/bash
# EA App FLY4 present — same stack as Connect Tools/present-fast-run.sh.
#
# Dedicated EA bottle only. NEVER wineserver -k Steam 32050D6B.
# Do not use this script for Connect (that remains present-fast-launch.sh).
#
# Wyn Play (EA App tile) is the product path. This script is the debug twin.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STEAM_BOTTLE_UUID="32050D6B-F756-491C-8CBF-8C4CAC1B5ECF"
BOTTLE="${FLY_EA_BOTTLE:-$HOME/Library/Containers/com.fly.gaming/Bottles/22BC8270-AD93-4263-A9AC-0685E29BCE90}"
case "$BOTTLE" in
  *"$STEAM_BOTTLE_UUID"*)
    echo "REFUSING: EA present must not target the Steam bottle $STEAM_BOTTLE_UUID" >&2
    exit 2
    ;;
esac

TREE_DIR="$HOME/Library/Application Support/com.fly.gaming/Libraries.steam/Wine"
WS="$TREE_DIR/bin/wineserver"
WINE="$TREE_DIR/bin/wine64"
TOOLS="$ROOT/Tools/bin"
EPI_DYLIB="${FLY_EPI_DYLIB:-$TOOLS/fly_stretch_epi_bridge.fast.dylib}"
INJECT="$TOOLS/present_force_inject.dylib"
SHM4_NAME="${FLY_BRIDGE_SHM4_NAME:-/fly-ea-stretch-bridge4}"

for b in "$WS" "$WINE" "$EPI_DYLIB" "$INJECT"; do
  [ -x "$b" ] || [ -f "$b" ] || { echo "missing: $b" >&2; exit 2; }
done
[ -d "$BOTTLE" ] || { echo "EA bottle missing: $BOTTLE" >&2; exit 2; }

find_ea_desktop() {
  local root="$BOTTLE/drive_c/Program Files/Electronic Arts/EA Desktop"
  local nested
  if [ -x "$root/EA Desktop/EADesktop.exe" ]; then
    printf '%s\n' "$root/EA Desktop/EADesktop.exe"
    return 0
  fi
  if [ -d "$root" ]; then
    # Newest versioned dir first (PlatformCatalog does the same).
    nested=$(ls -1d "$root"/*/EA\ Desktop/EADesktop.exe 2>/dev/null | sort -r | head -1 || true)
    if [ -n "$nested" ] && [ -x "$nested" ]; then
      printf '%s\n' "$nested"
      return 0
    fi
  fi
  return 1
}

EXE="$(find_ea_desktop)" || { echo "EADesktop.exe not found under $BOTTLE" >&2; exit 2; }
EA_DIR="$(dirname "$EXE")"
LOGDIR="$HOME/Library/Logs/com.fly.gaming"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$LOGDIR/present-ea-$STAMP"
BRIDGE_HOST="$BOTTLE/drive_c/windows/temp/fly-stretch-bridge.bgra"
mkdir -p "$OUT"

export FLY_BRIDGE_SHM4_NAME="$SHM4_NAME"

# Virgin FLY4 segment for this bottle. Do NOT unlink /fly-upc-stretch-bridge4
# (that is Connect on the Steam prefix).
python3 -c 'import ctypes,ctypes.util,os
name=os.environ["FLY_BRIDGE_SHM4_NAME"].encode()
ctypes.CDLL(ctypes.util.find_library("c")).shm_unlink(name)' 2>/dev/null || true

export WINEPREFIX="$BOTTLE"
export WINEESYNC=1
export WINE_SIMULATE_WRITECOPY=1
unset VK_ICD_FILENAMES || true
unset WINEMSYNC || true
export WINEDLLOVERRIDES="${FLY_DLLOVERRIDES:-winemenubuilder.exe=d;winedbg.exe=d;d3d11,dxgi,d3d10core=n,b;d3d12=d}"
export WINEDEBUG="${FLY_WINEDEBUG:--all}"

echo "bottle=$BOTTLE"
echo "exe=$EXE"
echo "wine=$WINE"
echo "shm=$SHM4_NAME"
echo "REFUSING Steam bottle $STEAM_BOTTLE_UUID (not sending wineserver -k there)"

# EA prefix only.
"$WS" -k 2>/dev/null || true
EA_PROCS='EADesktop\.exe|EACefSubProcess\.exe|EABackgroundService\.exe|EALocalHostSvc\.exe'
drain_start=$(date +%s)
for i in $(seq 1 40); do
  alive=$(pgrep -f "$EA_PROCS" 2>/dev/null | wc -l | tr -d ' ')
  [ "$alive" = "0" ] && break
  if [ "$i" = "16" ]; then
    echo "drain: still $alive after 8s, SIGKILL EA procs (not Steam)"
    pkill -9 -f "$EA_PROCS" 2>/dev/null || true
  fi
  sleep 0.5
done
alive=$(pgrep -f "$EA_PROCS" 2>/dev/null | wc -l | tr -d ' ')
echo "drain: ea procs=$alive after $(( $(date +%s) - drain_start ))s"
sleep 1

: > "$OUT/wine.log"

cd "$EA_DIR"
python3 - "$OUT" "$EPI_DYLIB" "$INJECT" "$BRIDGE_HOST" "$WINE" "$EXE" "$SHM4_NAME" <<'PY'
import os, sys, subprocess
out, epi, inj, bridge, wine, exe, shm4 = sys.argv[1:8]
cmd = [
    "arch", "-x86_64", "env",
    f"DYLD_INSERT_LIBRARIES={epi}:{inj}",
    f"STRETCHBLT_SPY_LOG={out}/spy.log",
    "FLY_STRETCH_DUMP=1",
    "FLY_FAST_PRESENT=1",
    "FLY_PARENT_PRESENT=1",
    "FLY_COCOA_FAST=1",
    "FLY_BRIDGE_SHM=0",
    "FLY_BRIDGE_FILE=0",
    "FLY_OPTION_B=0",
    "FLY_SURFACE_MAP=0",
    f"FLY_BRIDGE_SHM4_NAME={shm4}",
    "PRESENT_FORCE_LOGIN_BRIDGE=0",
    "PRESENT_FORCE_OPAQUE=0",
    "PRESENT_FORCE_LOGIN_FILL=0",
    "PRESENT_FORCE_LOGIN_SYNC=0",
    f"PRESENT_BRIDGE_BGRA={bridge}",
    f"PRESENT_FORCE_LOG={out}/inject.log",
    "QT_OPENGL=angle",
    "QT_ANGLE_PLATFORM=d3d11",
    "QT_QUICK_BACKEND=software",
    "QSG_RENDER_LOOP=basic",
    wine, os.path.basename(exe),
    "--disable-gpu-compositing",
    "--in-process-gpu",
    "--use-gl=angle",
    "--use-angle=swiftshader-webgl",
]
log = open(f"{out}/wine.log", "ab", buffering=0)
p = subprocess.Popen(
    cmd, env=os.environ.copy(), stdout=log, stderr=subprocess.STDOUT,
    stdin=subprocess.DEVNULL, start_new_session=True,
)
open(f"{out}/shell.pid", "w").write(str(p.pid))
print(f"wine_pid={p.pid} epi={epi} shm={shm4}")
PY

echo "OUT=$OUT"
echo "Watch:  grep -E 'epi hooked|FAST_SHM|FAST blit|peek parent|UNEXPECTED' \"$OUT/spy.log\""
echo "Product path: quit old Wyn, open /tmp/WynDerivedData/Build/Products/Debug/Wyn.app, click EA App."
