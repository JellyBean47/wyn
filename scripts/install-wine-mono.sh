#!/bin/bash
# Stage official WineHQ Mono into the live Wine datadir and optional bottle.
# winecx addons.c only skips the hung GUI when wine-mono-11.2.0-x86.msi is
# already in share/wine/mono/. frankea Wine 11.0 wants 10.4.1. Cache lives in
# ~/Library/Caches/wyn so replacing Libraries/ with FOSS winecx can restore it.
# wyn steam install also runs msiexec /qn before SteamSetup.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
if [[ -f "$ROOT/scripts/runtime-pins.env" ]]; then
  source "$ROOT/scripts/runtime-pins.env"
fi

WINE_ROOT="${WYN_WINE_ROOT:-$HOME/Library/Application Support/com.fly.gaming/Libraries/Wine}"
CACHE_DIR="${HOME}/Library/Caches/wyn"
WINE64="$WINE_ROOT/bin/wine64"
CX_VER="${WINE_MONO_VERSION:-11.2.0}"
CX_SHA="${WINE_MONO_SHA256:-b4525679e7da30d4658ceb85739cbc55c771791054abbb4b3152fe96ded0b897}"
FR_VER="${WINE_MONO_FRANKEA_VERSION:-10.4.1}"
FR_SHA="${WINE_MONO_FRANKEA_SHA256:-071f4b2887e1c97a11d791ff3d65be9429eed6dec4c2708888bfd546ba358e23}"

fail() { echo "error: $*" >&2; exit 1; }

ntdll_has_hook() {
  local wine_root="$1"
  local f
  for f in \
    "$wine_root/lib/wine/x86_64-unix/ntdll.so" \
    "$wine_root/lib64/wine/x86_64-unix/ntdll.so"
  do
    [[ -f "$f" ]] || continue
    if grep -a -q "CX_APPLEGPTK_LIBD3DSHARED_PATH" "$f"; then
      return 0
    fi
  done
  return 1
}

sha256_of() {
  shasum -a 256 "$1" | awk '{print $1}'
}

INTO=0
PREFIX=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --into-bottle)
      INTO=1
      if [[ "${2:-}" != "" && "${2:-}" != --* ]]; then
        PREFIX="$2"
        shift
      fi
      ;;
    -h|--help)
      echo "Usage: $0 [--into-bottle [WINEPREFIX]]"
      echo "Downloads the WineHQ MSI matching live Libraries/Wine into"
      echo "~/Library/Caches/wyn and share/wine/mono/."
      echo "--into-bottle runs msiexec /qn (needed if the GUI already appeared)."
      exit 0
      ;;
    *)
      fail "unknown arg: $1
Usage: $0 [--into-bottle [WINEPREFIX]]"
      ;;
  esac
  shift
done

if [[ ! -x "$WINE64" && ! -x "$WINE_ROOT/bin/wine" ]]; then
  fail "Wine not installed at $WINE_ROOT
Run ./scripts/setup.sh first."
fi
[[ -x "$WINE64" ]] || WINE64="$WINE_ROOT/bin/wine"

if ntdll_has_hook "$WINE_ROOT"; then
  MONO_VER="$CX_VER"
  MONO_SHA="$CX_SHA"
else
  MONO_VER="$FR_VER"
  MONO_SHA="$FR_SHA"
fi

DEST="$WINE_ROOT/share/wine/mono"
URL="https://dl.winehq.org/wine/wine-mono/${MONO_VER}/wine-mono-${MONO_VER}-x86.msi"
CACHE="$CACHE_DIR/wine-mono-${MONO_VER}-x86.msi"
MSI="$DEST/wine-mono-${MONO_VER}-x86.msi"

mkdir -p "$CACHE_DIR" "$DEST"

verify() {
  local file="$1"
  local got
  got="$(sha256_of "$file")"
  if [[ "$got" != "$MONO_SHA" ]]; then
    fail "Wine Mono SHA-256 mismatch for $file
expected $MONO_SHA
got      $got
See DEPENDENCIES.md."
  fi
}

stage_from() {
  local src="$1"
  verify "$src"
  if [[ -f "$MSI" ]]; then
    if [[ "$(sha256_of "$MSI")" == "$MONO_SHA" ]]; then
      return 0
    fi
    rm -f "$MSI"
  fi
  cp "$src" "$MSI"
  verify "$MSI"
}

if [[ -f "$CACHE" ]]; then
  if [[ "$(sha256_of "$CACHE")" != "$MONO_SHA" ]]; then
    rm -f "$CACHE"
  fi
fi

if [[ ! -f "$CACHE" ]]; then
  echo "==> Wine Mono ${MONO_VER} from WineHQ"
  echo "    $URL"
  curl -fL --retry 3 -o "$CACHE.partial" "$URL"
  verify "$CACHE.partial"
  mv "$CACHE.partial" "$CACHE"
else
  echo "==> cache hit $CACHE"
  verify "$CACHE"
fi

stage_from "$CACHE"
echo "    $(ls -lh "$MSI" | awk '{print $5}')  $MSI"
echo "    wineboot uses this file; wyn steam install also runs msiexec /qn."

if [[ "$INTO" -eq 1 ]]; then
  if [[ -z "$PREFIX" ]]; then
    shopt -s nullglob
    bottles=( "$HOME/Library/Containers/com.fly.gaming/Bottles/"* )
    shopt -u nullglob
    PREFIX="${bottles[0]:-}"
  fi
  [[ -n "$PREFIX" && -d "$PREFIX" ]] || fail "no bottle found. Pass --into-bottle /path/to/prefix"
  echo "==> msiexec /qn into $PREFIX"
  export WINEPREFIX="$PREFIX"
  export WINEESYNC=1
  export WINEMSYNC=1
  export WINEDEBUG="-all"
  export WINEDLLOVERRIDES="winemenubuilder.exe=d"
  "$WINE64" msiexec /i "$MSI" /qn
  echo "    installed"
fi
