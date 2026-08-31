#!/usr/bin/env bash
# Compile first-party present helpers into Tools/bin (gitignored).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/Tools/bin"
mkdir -p "$BIN"

clang -arch x86_64 -dynamiclib -O2 \
  -o "$BIN/fly_stretch_epi_bridge.fast.dylib" \
  "$ROOT/Tools/fly_stretch_epi_bridge.c"

clang -arch x86_64 -dynamiclib -O2 -fobjc-arc -framework Foundation -framework AppKit -framework QuartzCore \
  -o "$BIN/present_force_inject.dylib" \
  "$ROOT/Tools/present_force_inject.m"

clang -arch x86_64 -dynamiclib -O2 \
    -o "$BIN/winemac_rtld_global.dylib" \
    "$ROOT/Tools/winemac_rtld_global.c"

# Steam CEF: --in-process-gpu so login HWND is not black. Not committed.
if ! command -v x86_64-w64-mingw32-gcc >/dev/null; then
  echo "error: x86_64-w64-mingw32-gcc missing — cannot build steamwebhelper_shim.exe" >&2
  echo "  brew install mingw-w64" >&2
  exit 1
fi
x86_64-w64-mingw32-gcc -O2 -mwindows \
    -o "$BIN/steamwebhelper_shim.exe" \
    "$ROOT/Tools/steamwebhelper_shim.c"
if [[ ! -s "$BIN/steamwebhelper_shim.exe" ]]; then
  echo "error: steamwebhelper_shim.exe was not produced" >&2
  exit 1
fi

# Names StorefrontLauncher / Connect look for.
cp -f "$BIN/fly_stretch_epi_bridge.fast.dylib" "$BIN/fly_stretch_epi_bridge.dylib" 2>/dev/null || true

echo "Helpers → $BIN"
ls -lh "$BIN"/fly_stretch_epi_bridge*.dylib "$BIN"/present_force_inject.dylib "$BIN"/winemac_rtld_global.dylib "$BIN"/steamwebhelper_shim.exe
