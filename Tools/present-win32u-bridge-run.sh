#!/bin/bash
# Connect + NtGdiStretchBlt EPILOGUE bridge (not entry trampoline — that kills Connect)
# + Cocoa present_force_inject for setColorImage when bridge.bgra appears.
set -eu
BOTTLE="$HOME/Library/Containers/com.fly.gaming/Bottles/32050D6B-F756-491C-8CBF-8C4CAC1B5ECF"
UC="$BOTTLE/drive_c/Program Files (x86)/Ubisoft/Ubisoft Game Launcher"
WS="$HOME/Library/Application Support/com.fly.gaming/Libraries.steam/Wine/bin/wineserver"
WINE="$HOME/Library/Application Support/com.fly.gaming/Libraries.steam/Wine/bin/wine64"
TOOLS="/Users/ebenoelofse/Desktop/wyn/Tools/bin"
LOGDIR="$HOME/Library/Logs/com.fly.gaming"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$LOGDIR/present-win32u-bridge-$STAMP"
LL="$UC/logs/launcher_log.txt"
EPI_DYLIB="$TOOLS/fly_stretch_epi_bridge.dylib"
INJECT="$TOOLS/present_force_inject.dylib"
BRIDGE_HOST="$BOTTLE/drive_c/windows/temp/fly-stretch-bridge.bgra"

mkdir -p "$OUT"

# #region agent log
python3 - <<PY
import json, time
p = "/Users/ebenoelofse/Desktop/wyn/.cursor/debug-b55dfe.log"
with open(p, "a") as f:
    f.write(json.dumps({
        "sessionId": "b55dfe",
        "runId": "unwedge-ck-http2",
        "hypothesisId": "H1",
        "location": "present-win32u-bridge-run.sh:start",
        "message": "launch start checkpoint-http2 restore path",
        "data": {"out": "$OUT", "bridge_host": "$BRIDGE_HOST"},
        "timestamp": int(time.time() * 1000),
    }) + "\n")
PY
# #endregion

cp -f "$UC/UplayWebCore_real.exe" "$UC/UplayWebCore.exe" 2>/dev/null || true
rm -f "$UC/version.dll" "$UC/version_wine.dll" 2>/dev/null || true

cat > "$UC/devargs.txt" <<'EOF'
--no-sandbox
--in-process-gpu
--disable-gpu-compositing
--use-gl=angle
--use-angle=swiftshader-webgl
EOF
cp -f "$UC/devargs.txt" "$UC/testargs.txt"
cp -f "$UC/devargs.txt" "$UC/webcore_args.txt"

rm -f "$BRIDGE_HOST" /tmp/fly-stretch-epi.log 2>/dev/null || true

export WINEPREFIX="$BOTTLE" WINEESYNC=1 WINE_SIMULATE_WRITECOPY=1
unset WINEMSYNC VK_ICD_FILENAMES || true
export WINEDLLOVERRIDES='winemenubuilder.exe=d;dwrite=b;d2d1,d3d10core=d;d3d11,dxgi=b;d3dcompiler_47=n'
export WINEDEBUG='-all'

"$WS" -k 2>/dev/null || true
sleep 1

# After wineserver -k, CEF http2 often wedges before StartView (transparent empty chrome).
# Prefer checkpoint snap; fall back to known bak. Opt out: FLY_RESTORE_HTTP2=0
if [ "${FLY_RESTORE_HTTP2:-1}" = "1" ]; then
  CACHE="$BOTTLE/drive_c/users/ebenoelofse/AppData/Local/Ubisoft Game Launcher/cache"
  CK_HTTP="/Users/ebenoelofse/Desktop/wyn/.scratch/checkpoint-bridge-working-20260810-205958/http2/http2"
  BAK_HTTP="$CACHE/http2.bak-20260809-2330"
  rm -rf "$CACHE/http2"
  if [ -d "$CK_HTTP" ]; then
    cp -a "$CK_HTTP" "$CACHE/http2"
    echo "http2: restored checkpoint snap"
  elif [ -d "$BAK_HTTP" ]; then
    cp -a "$BAK_HTTP" "$CACHE/http2"
    echo "http2: restored bak-20260809-2330"
  else
    echo "http2: cleared (no snap/bak found)"
  fi
fi

: > "$OUT/wine.log"
: > "$OUT/monitor.txt"
START_EPOCH=$(date +%s)

cd "$UC"
# SRC dump ON (FLY_STRETCH_DUMP=1) — log-only already proved LOGIN_EPI stable.
# Entry trampoline intentionally omitted (kills Connect).
# Detach wine into a new session so agent/Cursor shell teardown cannot kill it.
python3 - "$OUT" "$EPI_DYLIB" "$INJECT" "$BRIDGE_HOST" "$WINE" <<'PY'
import os, sys, subprocess
out, epi, inj, bridge, wine = sys.argv[1:6]
# Put DYLD_* on `env` argv — macOS SIP strips inherited DYLD_INSERT from Popen env.
cmd = [
    "arch", "-x86_64", "env",
    f"DYLD_INSERT_LIBRARIES={epi}:{inj}",
    f"STRETCHBLT_SPY_LOG={out}/spy.log",
    "FLY_STRETCH_DUMP=1",
    "PRESENT_FORCE_OPAQUE=0",
    "PRESENT_FORCE_LOGIN_FILL=0",
    "PRESENT_FORCE_LOGIN_BRIDGE=1",
    f"PRESENT_BRIDGE_BGRA={bridge}",
    f"PRESENT_FORCE_LOG={out}/inject.log",
    wine, "upc.exe",
    "--no-sandbox", "--in-process-gpu",
    "--disable-gpu-compositing", "--use-gl=angle", "--use-angle=swiftshader-webgl",
]
log = open(f"{out}/wine.log", "ab", buffering=0)
p = subprocess.Popen(
    cmd, env=os.environ.copy(), stdout=log, stderr=subprocess.STDOUT,
    stdin=subprocess.DEVNULL, start_new_session=True,
)
open(f"{out}/shell.pid", "w").write(str(p.pid))
print(f"wine_pid={p.pid}")
PY

cat > "$OUT/monitor.sh" <<MON
#!/bin/bash
OUT="$OUT"
LL="$LL"
START_EPOCH=$START_EPOCH
BRIDGE_HOST="$BRIDGE_HOST"
for i in \$(seq 1 180); do
  ts=\$(date +%H:%M:%S)
  wins=\$(/usr/bin/timeout 2 /tmp/fly-list-wine-windows 2>/dev/null | tr '\\n' ';' || echo timeout)
  close=\$(grep 'Close for browser with id: 4' "\$LL" 2>/dev/null | awk -v start="\$START_EPOCH" '
    match(\$0, /[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/) {
      cmd = "date -j -f \"%Y-%m-%d %H:%M:%S\" \"" substr(\$0, RSTART, RLENGTH) "\" +%s"
      cmd | getline t; close(cmd)
      if (t+0 >= start+0) c++
    }
    END { print c+0 }')
  [ -n "\$close" ] || close=0
  # grep -c prints 0 and exits 1 on no match, so guard on empty output (missing file)
  # rather than chaining an echo-0 fallback, which would emit a second line.
  # NOTE: this heredoc is unquoted -- no backticks in here, they get substituted.
  blits=\$(grep -c 'LOGIN_EPI' "\$OUT/spy.log" 2>/dev/null || true)
  [ -n "\$blits" ] || blits=0
  anyepi=\$(grep -c 'ANY_EPI' "\$OUT/spy.log" 2>/dev/null || true)
  [ -n "\$anyepi" ] || anyepi=0
  alive=\$(pgrep -f '[u]pc.exe|[U]playWebCore.exe' 2>/dev/null | wc -l | tr -d ' ')
  br=0; [ -f "\$BRIDGE_HOST" ] && br=\$(wc -c < "\$BRIDGE_HOST" | tr -d ' ')
  echo "[\$ts] #\$i alive=\$alive close=\$close epi=\$blits any=\$anyepi bridge=\$br wins=\$wins" >> "\$OUT/monitor.txt"
  if [ "\$close" != "0" ] && echo "\$wins" | grep -qE '1[0-9]{3}x'; then
    sleep 2
    screencapture -x "\$OUT/desktop.png" 2>/dev/null || true
    for j in 1 2 3 4 5 6; do
      sleep 1
      screencapture -x "\$OUT/desktop-\$j.png" 2>/dev/null || true
      bl2=\$(grep -c 'LOGIN_EPI' "\$OUT/spy.log" 2>/dev/null || true)
      [ -n "\$bl2" ] || bl2=0
      br2=0; [ -f "\$BRIDGE_HOST" ] && br2=\$(wc -c < "\$BRIDGE_HOST" | tr -d ' ')
      echo "[\$ts] post#\$j epi=\$bl2 bridge=\$br2" >> "\$OUT/monitor.txt"
    done
    echo DONE >> "\$OUT/monitor.txt"
    exit 0
  fi
  sleep 1
done
echo timeout >> "\$OUT/monitor.txt"
MON
chmod +x "$OUT/monitor.sh"
python3 - "$OUT/monitor.sh" "$OUT/monitor.stdout" "$OUT/monitor.pid" <<'PY'
import sys, subprocess
script, stdout_path, pid_path = sys.argv[1:4]
log = open(stdout_path, "ab", buffering=0)
p = subprocess.Popen(
    ["/bin/bash", script],
    stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
    start_new_session=True,
)
open(pid_path, "w").write(str(p.pid))
print(f"monitor_pid={p.pid}")
PY

# NOTE: the backgrounded "lifecycle watch" python block that used to live here was removed
# 11 Aug for leaking a ~36% CPU process on every launch. See the same note in
# present-parent-native-run.sh.

echo "OUT=$OUT"
echo "Epilogue hook + FLY_STRETCH_DUMP=1 + Cocoa bridge. Advance splash until login; watch for SRC_DUMP / bridge file."
