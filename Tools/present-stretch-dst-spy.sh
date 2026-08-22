#!/bin/bash
# §2.18 StretchBlt dst spy — LOG ONLY (no WindowFromDC/GetPixel in hook).
# After Close + login HWND: also run present_hwnd_dump / inspect.
set -euo pipefail
BOTTLE="$HOME/Library/Containers/com.fly.gaming/Bottles/32050D6B-F756-491C-8CBF-8C4CAC1B5ECF"
UC="$BOTTLE/drive_c/Program Files (x86)/Ubisoft/Ubisoft Game Launcher"
WINE="$HOME/Library/Application Support/com.fly.gaming/Libraries.steam/Wine/bin/wine64"
WS="$HOME/Library/Application Support/com.fly.gaming/Libraries.steam/Wine/bin/wineserver"
SPY_SRC="/Users/ebenoelofse/Desktop/wyn/Tools/stretchblt_dst_spy.c"
SPY_DYLIB="/Users/ebenoelofse/Desktop/wyn/Tools/bin/stretchblt_dst_spy.dylib"
DUMP_EXE="/Users/ebenoelofse/Desktop/wyn/Tools/bin/present_hwnd_dump.exe"
INSP_EXE="/Users/ebenoelofse/Desktop/wyn/Tools/bin/present_hwnd_inspect.exe"
LOGDIR="$HOME/Library/Logs/com.fly.gaming"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$LOGDIR/present-stretch-dst-$STAMP"
LL="$UC/logs/launcher_log.txt"

mkdir -p "$OUT" "$(dirname "$SPY_DYLIB")"
echo "$OUT" > /tmp/fly-stretch-dst-out.txt

clang -arch x86_64 -dynamiclib -O2 -o "$SPY_DYLIB" "$SPY_SRC" \
  -isysroot "$(xcrun --sdk macosx --show-sdk-path)"
file "$SPY_DYLIB" | tee "$OUT/build.txt"

cat > "$UC/devargs.txt" <<'EOF'
--no-sandbox
--in-process-gpu
--disable-gpu-compositing
--use-gl=angle
--use-angle=swiftshader-webgl
EOF
cp -f "$UC/devargs.txt" "$UC/testargs.txt"
cp -f "$UC/devargs.txt" "$UC/webcore_args.txt"

export WINEPREFIX="$BOTTLE" WINEESYNC=1 WINE_SIMULATE_WRITECOPY=1
unset WINEMSYNC VK_ICD_FILENAMES
export WINEDLLOVERRIDES='winemenubuilder.exe=d;dwrite=b;d2d1,d3d10core=d;d3d11,dxgi=b;d3dcompiler_47=n'
export WINEDEBUG='-all'
export MVK_CONFIG_LOG_LEVEL=0

"$WS" -k 2>/dev/null || true
sleep 1

LL_MARK=$(wc -c < "$LL" 2>/dev/null || echo 0)
: > "$OUT/wine.log"
: > "$OUT/spy.log"
: > "$OUT/monitor.txt"

cd "$UC"
nohup arch -x86_64 env \
  DYLD_INSERT_LIBRARIES="$SPY_DYLIB" \
  STRETCHBLT_SPY_LOG="$OUT/spy.log" \
  "$WINE" upc.exe \
  --no-sandbox --in-process-gpu \
  --disable-gpu-compositing --use-gl=angle --use-angle=swiftshader-webgl \
  >>"$OUT/wine.log" 2>&1 &
echo $! > "$OUT/shell.pid"
disown || true
echo "launched OUT=$OUT pid=$(cat "$OUT/shell.pid")"

nohup bash -c "
OUT='$OUT'; LL='$LL'; LL_MARK='$LL_MARK'
WINE='$WINE'; BOTTLE='$BOTTLE'
DUMP_EXE='$DUMP_EXE'; INSP_EXE='$INSP_EXE'
CLOSE=0; DUMPED=0
export WINEPREFIX=\"\$BOTTLE\" WINEESYNC=1
unset WINEMSYNC
for i in \$(seq 1 600); do
  ts=\$(date +%H:%M:%S)
  wins=\$(/tmp/fly-list-wine-windows 2>/dev/null | tr '\n' ' ; ' || true)
  blits=\$(rg -c 'LOGIN_BLIT' \"\$OUT/spy.log\" 2>/dev/null || echo 0)
  if [ \"\$CLOSE\" -eq 0 ]; then
    n=\$(tail -c +\"\$((LL_MARK+1))\" \"\$LL\" 2>/dev/null | rg -c 'Close for browser with id: 4' || echo 0)
    if [ \"\${n:-0}\" -gt 0 ]; then
      CLOSE=1
      echo \"[\$ts] CLOSE\" >> \"\$OUT/monitor.txt\"
    fi
  fi
  if [ \"\$CLOSE\" -eq 0 ] && echo \"\$wins\" | rg -q '1[0-9]{3}x'; then
    CLOSE=1
    echo \"[\$ts] large HWND as login\" >> \"\$OUT/monitor.txt\"
  fi
  echo \"[\$ts] #\$i close=\$CLOSE blits=\$blits wins=\$wins\" >> \"\$OUT/monitor.txt\"
  if [ \"\$CLOSE\" -eq 1 ] && [ \"\$DUMPED\" -eq 0 ] && [ \"\${blits:-0}\" -ge 2 ]; then
    DUMPED=1
    sleep 2
    echo \"[\$ts] hwnd dump/inspect\" >> \"\$OUT/monitor.txt\"
    arch -x86_64 \"\$WINE\" \"\$DUMP_EXE\" \"C:\\\\windows\\\\temp\\\\fly-login-spy.bgra\" \
      >\"\$OUT/hwnd-dump.txt\" 2>&1 || true
    arch -x86_64 \"\$WINE\" \"\$INSP_EXE\" >\"\$OUT/hwnd-inspect.txt\" 2>&1 || true
    BG=\"\$BOTTLE/drive_c/windows/temp/fly-login-spy.bgra\"
    [ -f \"\$BG\" ] && cp -f \"\$BG\" \"\$OUT/fly-login-spy.bgra\" || true
  fi
  if [ \"\$CLOSE\" -eq 1 ] && [ \"\${blits:-0}\" -ge 5 ] && [ \"\$DUMPED\" -eq 1 ]; then
    echo \"[\$ts] DONE\" >> \"\$OUT/monitor.txt\"
    {
      echo '=== LOGIN_BLIT ==='
      rg -n 'LOGIN_BLIT' \"\$OUT/spy.log\" || true
      echo '=== hwnd-dump ==='
      cat \"\$OUT/hwnd-dump.txt\" 2>/dev/null || true
      echo '=== hwnd-inspect ==='
      cat \"\$OUT/hwnd-inspect.txt\" 2>/dev/null || true
      echo '=== windows ==='
      /tmp/fly-list-wine-windows 2>/dev/null || true
    } > \"\$OUT/summary.txt\"
    exit 0
  fi
  sleep 1
done
echo timeout >> \"\$OUT/monitor.txt\"
" >/dev/null 2>&1 &
disown || true

for i in $(seq 1 30); do
  if /tmp/fly-list-wine-windows 2>/dev/null | rg -q 'Ubisoft'; then
    /tmp/fly-list-wine-windows 2>/dev/null
    break
  fi
  sleep 1
done
echo "OUT=$OUT — drive splash→Close→login, then Proceed"
