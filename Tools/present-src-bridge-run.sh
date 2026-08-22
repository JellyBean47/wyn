#!/bin/bash
# Launch Fly Connect with fixed VERSION→version_wine spy + Cocoa SRC bridge.
# Goal: splash → transparent login becomes visible via StretchBlt SRC → setColorImage.
set -eu
BOTTLE="$HOME/Library/Containers/com.fly.gaming/Bottles/32050D6B-F756-491C-8CBF-8C4CAC1B5ECF"
UC="$BOTTLE/drive_c/Program Files (x86)/Ubisoft/Ubisoft Game Launcher"
WS="$HOME/Library/Application Support/com.fly.gaming/Libraries.steam/Wine/bin/wineserver"
WINE="$HOME/Library/Application Support/com.fly.gaming/Libraries.steam/Wine/bin/wine64"
WINE32_VER="$HOME/Library/Application Support/com.fly.gaming/Libraries.steam/Wine/lib/wine/i386-windows/version.dll"
TOOLS="/Users/ebenoelofse/Desktop/wyn/Tools/bin"
LOGDIR="$HOME/Library/Logs/com.fly.gaming"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$LOGDIR/present-src-bridge-$STAMP"
LL="$UC/logs/launcher_log.txt"
INJECT="$TOOLS/present_force_inject.dylib"
BRIDGE_HOST="$BOTTLE/drive_c/windows/temp/fly-stretch-bridge.bgra"
SPY_LOG="$BOTTLE/drive_c/windows/temp/present-stretch-spy.log"

mkdir -p "$OUT"

# Deploy spy via app-dir VERSION.dll → version_wine.dll (GetProcAddress stubs,
# NOT PE forwarders — Wine skips DllMain on forwarder-only PEs).
# Keep REAL UplayWebCore (shim remote-inject stalls splash).
cp -f "$TOOLS/present_stretch_spy.dll" "$UC/present_stretch_spy.dll"
cp -f "$TOOLS/version.dll" "$UC/version.dll"
cp -f "$WINE32_VER" "$UC/version_wine.dll"
if [ -f "$UC/UplayWebCore_real.exe" ] && [ "$(wc -c < "$UC/UplayWebCore_real.exe")" -gt 500000 ]; then
  cp -f "$UC/UplayWebCore_real.exe" "$UC/UplayWebCore.exe"
fi

cat > "$UC/devargs.txt" <<'EOF'
--no-sandbox
--in-process-gpu
--disable-gpu-compositing
--use-gl=angle
--use-angle=swiftshader-webgl
EOF
cp -f "$UC/devargs.txt" "$UC/testargs.txt"
cp -f "$UC/devargs.txt" "$UC/webcore_args.txt"

# Clear prior spy artifacts
rm -f "$BRIDGE_HOST" "$SPY_LOG" \
  "$BOTTLE/drive_c/windows/temp/fly-stretch-"*.bgra \
  "$BOTTLE/drive_c/windows/temp/debug-505da6.log" 2>/dev/null || true

export WINEPREFIX="$BOTTLE" WINEESYNC=1 WINE_SIMULATE_WRITECOPY=1
unset WINEMSYNC VK_ICD_FILENAMES || true
# version=n is REQUIRED — Wine hardcodes builtin version.dll and otherwise
# maps our app-dir PE path but runs builtin DllMain (spy never loads).
export WINEDLLOVERRIDES='winemenubuilder.exe=d;dwrite=b;d2d1,d3d10core=d;d3d11,dxgi=b;d3dcompiler_47=n;version=n'
export WINEDEBUG='-all'

"$WS" -k 2>/dev/null || true
sleep 1

: > "$OUT/wine.log"
: > "$OUT/monitor.txt"
# Byte mark can mis-count on rewritten logs; stamp wall time instead.
START_EPOCH=$(date +%s)

cd "$UC"
# Phase A (default): SRC spy only — no DYLD (avoids wineserver inject noise).
# Phase B: WITH_BRIDGE=1 adds Cocoa present_force_inject bridge.
WITH_BRIDGE="${WITH_BRIDGE:-0}"
if [ "$WITH_BRIDGE" = "1" ]; then
  nohup arch -x86_64 env \
    DYLD_INSERT_LIBRARIES="$INJECT" \
    PRESENT_FORCE_OPAQUE=0 \
    PRESENT_FORCE_LOGIN_FILL=0 \
    PRESENT_FORCE_LOGIN_BRIDGE=1 \
    PRESENT_BRIDGE_BGRA="$BRIDGE_HOST" \
    PRESENT_FORCE_LOG="$OUT/inject.log" \
    "$WINE" upc.exe \
    --no-sandbox --in-process-gpu \
    --disable-gpu-compositing --use-gl=angle --use-angle=swiftshader-webgl \
    >>"$OUT/wine.log" 2>&1 &
else
  nohup arch -x86_64 "$WINE" upc.exe \
    --no-sandbox --in-process-gpu \
    --disable-gpu-compositing --use-gl=angle --use-angle=swiftshader-webgl \
    >>"$OUT/wine.log" 2>&1 &
fi
echo $! > "$OUT/shell.pid"
echo "WITH_BRIDGE=$WITH_BRIDGE" > "$OUT/mode.txt"
disown || true

cat > "$OUT/monitor.sh" <<MON
#!/bin/bash
OUT="$OUT"
LL="$LL"
START_EPOCH=$START_EPOCH
BRIDGE_HOST="$BRIDGE_HOST"
SPY_LOG="$SPY_LOG"
BOTTLE="$BOTTLE"
for i in \$(seq 1 180); do
  ts=\$(date +%H:%M:%S)
  wins=\$(/tmp/fly-list-wine-windows 2>/dev/null | tr '\\n' ' ; ' || true)
  # Count Close lines whose log timestamp is at/after start (launcher uses local time).
  close=\$(rg 'Close for browser with id: 4' "\$LL" 2>/dev/null | awk -v start="\$START_EPOCH" '
    match(\$0, /[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/) {
      cmd = "date -j -f \"%Y-%m-%d %H:%M:%S\" \"" substr(\$0, RSTART, RLENGTH) "\" +%s"
      cmd | getline t; close(cmd)
      if (t+0 >= start+0) c++
    }
    END { print c+0 }')
  blits=\$(rg -c 'LOGIN_BLIT|LOGIN_BITBLT|LOGIN_STRETCHDIB' "\$SPY_LOG" 2>/dev/null || echo 0)
  hooks=\$(rg -c 'IAT blit hooks: iat=[1-9]|IAT StretchBlt hooks' "\$SPY_LOG" 2>/dev/null || echo 0)
  nz=\$(rg -o 'nonzero_rgb=[0-9]+' "\$SPY_LOG" 2>/dev/null | tail -3 | tr '\\n' ',' || true)
  br=0
  if [ -f "\$BRIDGE_HOST" ]; then br=\$(wc -c < "\$BRIDGE_HOST"); fi
  echo "[\$ts] #\$i close=\$close blits=\$blits hooks=\$hooks bridge=\$br nz=\$nz wins=\$wins" >> "\$OUT/monitor.txt"
  if [ "\$close" != "0" ] && echo "\$wins" | rg -q '1[0-9]{3}x'; then
    sleep 3
    screencapture -x "\$OUT/desktop.png" 2>/dev/null || true
    cp -f "\$SPY_LOG" "\$OUT/spy.log" 2>/dev/null || true
    cp -f "\$BRIDGE_HOST" "\$OUT/bridge.bgra" 2>/dev/null || true
    cp -f "\$OUT/inject.log" "\$OUT/inject.copy.log" 2>/dev/null || true
    # Keep capturing a few more frames
    for j in 1 2 3 4 5 6 7 8; do
      sleep 1
      screencapture -x "\$OUT/desktop-\$j.png" 2>/dev/null || true
      wins2=\$(/tmp/fly-list-wine-windows 2>/dev/null | tr '\\n' ' ; ' || true)
      br2=0; [ -f "\$BRIDGE_HOST" ] && br2=\$(wc -c < "\$BRIDGE_HOST")
      echo "[\$ts] post#\$j bridge=\$br2 wins=\$wins2" >> "\$OUT/monitor.txt"
    done
    cp -f "\$SPY_LOG" "\$OUT/spy.log" 2>/dev/null || true
    echo DONE >> "\$OUT/monitor.txt"
    exit 0
  fi
  sleep 1
done
cp -f "\$SPY_LOG" "\$OUT/spy.log" 2>/dev/null || true
echo timeout >> "\$OUT/monitor.txt"
MON
chmod +x "$OUT/monitor.sh"
nohup "$OUT/monitor.sh" >/dev/null 2>&1 &
disown || true

echo "OUT=$OUT"
echo "Launched Fly Connect with SRC→Cocoa bridge. Wait for splash→login."
echo "Spy log: $SPY_LOG"
echo "Bridge:  $BRIDGE_HOST"
