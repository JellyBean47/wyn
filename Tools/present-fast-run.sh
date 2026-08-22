#!/bin/bash
# Fast present path: faithful blit replay + dirty-rect present (FLY4).
#
# Producer (gpu proc) replays every window-targeted StretchBlt 1:1 into a shared
# shadow surface and unions a dirty rect. Parent (upc) grabs-and-clears that rect
# and SetDIBits only those pixels — no full-frame copies, no size/pin gating,
# no 10 Hz cap. Same shape as Wine's window_surface + window_surface_flush.
#
# Known-good Cocoa checkpoint launcher is untouched:
#   bash Tools/present-win32u-bridge-run.sh
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

export FLY_FAST_PRESENT=1
export FLY_PARENT_PRESENT=1
export PRESENT_FORCE_LOGIN_BRIDGE=0   # no Cocoa pixel inject
export FLY_BRIDGE_SHM=0               # old full-frame transports off
export FLY_BRIDGE_FILE=0
export FLY_OPTION_B=0
export FLY_SURFACE_MAP=0
export FLY_EPI_DYLIB="${FLY_EPI_DYLIB:-$ROOT/Tools/bin/fly_stretch_epi_bridge.fast.dylib}"
export FLY_RESTORE_HTTP2="${FLY_RESTORE_HTTP2:-1}"
export FLY_CK_HTTP="${FLY_CK_HTTP:-bridge}"

# The FLY4 surface is shm_open(O_CREAT) and macOS keeps such objects until they are
# unlinked or the machine reboots. Drop the name so this run gets a virgin segment:
# a previous run killed mid-frame leaves a dirty rect that upc would paint into
# whatever inherited that HWND, or a lock held by a dead process that silently kills
# every present for the whole session. Unlinking here is safe even while the old
# processes live — their existing mapping stays valid and simply becomes unreachable.
python3 -c 'import ctypes,ctypes.util
ctypes.CDLL(ctypes.util.find_library("c")).shm_unlink(b"/fly-upc-stretch-bridge4")' 2>/dev/null || true

exec bash "$ROOT/Tools/present-parent-native-run.sh"
