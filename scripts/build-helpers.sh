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

# Names StorefrontLauncher / Connect look for.
cp -f "$BIN/fly_stretch_epi_bridge.fast.dylib" "$BIN/fly_stretch_epi_bridge.dylib" 2>/dev/null || true

echo "Helpers → $BIN"
ls -lh "$BIN"/fly_stretch_epi_bridge*.dylib "$BIN"/present_force_inject.dylib "$BIN"/winemac_rtld_global.dylib
