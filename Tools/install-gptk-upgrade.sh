#!/usr/bin/env bash
# Wire a *user-provided* Apple GPTK redist or DMG into WynWine.
# Wyn never downloads GPTK. With no args, uses GPTK 3.0 from ~/Downloads.
#
# Usage:
#   Tools/install-gptk-upgrade.sh
#   Tools/install-gptk-upgrade.sh /path/to/Game_Porting_Toolkit.dmg
#   Tools/install-gptk-upgrade.sh /path/to/redist
set -euo pipefail

FLY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLY_BIN="${FLY_BIN:-$FLY_ROOT/.build/release/wyn}"

die() { echo "error: $*" >&2; exit 1; }

if [[ $# -eq 0 ]]; then
  if [[ ! -x "$FLY_BIN" ]]; then
    echo "Building wyn…"
    (cd "$FLY_ROOT" && swift build -c release)
  fi
  "$FLY_BIN" gptk install
  "$FLY_BIN" gptk status
  exit 0
fi

find_lib_root() {
  local candidate="$1"
  if [[ -f "$candidate/external/libd3dshared.dylib" ]]; then
    echo "$candidate"
  elif [[ -f "$candidate/lib/external/libd3dshared.dylib" ]]; then
    echo "$candidate/lib"
  elif [[ -f "$candidate/redist/lib/external/libd3dshared.dylib" ]]; then
    echo "$candidate/redist/lib"
  else
    return 1
  fi
}

mount_dmg() {
  local dmg="$1"
  local out
  out="$(hdiutil attach -nobrowse -readonly "$dmg" | tail -1 | awk '{$1=$2=""; print substr($0,3)}' | sed 's/[[:space:]]*$//')"
  [[ -n "$out" && -d "$out" ]] || die "failed to mount $dmg"
  echo "$out"
}

resolve_source() {
  local arg="$1"
  if [[ -f "$arg" && "$arg" == *.dmg ]]; then
    local vol
    vol="$(mount_dmg "$arg")"
    echo "Mounted: $vol" >&2
    local nested
    nested="$(find "$vol" -maxdepth 2 -name '*.dmg' 2>/dev/null | head -1 || true)"
    if [[ -n "$nested" ]]; then
      local inner
      inner="$(mount_dmg "$nested")"
      echo "Mounted nested: $inner" >&2
      find_lib_root "$inner" || find_lib_root "$inner/redist" || die "no redist/lib/external in nested DMG"
      return
    fi
    find_lib_root "$vol" || find_lib_root "$vol/redist" || die "no redist/lib/external in DMG"
    return
  fi
  if [[ -d "$arg" ]]; then
    find_lib_root "$arg" || die "no lib/external under $arg"
    return
  fi
  die "not a DMG or directory: $arg"
}

main() {
  local lib
  lib="$(resolve_source "$1")"
  local ver
  ver="$(plutil -extract CFBundleShortVersionString raw "$lib/external/D3DMetal.framework/Resources/Info.plist" 2>/dev/null || echo unknown)"
  echo "Source lib: $lib"
  echo "D3DMetal:   $ver"

  if [[ "$ver" == "2.1" || "$ver" == "2.0" || "$ver" == "1."* ]]; then
    die "Source is still D3DMetal $ver — need 3.0+ from Apple."
  fi

  if [[ ! -x "$FLY_BIN" ]]; then
    echo "Building wyn…"
    (cd "$FLY_ROOT" && swift build -c release)
  fi

  # Copy into the Wine tree only — never into the git working copy.
  "$FLY_BIN" gptk install --from "$lib"
  "$FLY_BIN" gptk status
}

main "$@"
