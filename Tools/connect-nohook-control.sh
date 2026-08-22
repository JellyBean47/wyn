#!/bin/bash
# Control launch: plain Connect under Wine with NO present hook injected at all.
#
# Purpose is to settle one question — does the StartView wedge belong to our present
# code or to Connect/CEF under Wine? Identical prefix, identical devargs, identical
# upc.exe flags as Tools/present-parent-native-run.sh, minus DYLD_INSERT_LIBRARIES.
# Reports only whether StartView.cpp is reached.
set -eu
BOTTLE="$HOME/Library/Containers/com.fly.gaming/Bottles/32050D6B-F756-491C-8CBF-8C4CAC1B5ECF"
UC="$BOTTLE/drive_c/Program Files (x86)/Ubisoft/Ubisoft Game Launcher"
WS="$HOME/Library/Application Support/com.fly.gaming/Libraries.steam/Wine/bin/wineserver"
WINE="$HOME/Library/Application Support/com.fly.gaming/Libraries.steam/Wine/bin/wine64"
LL="$UC/logs/launcher_log.txt"
CONNECT_PROCS='upc\.exe|UplayWebCore\.exe|UplayService\.exe'
SV_TIMEOUT="${FLY_STARTVIEW_TIMEOUT:-50}"

export WINEPREFIX="$BOTTLE" WINEESYNC=1 WINE_SIMULATE_WRITECOPY=1
unset WINEMSYNC VK_ICD_FILENAMES || true
export WINEDLLOVERRIDES='winemenubuilder.exe=d;dwrite=b;d2d1,d3d10core=d;d3d11,dxgi=b;d3dcompiler_47=n'
export WINEDEBUG='-all'

"$WS" -k 2>/dev/null || true
for i in $(seq 1 40); do
  pgrep -f "$CONNECT_PROCS" >/dev/null 2>&1 || break
  sleep 0.5
done

if [ "${FLY_RESTORE_HTTP2:-1}" = "1" ]; then
  CACHE="$BOTTLE/drive_c/users/ebenoelofse/AppData/Local/Ubisoft Game Launcher/cache"
  CK="/Users/ebenoelofse/Desktop/wyn/.scratch/checkpoint-bridge-working-LATEST/http2/http2"
  rm -rf "$CACHE/http2"
  [ -d "$CK" ] && cp -a "$CK" "$CACHE/http2"
  echo "http2: restored"
else
  echo "http2: left as-is"
fi

off=0
[ -f "$LL" ] && off=$(wc -c < "$LL" | tr -d ' ')

LOGDIR="$HOME/Library/Logs/com.fly.gaming"
OUT="$LOGDIR/connect-nohook-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
cd "$UC"   # upc.exe is resolved relative to the install dir, as in the real launcher
nohup arch -x86_64 "$WINE" upc.exe \
  --no-sandbox --in-process-gpu --disable-gpu-compositing \
  --use-gl=angle --use-angle=swiftshader-webgl \
  > "$OUT/wine.log" 2>&1 &
echo "launched pid=$! (no DYLD_INSERT_LIBRARIES)"

for i in $(seq 1 "$SV_TIMEOUT"); do
  if tail -c "+$((off + 1))" "$LL" 2>/dev/null | grep -q 'StartView\.cpp'; then
    echo "RESULT: StartView reached in ${i}s — no-hook launch OK"
    exit 0
  fi
  sleep 1
done
echo "RESULT: WEDGED with no hook — no StartView in ${SV_TIMEOUT}s (renderer cpu:$(ps -axo pid,%cpu,command | awk '/UplayWebCore.exe --type=renderer/ {printf " %s", $2}'))"
exit 1
