#!/bin/bash
# Stock Connect + instant HWND dump on first large window (no DYLD, no shim).
set -eu
BOTTLE="$HOME/Library/Containers/com.fly.gaming/Bottles/32050D6B-F756-491C-8CBF-8C4CAC1B5ECF"
UC="$BOTTLE/drive_c/Program Files (x86)/Ubisoft/Ubisoft Game Launcher"
WS="$HOME/Library/Application Support/com.fly.gaming/Libraries.steam/Wine/bin/wineserver"
WINE="$HOME/Library/Application Support/com.fly.gaming/Libraries.steam/Wine/bin/wine64"
DUMP_EXE="/Users/ebenoelofse/Desktop/wyn/Tools/bin/present_hwnd_dump.exe"
INSP_EXE="/Users/ebenoelofse/Desktop/wyn/Tools/bin/present_hwnd_inspect.exe"
LOGDIR="$HOME/Library/Logs/com.fly.gaming"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$LOGDIR/present-stock-$STAMP"
LL="$UC/logs/launcher_log.txt"

mkdir -p "$OUT"
echo "$OUT" > /tmp/fly-stretch-dst-out.txt

# Stock WebCore only
cp -f "$UC/UplayWebCore_real.exe" "$UC/UplayWebCore.exe"
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
unset WINEMSYNC VK_ICD_FILENAMES || true
export WINEDLLOVERRIDES='winemenubuilder.exe=d;dwrite=b;d2d1,d3d10core=d;d3d11,dxgi=b;d3dcompiler_47=n'
export WINEDEBUG='-all'

"$WS" -k 2>/dev/null || true
sleep 1

: > "$OUT/wine.log"
: > "$OUT/monitor.txt"
MARK=$(wc -c < "$LL" 2>/dev/null || echo 0)

cd "$UC"
nohup arch -x86_64 "$WINE" upc.exe \
  --no-sandbox --in-process-gpu \
  --disable-gpu-compositing --use-gl=angle --use-angle=swiftshader-webgl \
  >>"$OUT/wine.log" 2>&1 &
echo $! > "$OUT/shell.pid"
disown || true

# Monitor as standalone script file (avoids quoting death)
cat > "$OUT/monitor.sh" <<MON
#!/bin/bash
OUT="$OUT"
LL="$LL"
MARK=$MARK
BOTTLE="$BOTTLE"
WINE="$WINE"
DUMP_EXE="$DUMP_EXE"
INSP_EXE="$INSP_EXE"
export WINEPREFIX="\$BOTTLE" WINEESYNC=1
unset WINEMSYNC || true
DUMPED=0
for i in \$(seq 1 360); do
  ts=\$(date +%H:%M:%S)
  wins=\$(/tmp/fly-list-wine-windows 2>/dev/null | tr '\\n' ' ; ' || true)
  n=\$(tail -c +\$((MARK+1)) "\$LL" 2>/dev/null | rg -c 'Close for browser with id: 4' || echo 0)
  echo "[\$ts] #\$i close_log=\$n dumps=\$DUMPED wins=\$wins" >> "\$OUT/monitor.txt"
  if [ "\$DUMPED" -eq 0 ] && echo "\$wins" | rg -q '1[0-9]{3}x'; then
    DUMPED=1
    echo "[\$ts] INSTANT DUMP" >> "\$OUT/monitor.txt"
    arch -x86_64 "\$WINE" "\$DUMP_EXE" 'C:\\windows\\temp\\fly-login-spy.bgra' >"\$OUT/hwnd-dump.txt" 2>&1 || true
    arch -x86_64 "\$WINE" "\$INSP_EXE" >"\$OUT/hwnd-inspect.txt" 2>&1 || true
    cp -f "\$BOTTLE/drive_c/windows/temp/fly-login-spy.bgra" "\$OUT/" 2>/dev/null || true
    screencapture -x "\$OUT/desktop.png" 2>/dev/null || true
    {
      echo "=== dump ==="; cat "\$OUT/hwnd-dump.txt" 2>/dev/null
      echo "=== inspect ==="; cat "\$OUT/hwnd-inspect.txt" 2>/dev/null
      echo "=== windows ==="; /tmp/fly-list-wine-windows 2>/dev/null
    } > "\$OUT/summary.txt"
    echo DONE >> "\$OUT/monitor.txt"
    for j in \$(seq 1 20); do
      ts2=\$(date +%H:%M:%S)
      wins2=\$(/tmp/fly-list-wine-windows 2>/dev/null | tr '\\n' ' ; ' || true)
      echo "[\$ts2] post#\$j wins=\$wins2" >> "\$OUT/monitor.txt"
      sleep 1
    done
    exit 0
  fi
  sleep 1
done
echo timeout >> "\$OUT/monitor.txt"
MON
chmod +x "$OUT/monitor.sh"
nohup "$OUT/monitor.sh" >/dev/null 2>&1 &
disown || true

for i in $(seq 1 30); do
  w=$(/tmp/fly-list-wine-windows 2>/dev/null || true)
  if echo "$w" | rg -q 'Ubisoft Connect'; then
    echo "SPLASH: $w"
    break
  fi
  sleep 1
done
echo "OUT=$OUT"
echo "Fly Wine Connect only — not CrossOver. Wait for large login window."
