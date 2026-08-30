#!/bin/bash
# Connect present launch — product default: parent-native POSIX shm (FOSS).
#   FLY_PARENT_PRESENT=1 PRESENT_FORCE_LOGIN_BRIDGE=0 FLY_BRIDGE_SHM=1 FLY_BRIDGE_FILE=0
# Cocoa file-pixel inject is opt-in fallback:
#   PRESENT_FORCE_LOGIN_BRIDGE=1 FLY_BRIDGE_FILE=1  (FILE auto-on if unset when bridge=1)
# Epilogue StretchBlt hook only — entry trampoline kills Connect.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BOTTLE="$HOME/Library/Containers/com.fly.gaming/Bottles/32050D6B-F756-491C-8CBF-8C4CAC1B5ECF"
UC="$BOTTLE/drive_c/Program Files (x86)/Ubisoft/Ubisoft Game Launcher"

# Which Wine tree runs Connect. Default `steam` (frankea) is the proven one.
# `game` targets the GPTK/D3DMetal tree — needed because Connect wedges at its CEF
# login view there, which is what blocks the D3DMetal path for Ubisoft titles. The
# correct order for that path is Connect (this script) → Steam → game, all on `game`,
# because the `wineserver -k` below takes down anything already running in the bottle.
FLY_WINE_TREE="${FLY_WINE_TREE:-steam}"
case "$FLY_WINE_TREE" in
  steam) TREE_DIR="$HOME/Library/Application Support/com.fly.gaming/Libraries.steam/Wine" ;;
  game)  TREE_DIR="$HOME/Library/Application Support/com.fly.gaming/Libraries/Wine" ;;
  *) echo "FLY_WINE_TREE must be 'steam' or 'game' (got '$FLY_WINE_TREE')" >&2; exit 2 ;;
esac
WS="$TREE_DIR/bin/wineserver"
WINE="$TREE_DIR/bin/wine64"
for b in "$WS" "$WINE"; do
  [ -x "$b" ] || { echo "missing wine binary for tree '$FLY_WINE_TREE': $b" >&2; exit 2; }
done
echo "tree=$FLY_WINE_TREE wine=$WINE"
TOOLS="$ROOT/Tools/bin"
LOGDIR="$HOME/Library/Logs/com.fly.gaming"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$LOGDIR/present-win32u-bridge-$STAMP"
LL="$UC/logs/launcher_log.txt"
# Parent-capable epi is the product default; override with FLY_EPI_DYLIB.
EPI_DYLIB="$TOOLS/fly_stretch_epi_bridge.optionb.dylib"
if [ ! -f "$EPI_DYLIB" ]; then
  EPI_DYLIB="$TOOLS/fly_stretch_epi_bridge.dylib"
fi
if [ -n "${FLY_EPI_DYLIB:-}" ] && [ -f "$FLY_EPI_DYLIB" ]; then
  EPI_DYLIB="$FLY_EPI_DYLIB"
fi
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

# One arg set for both trees. `--use-gl=disabled --disable-gpu` was tried on the game tree
# (01:42) against the `gl_factory_win.cc(63) NOTREACHED` storm and changed nothing — that
# NOTREACHED is Chromium's unreachable default in the Windows GL-surface factory, so it fires
# regardless of the implementation requested. Reverted, both because it does not help and
# because HANDOFF.md §0.4 says never `--disable-gpu`.
# FLY_CEF_ARGS (newline-separated) replaces this set. These flags were long suspected of
# causing the storm because they ask for ANGLE while WINEDLLOVERRIDES was disabling libEGL/
# libGLESv2 — but the override was the whole problem, not the flags. With the override gone
# (see below) this arg set scores CLEAN and paints. Connect also paints with no GL flags at
# all, so treat them as tunable rather than load-bearing.
if [ -n "${FLY_CEF_ARGS:-}" ]; then
  printf '%s\n' "$FLY_CEF_ARGS" > "$UC/devargs.txt"
else
cat > "$UC/devargs.txt" <<'EOF'
--no-sandbox
--in-process-gpu
--disable-gpu-compositing
--use-gl=angle
--use-angle=swiftshader-webgl
EOF
fi
# FLY_CEF_VERBOSE=1 makes Chromium say *why* GL init failed instead of only spamming the
# gl_factory_win NOTREACHED that follows it.
if [ "${FLY_CEF_VERBOSE:-0}" = "1" ]; then
  cat >> "$UC/devargs.txt" <<'EOF'
--enable-logging=stderr
--v=1
--vmodule=gl*=3,*angle*=3,*swiftshader*=3,*gpu_init*=3
EOF
fi
cp -f "$UC/devargs.txt" "$UC/testargs.txt"
cp -f "$UC/devargs.txt" "$UC/webcore_args.txt"

rm -f "$BRIDGE_HOST" /tmp/fly-stretch-epi.log 2>/dev/null || true

export WINEPREFIX="$BOTTLE"
# WINEESYNC=1 was briefly believed to be what kills CEF on a winecx-lineage
# tree (one run each: bare 0 vs esync 314k gl_factory_win NOTREACHED). It is
# not. Re-measured as a rate over 3 bare and 2 esync runs: every run storms,
# 5.9-8.2k/s, with and without esync. The original counts differed only
# because they were raw totals from a fixed 55 s window that the storm occupied
# for 49 s and 30 s respectively.
#
# Game-host default here is FLY_MSYNC=1. Left as-is because this launcher is
# shared with the frankea tree, which is the playable path.
[ "${FLY_NO_ESYNC:-0}" = "1" ] || export WINEESYNC=1
# WRITECOPY simulation is an ntdll feature and Chromium leans hard on copy-on-write pages,
# so FLY_NO_WRITECOPY=1 exists to take it out of the picture when CEF fails to init GL.
[ "${FLY_NO_WRITECOPY:-0}" = "1" ] || export WINE_SIMULATE_WRITECOPY=1
unset VK_ICD_FILENAMES || true
# Connect starts the shared wineserver, so its sync mode decides what later clients can
# use: with msync off, `fly steam launch`/`fly play` (bottle enhancedSync=msync) die at
# "msync_init Failed bootstrap_look_up". Opt in with FLY_MSYNC=1 to keep one session.
if [ "${FLY_MSYNC:-0}" = "1" ]; then
  export WINEMSYNC=1
else
  unset WINEMSYNC || true
fi
# `libEGL,libGLESv2=d` is what caused the gl_factory_win NOTREACHED storm. LO_DISABLED makes
# ntdll return STATUS_DLL_NOT_FOUND before it ever looks at the file, so Chromium's own ANGLE
# DLLs — which sit right there in the Connect directory — cannot load, GL init leaves the
# implementation as none, and the Windows GL-surface factory NOTREACHEDs forever.
# Dropping it here looked like it changed nothing for weeks because the same disable was also
# baked into the bottle's registry (AppDefaults\upc.exe, UplayWebCore.exe, UbisoftConnect.exe,
# UbisoftGameLauncher.exe). Either copy alone is enough to storm; both are removed as of
# 12 Aug 23:05. Game-host Wine sets no WINEDLLOVERRIDES at all and has no upc AppDefaults.
# The rest of the string is proven harmless: scored CLEAN with d2d1/d3d10core=d, d3d11/dxgi=b
# and d3dcompiler_47=n all still in place.
# FLY_DLLOVERRIDES replaces the whole string for one-off experiments (e.g. taking the GPTK
# d3d11/dxgi out of Chromium's GPU probe on the game tree) without touching the tree itself.
export WINEDLLOVERRIDES="${FLY_DLLOVERRIDES:-winemenubuilder.exe=d;dwrite=b;d2d1,d3d10core=d;d3d11,dxgi=b;d3dcompiler_47=n}"
export WINEDEBUG="${FLY_WINEDEBUG:--all}"

"$WS" -k 2>/dev/null || true

# `wineserver -k` only signals; upc.exe plus its six UplayWebCore children take several
# seconds to unwind, and `sleep 1` used to launch straight into that half-dead session.
# That race is what leaves CEF wedged before StartView — two renderers spinning at ~80%
# with an empty transparent splash-sized window and no StartView.cpp line ever logged.
# Wait for the prefix to be genuinely empty instead of guessing.
CONNECT_PROCS='upc\.exe|UplayWebCore\.exe|UplayService\.exe'
drain_start=$(date +%s)
for i in $(seq 1 60); do
  alive=$(pgrep -f "$CONNECT_PROCS" 2>/dev/null | wc -l | tr -d ' ')
  [ "$alive" = "0" ] && break
  # Escalate once if the polite shutdown is clearly not converging.
  if [ "$i" = "20" ]; then
    echo "drain: still $alive after 10s, sending SIGKILL"
    pkill -9 -f "$CONNECT_PROCS" 2>/dev/null || true
  fi
  sleep 0.5
done
alive=$(pgrep -f "$CONNECT_PROCS" 2>/dev/null | wc -l | tr -d ' ')
echo "drain: connect procs=$alive after $(( $(date +%s) - drain_start ))s"
if [ "$alive" != "0" ]; then
  echo "drain: WARNING launching with $alive process(es) still up — expect a CEF wedge" >&2
fi
# Same for our own wineserver: a dying one still owns the prefix socket. Only ever wait on
# the tree we are launching, never a different one (bottle isolation).
# The pattern must use the *resolved* path: `Libraries.steam` is a symlink to
# `Libraries.pre-gptk-aware.bak`, and the process cmdline shows the target, so the old
# `Libraries\.steam/...` pattern never matched and this loop always fell through.
TREE_REAL=$(cd "$TREE_DIR" && pwd -P)
for i in $(seq 1 20); do
  pgrep -f "$TREE_REAL/.*wineserver" >/dev/null 2>&1 || break
  sleep 0.5
done
sleep 1

# After wineserver -k, CEF http2 often wedges before StartView (transparent empty chrome).
# Prefer parent-native LATEST; Cocoa-era: FLY_CK_HTTP=bridge. Or set FLY_CK_HTTP to an http2 dir.
# Opt out: FLY_RESTORE_HTTP2=0
if [ "${FLY_RESTORE_HTTP2:-1}" = "1" ]; then
  CACHE="$BOTTLE/drive_c/users/ebenoelofse/AppData/Local/Ubisoft Game Launcher/cache"
  SCRATCH="$ROOT/.scratch"
  CK_SEL="${FLY_CK_HTTP:-parent}"
  case "$CK_SEL" in
    bridge|cocoa)
      CK_HTTP="$SCRATCH/checkpoint-bridge-working-LATEST/http2/http2"
      ;;
    parent|native|"")
      CK_HTTP="$SCRATCH/checkpoint-parent-native-LATEST/http2/http2"
      ;;
    *)
      CK_HTTP="$CK_SEL"
      ;;
  esac
  BAK_HTTP="$CACHE/http2.bak-20260809-2330"
  rm -rf "$CACHE/http2"
  if [ -d "$CK_HTTP" ]; then
    cp -a "$CK_HTTP" "$CACHE/http2"
    echo "http2: restored $CK_HTTP"
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
python3 - "$OUT" "$EPI_DYLIB" "$INJECT" "$BRIDGE_HOST" "$WINE" "$UC/devargs.txt" <<'PY'
import os, sys, subprocess
out, epi, inj, bridge, wine, devargs = sys.argv[1:7]
# Put DYLD_* on `env` argv — macOS SIP strips inherited DYLD_INSERT from Popen env.
opt_b = os.environ.get("FLY_OPTION_B", "0")
opt_b_flush = os.environ.get("FLY_OPTION_B_FLUSH", "1")
# Product default: parent-native shm; Cocoa inject is explicit fallback.
login_bridge = os.environ.get("PRESENT_FORCE_LOGIN_BRIDGE", "0")
surface_map = os.environ.get("FLY_SURFACE_MAP", "0")
parent_present = os.environ.get("FLY_PARENT_PRESENT", "1")
# Product default opaque/fill off; parent-native digs may set SYNC/OPAQUE=1.
force_opaque = os.environ.get("PRESENT_FORCE_OPAQUE", "0")
force_fill = os.environ.get("PRESENT_FORCE_LOGIN_FILL", "0")
force_sync = os.environ.get("PRESENT_FORCE_LOGIN_SYNC", "0")
bridge_shm = os.environ.get("FLY_BRIDGE_SHM", "1")
fast_present = os.environ.get("FLY_FAST_PRESENT", "0")
# File .bgra off by default (shm path). Cocoa fallback needs the file — auto-on if unset.
if "FLY_BRIDGE_FILE" in os.environ:
    bridge_file = os.environ["FLY_BRIDGE_FILE"]
else:
    bridge_file = "1" if login_bridge == "1" else "0"
cmd = [
    "arch", "-x86_64", "env",
]
# The epi/inject pair resolves Wine's GDI internals by pattern and patches a code cave, so on a
# tree it was not tuned against it can land in the wrong place (spy.log then shows flush_fn=0x0
# and "FAILED epi hook after wait"). FLY_NO_INJECT=1 launches Connect bare to separate
# "CEF is broken on this tree" from "our hook broke CEF on this tree".
if os.environ.get("FLY_NO_INJECT", "0") != "1":
    cmd.append(f"DYLD_INSERT_LIBRARIES={epi}:{inj}")
cmd += [
    f"STRETCHBLT_SPY_LOG={out}/spy.log",
    "FLY_STRETCH_DUMP=1",
    f"FLY_OPTION_B={opt_b}",
    f"FLY_OPTION_B_FLUSH={opt_b_flush}",
    f"FLY_SURFACE_MAP={surface_map}",
    f"FLY_PARENT_PRESENT={parent_present}",
    f"FLY_BRIDGE_SHM={bridge_shm}",
    f"FLY_BRIDGE_FILE={bridge_file}",
    f"FLY_FAST_PRESENT={fast_present}",
    f"PRESENT_FORCE_OPAQUE={force_opaque}",
    f"PRESENT_FORCE_LOGIN_FILL={force_fill}",
    f"PRESENT_FORCE_LOGIN_SYNC={force_sync}",
    f"PRESENT_FORCE_LOGIN_BRIDGE={login_bridge}",
    f"PRESENT_BRIDGE_BGRA={bridge}",
    f"PRESENT_FORCE_LOG={out}/inject.log",
    wine, "upc.exe",
]
# Connect's CEF flags come from *this* argv, not from devargs.txt — the args files are only
# read by UplayWebCore children. They were hardcoded here, so writing a per-tree devargs.txt
# changed nothing and Connect kept launching with `--use-gl=angle` on both trees. Read the
# same file the shell just wrote so one edit covers parent and children alike.
with open(devargs) as f:
    cmd += [ln.strip() for ln in f if ln.strip() and not ln.startswith("#")]
log = open(f"{out}/wine.log", "ab", buffering=0)
p = subprocess.Popen(
    cmd, env=os.environ.copy(), stdout=log, stderr=subprocess.STDOUT,
    stdin=subprocess.DEVNULL, start_new_session=True,
)
open(f"{out}/shell.pid", "w").write(str(p.pid))
print(
    f"wine_pid={p.pid} FLY_OPTION_B={opt_b} BRIDGE={login_bridge} PARENT={parent_present} "
    f"SURFACE_MAP={surface_map} SHM={bridge_shm} FILE={bridge_file} "
    f"OPAQUE={force_opaque} SYNC={force_sync} FILL={force_fill} epi={epi}"
)
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
  close=\$(rg 'Close for browser with id: 4' "\$LL" 2>/dev/null | awk -v start="\$START_EPOCH" '
    match(\$0, /[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/) {
      cmd = "date -j -f \"%Y-%m-%d %H:%M:%S\" \"" substr(\$0, RSTART, RLENGTH) "\" +%s"
      cmd | getline t; close(cmd)
      if (t+0 >= start+0) c++
    }
    END { print c+0 }')
  [ -n "\$close" ] || close=0
  blits=\$(rg -c 'LOGIN_EPI' "\$OUT/spy.log" 2>/dev/null || echo 0)
  anyepi=\$(rg -c 'ANY_EPI' "\$OUT/spy.log" 2>/dev/null || echo 0)
  optb=\$(rg -c 'OPTION_B' "\$OUT/spy.log" 2>/dev/null || echo 0)
  alive=\$(pgrep -f '[u]pc.exe|[U]playWebCore.exe' 2>/dev/null | wc -l | tr -d ' ')
  br=0; [ -f "\$BRIDGE_HOST" ] && br=\$(wc -c < "\$BRIDGE_HOST" | tr -d ' ')
  echo "[\$ts] #\$i alive=\$alive close=\$close epi=\$blits any=\$anyepi optB=\$optb bridge=\$br wins=\$wins" >> "\$OUT/monitor.txt"
  if [ "\$close" != "0" ] && echo "\$wins" | rg -q '1[0-9]{3}x'; then
    sleep 2
    screencapture -x "\$OUT/desktop.png" 2>/dev/null || true
    for j in 1 2 3 4 5 6; do
      sleep 1
      screencapture -x "\$OUT/desktop-\$j.png" 2>/dev/null || true
      bl2=\$(rg -c 'LOGIN_EPI' "\$OUT/spy.log" 2>/dev/null || echo 0)
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

# NOTE: a backgrounded "lifecycle watch" python block used to live here. It was removed
# 11 Aug because it leaked: nothing ever waited on or killed it, so every launch left a
# process behind at ~36% CPU. Four of them from four retries drove load average to 14 and
# slowed Connect's own startup (CEF start drifted 15s -> 24s), which made the very wedge
# it was measuring more likely. It also re-read the whole 1 MB launcher_log each pass and
# shelled out to `date` for every timestamped line *before* filtering, so its 90 iterations
# took ~25 min rather than ~3. If you need this telemetry again, parse timestamps in
# Python, bound it with a deadline, and kill it in a trap on exit.

echo "OUT=$OUT"
echo "Product default: parent-native shm (PARENT=1 BRIDGE=0 SHM=1 FILE=0). Cocoa fallback: PRESENT_FORCE_LOGIN_BRIDGE=1."
echo "Advance splash until hub; watch PARENT_PRESENT ok / BRIDGE_SHM (or login-bridge if Cocoa)."
