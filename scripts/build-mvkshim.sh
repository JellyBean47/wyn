#!/usr/bin/env bash
# This file is part of Wyn.
#
# Wyn is free software: you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later
# version.
#
# Wyn is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# Wyn. If not, see https://www.gnu.org/licenses/.
#
# Build fly-mvkshim into Tools/bin (gitignored). Separate from
# build-helpers.sh because that script requires mingw-w64 for the Steam CEF
# shim, and this one needs nothing but clang — a user installing a Vulkan
# title should not need a Windows cross-compiler.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/Tools/bin"
SRC="$ROOT/Tools/fly_mvkshim.c"
OUT="$BIN/fly_mvkshim.dylib"

mkdir -p "$BIN"
[[ -f "$SRC" ]] || { echo "error: missing $SRC" >&2; exit 1; }

# Universal: Wine runs the x86_64 side, so that slice is the one winevulkan
# loads, but the arm64 slice costs nothing and lets the shim be inspected and
# tested natively.
#
# The install name must be @rpath/libMoltenVK.dylib: the shim is installed
# *as* libMoltenVK.dylib, and winevulkan dlopens it under that name.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for arch in x86_64 arm64; do
  clang -arch "$arch" -dynamiclib -O2 -Wall -Wextra \
    -install_name "@rpath/libMoltenVK.dylib" \
    -o "$TMP/fly_mvkshim.$arch.dylib" \
    "$SRC"
done

lipo -create -output "$OUT" "$TMP/fly_mvkshim.x86_64.dylib" "$TMP/fly_mvkshim.arm64.dylib"

# The shim must export exactly the Vulkan entry points it interposes and
# nothing else: an extra export would shadow a real MoltenVK function with a
# symbol that forwards nowhere.
expected="_vkCreateDevice
_vkGetDeviceProcAddr
_vkGetInstanceProcAddr
_vkGetPhysicalDeviceFeatures
_vkGetPhysicalDeviceFeatures2
_vkGetPhysicalDeviceFeatures2KHR
_vk_icdGetInstanceProcAddr
_vk_icdGetPhysicalDeviceProcAddr
_vk_icdNegotiateLoaderICDInterfaceVersion"

actual="$(nm -gU "$OUT" 2>/dev/null | awk '{print $3}' | grep -E '^_' | sort -u)"
if [[ "$actual" != "$(printf '%s\n' "$expected" | sort -u)" ]]; then
  echo "error: unexpected export list" >&2
  diff <(printf '%s\n' "$expected" | sort -u) <(printf '%s\n' "$actual") >&2 || true
  exit 1
fi

echo "fly-mvkshim → $OUT"
lipo -info "$OUT"
ls -l "$OUT"
