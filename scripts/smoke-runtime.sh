#!/usr/bin/env bash
# This file is part of Wyn.
#
# Wyn is free software: you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later
# version.
#
# Smoke-test the runtime a release Wyn.app carries, installed the way a first
# launch installs it, without touching this Mac's real Wyn state.
#
#   ./scripts/smoke-runtime.sh <Wyn.dmg | Wyn.app> [--keep]
#
# Installs Runtime/ with the app's own CLI (`wyn runtime install --bundled`)
# into a throwaway HOME, boots a fresh prefix, and then measures the running
# processes rather than trusting what was deployed (see CLAUDE.md):
#
#   fonts     no "install a version of FreeType" warning on first boot
#   https     WinHTTP → schannel → GnuTLS, chain checked against the keychain
#   d3dmetal  D3D12 device, and a D3D11 device that presents; D3DMetal mapped
#   dxmt      D3D11 device through native DXMT that presents; winemetal.so mapped
#   vulkan    vulkan-1 → winevulkan → MoltenVK finds the GPU (id Tech titles)
#   sdl       a winedevice process mapped winebus and libSDL2 (controllers)
#
# Every check prints PASS or FAIL; the exit status is the number of failures.
# KNOWN lines are measured and printed but not counted: DXVK's D3D11 path
# cannot create a swapchain with the Gcenx 1.10.3 release (it ships no
# dxgi.dll, and its d3d11 rejects both Wine's and D3DMetal's DXGI) on the old
# frankea tree or this one, and no D3D11 title is verified on DXVK.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:?usage: smoke-runtime.sh <Wyn.dmg | Wyn.app> [--keep]}"
KEEP=0; [[ "${2:-}" == "--keep" ]] && KEEP=1

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wyn-smoke.XXXXXX")"
MNT=""
cleanup() {
  [[ -n "$MNT" ]] && hdiutil detach -quiet "$MNT" 2>/dev/null
  if (( KEEP )); then echo "kept: $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

case "$TARGET" in
  *.dmg)
    MNT="$WORK/mnt"; mkdir -p "$MNT"
    hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$MNT" "$TARGET" >/dev/null 2>&1 \
      || { echo "cannot mount $TARGET" >&2; exit 99; }
    APP="$MNT/Wyn.app" ;;
  *) APP="$TARGET" ;;
esac
CLI="$APP/Contents/Resources/wyn"
[[ -x "$CLI" ]] || { echo "$CLI missing" >&2; exit 99; }

failures=0
check() {  # name, condition-exit-status, detail
  if [[ "$2" -eq 0 ]]; then echo "PASS  $1  $3"; else echo "FAIL  $1  $3"; failures=$((failures + 1)); fi
}
known() {  # name, condition-exit-status, detail — measured, not counted
  if [[ "$2" -eq 0 ]]; then echo "PASS  $1  $3  (was a known failure: update this script)"; else echo "KNOWN $1  $3"; fi
}

echo "==> probes"
for p in d3d12probe d3d11probe tlsprobe vkprobe; do
  libs=()
  case "$p" in
    d3d12probe) libs=(-ld3d12 -ldxgi) ;;
    d3d11probe) libs=(-ld3d11 -ldxgi) ;;
    tlsprobe) libs=(-lwinhttp) ;;
  esac
  x86_64-w64-mingw32-gcc -O2 -o "$WORK/$p.exe" "$ROOT/Tools/probes/$p.c" ${libs[@]+"${libs[@]}"} \
    || { echo "cannot build $p" >&2; exit 99; }
done

# Wine processes start in the current directory, and DXVK writes its shader
# cache there: keep that in the throwaway directory, not in the checkout.
cd "$WORK"

echo "==> install from $APP (HOME=$WORK/home)"
export HOME="$WORK/home" CFFIXED_USER_HOME="$WORK/home"
mkdir -p "$HOME"
"$CLI" runtime install --bundled >"$WORK/install.log" 2>&1
check install $? "$(grep -m1 'D3DMetal' "$WORK/install.log")"
T="$HOME/Library/Application Support/com.fly.gaming/Libraries/Wine"
[[ -x "$T/bin/wine" ]] || { echo "no Wine at $T" >&2; exit 99; }

export WINEPREFIX="$WORK/prefix" WINEDEBUG=-all
BASE_OVERRIDES="mscoree,mshtml=;winemenubuilder.exe=d"
export WINEDLLOVERRIDES="$BASE_OVERRIDES"
sys32="$WINEPREFIX/drive_c/windows/system32"

echo "==> first boot"
"$T/bin/wine" cmd /c ver >"$WORK/boot.log" 2>&1
grep -q "Microsoft Windows" "$WORK/boot.log"; boot=$?
check boot $boot "$(grep -m1 'Microsoft Windows' "$WORK/boot.log")"
! grep -qi "install a version of FreeType" "$WORK/boot.log"
check fonts $? "(FreeType loaded)"

# Run a probe, and while it sleeps, record what its process and the device
# manager actually mapped.
run_probe() {  # label, exe, extra env...
  local label="$1" exe="$2"; shift 2
  env "$@" "$T/bin/wine" "$WORK/$exe" >"$WORK/$label.out" 2>"$WORK/$label.err" &
  local wpid=$! pid="" i
  for i in $(seq 1 60); do
    pid="$(pgrep -f "$exe" | head -1)"
    [[ -n "$pid" ]] && grep -q "D3D1[12]CreateDevice" "$WORK/$label.out" 2>/dev/null && break
    sleep 1
  done
  [[ -n "$pid" ]] && lsof -p "$pid" 2>/dev/null | awk '{print $NF}' >"$WORK/$label.maps"
  # There are several winedevice.exe processes; winebus lives in one of them.
  local dev
  for dev in $(pgrep -f winedevice.exe); do
    lsof -p "$dev" 2>/dev/null | awk '{print $NF}' >>"$WORK/winedevice.maps"
  done
  wait "$wpid"
}

echo "==> https"
"$T/bin/wine" "$WORK/tlsprobe.exe" >"$WORK/tls.out" 2>/dev/null
check https $? "$(tr '\n' ' ' <"$WORK/tls.out")"

echo "==> d3dmetal"
"$CLI" renderer set d3dmetal >/dev/null 2>&1
d3dm_env=(WINEDLLOVERRIDES="$BASE_OVERRIDES;d3d11,dxgi,d3d12,d3d10,atidxx64,nvapi64,nvngx=b"
          CX_APPLEGPTK_LIBD3DSHARED_PATH="$T/lib/external/libd3dshared.dylib"
          CX_APPLEGPT_LIBD3DSHARED_PATH="$T/lib/external/libd3dshared.dylib"
          CX_ROOT="$T" CX_GRAPHICS_BACKEND=d3dmetal)
run_probe d3dm12 d3d12probe.exe "${d3dm_env[@]}"
grep -q "D3D12CreateDevice(12_0): 0x00000000" "$WORK/d3dm12.out" && grep -q "libd3dshared" "$WORK/d3dm12.maps"
check d3dmetal-d3d12 $? "$(grep -m1 adapter "$WORK/d3dm12.out")"
run_probe d3dm11 d3d11probe.exe "${d3dm_env[@]}"
grep -q "Present x10: 0x00000000" "$WORK/d3dm11.out" && grep -q "D3DMetal" "$WORK/d3dm11.maps"
check d3dmetal-d3d11 $? "$(grep -m1 adapter "$WORK/d3dm11.out"), $(grep -m1 Present "$WORK/d3dm11.out")"

echo "==> dxmt (Wyn's deployment: native trio + winemetal in system32)"
DXMT="$T/../DXMT/x64"
cp "$DXMT/d3d11.dll" "$DXMT/dxgi.dll" "$DXMT/d3d10core.dll" "$DXMT/winemetal.dll" "$sys32/"
run_probe dxmt d3d11probe.exe WINEDLLOVERRIDES="$BASE_OVERRIDES;dxgi,d3d11,d3d10core=n,b"
grep -q "Present x10: 0x00000000" "$WORK/dxmt.out" && grep -q "winemetal.so" "$WORK/dxmt.maps"
check dxmt $? "$(grep -m1 adapter "$WORK/dxmt.out"), $(grep -m1 Present "$WORK/dxmt.out")"

echo "==> dxvk (Wyn's deployment: native d3d11/d3d10core, Wine's builtin dxgi)"
DXVK="$T/../DXVK/x64"
cp "$DXVK/d3d11.dll" "$DXVK/d3d10core.dll" "$sys32/"
cp "$T/lib/wine/x86_64-windows/dxgi.dll" "$sys32/dxgi.dll"
rm -f "$sys32/winemetal.dll"
run_probe dxvk d3d11probe.exe WINEDLLOVERRIDES="$BASE_OVERRIDES;dxgi,d3d9,d3d10core,d3d11=n,b" DXVK_ASYNC=1
grep -q "Present x10: 0x00000000" "$WORK/dxvk.out"
known dxvk-d3d11 $? "$(grep -m1 'CreateDevice' "$WORK/dxvk.out"); $(grep -m1 'not a DXVK adapter' "$WORK/dxvk.err")"

echo "==> vulkan"
"$T/bin/wine" "$WORK/vkprobe.exe" >"$WORK/vk.out" 2>"$WORK/vk.err"
grep -q "^vulkan device 0:" "$WORK/vk.out"
check vulkan $? "$(grep -m1 '^vulkan device' "$WORK/vk.out")"

echo "==> sdl"
grep -q "libSDL2" "$WORK/winedevice.maps" 2>/dev/null && grep -q "winebus.so" "$WORK/winedevice.maps"
check sdl $? "(winebus mapped libSDL2)"

"$T/bin/wineserver" -k 2>/dev/null
echo "failures: $failures"
exit "$failures"
