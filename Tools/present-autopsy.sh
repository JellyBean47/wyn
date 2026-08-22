#!/bin/bash
# Present autopsy: §2.8 Connect → splash→ghost → Cocoa probe → force opaque → probe again.
set -euo pipefail
BOTTLE="$HOME/Library/Containers/com.fly.gaming/Bottles/32050D6B-F756-491C-8CBF-8C4CAC1B5ECF"
UC="$BOTTLE/drive_c/Program Files (x86)/Ubisoft/Ubisoft Game Launcher"
WINE="$HOME/Library/Application Support/com.fly.gaming/Libraries.steam/Wine/bin/wine64"
WS="$HOME/Library/Application Support/com.fly.gaming/Libraries.steam/Wine/bin/wineserver"
LOGDIR="$HOME/Library/Logs/com.fly.gaming"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$LOGDIR/present-autopsy-$STAMP"
LOG="$OUT/wine.log"
MON="$OUT/monitor.txt"
LL="$UC/logs/launcher_log.txt"
mkdir -p "$OUT"

swiftc -O /Users/ebenoelofse/Desktop/wyn/Tools/present-cocoa-probe.swift -o "$OUT/present-cocoa-probe" 2>"$OUT/swiftc.err"

export WINEPREFIX="$BOTTLE" WINEESYNC=1 WINE_SIMULATE_WRITECOPY=1
unset WINEMSYNC VK_ICD_FILENAMES
"$WS" -k 2>/dev/null || true
sleep 1

cat > "$UC/devargs.txt" <<'EOF'
--no-sandbox
--in-process-gpu
--disable-gpu-compositing
--use-gl=angle
--use-angle=swiftshader-webgl
EOF
cp -f "$UC/devargs.txt" "$UC/testargs.txt"
cp -f "$UC/devargs.txt" "$UC/webcore_args.txt"
[ -f "$UC/UplayWebCore_real.exe" ] && cp -f "$UC/UplayWebCore_real.exe" "$UC/UplayWebCore.exe"

export WINEDLLOVERRIDES='winemenubuilder.exe=d;dwrite=b;d2d1,d3d10core=d;d3d11,dxgi=b;d3dcompiler_47=n'
# Light channels only — heavy +macdrv destabilizes Connect (HANDOFF)
export WINEDEBUG='+bitblt,+timestamp'
export MVK_CONFIG_LOG_LEVEL=0

LL_MARK=$(wc -c < "$LL" 2>/dev/null || echo 0)

: > "$LOG"
cd "$UC"
arch -x86_64 "$WINE" upc.exe \
  --no-sandbox --in-process-gpu \
  --disable-gpu-compositing --use-gl=angle --use-angle=swiftshader-webgl \
  >>"$LOG" 2>&1 &
echo $! > "$OUT/shell.pid"
disown || true
sleep 3

CLOSE_SEEN=0
DID_FORCE=0
POST_FORCE_TICKS=0
for i in $(seq 1 100); do
  ts=$(date +%H:%M:%S)
  wins=$(/tmp/fly-list-wine-windows 2>/dev/null | tr '\n' ' ; ' || true)
  large=$(rg -c '1454x934' "$LOG" 2>/dev/null || echo 0)
  # New Close lines since mark
  if [ "$CLOSE_SEEN" -eq 0 ]; then
    newclose=$(tail -c +"$((LL_MARK+1))" "$LL" 2>/dev/null | rg -c 'Close for browser with id: 4' || echo 0)
    if [ "${newclose:-0}" -gt 0 ]; then
      CLOSE_SEEN=1
      echo "[$ts] CLOSE seen (new since mark)" | tee -a "$MON"
      sleep 3
      echo "[$ts] PRE-FORCE probe" | tee -a "$MON"
      "$OUT/present-cocoa-probe" "$OUT/pre-force" | tee -a "$MON" || true
    fi
  fi
  if [ "$CLOSE_SEEN" -eq 1 ] && [ "$DID_FORCE" -eq 0 ] && [ "${large:-0}" -gt 3 ]; then
    WPID=$(/tmp/fly-list-wine-windows 2>/dev/null | awk '/owner=wine/{for(i=1;i<=NF;i++) if($i~/^pid=/){split($i,a,"="); print a[2]; exit}}')
    if [ -z "${WPID:-}" ]; then
      WPID=$(/tmp/fly-list-wine-windows 2>/dev/null | awk '/wine/{for(i=1;i<=NF;i++) if($i~/^pid=/){split($i,a,"="); print a[2]; exit}}')
    fi
    if [ -n "${WPID:-}" ]; then
      DID_FORCE=1
      echo "[$ts] FORCE opaque via lldb pid=$WPID large=$large" | tee -a "$MON"
      lldb -p "$WPID" --batch \
        -o "command script import /Users/ebenoelofse/Desktop/wyn/Tools/present_force_lldb.py" \
        -o "present_force" \
        -o "detach" \
        -o "quit" \
        >"$OUT/lldb-force.log" 2>&1 || echo "lldb exit $?" | tee -a "$MON"
      sleep 2
      echo "[$ts] POST-FORCE probe" | tee -a "$MON"
      "$OUT/present-cocoa-probe" "$OUT/post-force" | tee -a "$MON" || true
    fi
  fi
  if [ "$DID_FORCE" -eq 1 ]; then
    POST_FORCE_TICKS=$((POST_FORCE_TICKS+1))
  fi
  echo "[$ts] #$i close=$CLOSE_SEEN force=$DID_FORCE large=$large wins=$wins" >> "$MON"
  if [ "$DID_FORCE" -eq 1 ] && [ "$POST_FORCE_TICKS" -ge 8 ]; then
    break
  fi
  # Also trigger force on large HWND even if Close log lagging
  if [ "$DID_FORCE" -eq 0 ] && [ "${large:-0}" -gt 10 ] && echo "$wins" | rg -q '1[0-9]{3}x'; then
    CLOSE_SEEN=1
  fi
  sleep 1
done

{
  echo "=== CreateWindowSurface ==="
  rg -n 'macdrv_CreateWindowSurface' "$LOG" | head -100
  echo "=== First large StretchBlt / surface ==="
  rg -n '1454x934|1536x1024|layered 0, surface_rect \(0,0\)-\(1' "$LOG" | head -40
} | tee "$OUT/summary.txt"

echo "OUT=$OUT"
echo "Connect left running for visual check. Kill: WINEPREFIX=\"$BOTTLE\" \"$WS\" -k"
