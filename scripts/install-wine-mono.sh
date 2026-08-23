#!/bin/bash
# Download official Wine Mono into the installed Wine tree.
# wineboot's GUI installer hangs on first run; this is the first-run path.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
if [[ -f "$ROOT/scripts/runtime-pins.env" ]]; then
  source "$ROOT/scripts/runtime-pins.env"
fi

WINE_ROOT="${WYN_WINE_ROOT:-$HOME/Library/Application Support/com.fly.gaming/Libraries/Wine}"
MONO_VER="${WINE_MONO_VERSION:-10.4.1}"
DEST="$WINE_ROOT/share/wine/mono"
URL="https://dl.winehq.org/wine/wine-mono/${MONO_VER}/wine-mono-${MONO_VER}-x86.msi"
MSI="$DEST/wine-mono-${MONO_VER}-x86.msi"
WINE64="$WINE_ROOT/bin/wine64"

fail() { echo "error: $*" >&2; exit 1; }

if [[ ! -x "$WINE64" && ! -x "$WINE_ROOT/bin/wine" ]]; then
  fail "Wine not installed at $WINE_ROOT
Run ./scripts/setup.sh first."
fi
[[ -x "$WINE64" ]] || WINE64="$WINE_ROOT/bin/wine"

mkdir -p "$DEST"

if [[ -f "$MSI" ]]; then
  size="$(stat -f%z "$MSI" 2>/dev/null || stat -c%s "$MSI")"
  if [[ "$size" -lt 1000000 ]]; then
    rm -f "$MSI"
  fi
fi

if [[ ! -f "$MSI" ]]; then
  echo "==> Wine Mono ${MONO_VER} from WineHQ (~82 MB)"
  echo "    $URL"
  curl -fL --retry 3 -o "$MSI.partial" "$URL"
  mv "$MSI.partial" "$MSI"
else
  echo "==> already have $MSI"
fi

echo "    $(ls -lh "$MSI" | awk '{print $5}')  $MSI"
echo "wineboot will use this file instead of the hung GUI installer."

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
    *)
      fail "unknown arg: $1
Usage: $0 [--into-bottle [WINEPREFIX]]"
      ;;
  esac
  shift
done

if [[ "$INTO" -eq 1 ]]; then
  if [[ -z "$PREFIX" ]]; then
    PREFIX="$(ls -d "$HOME/Library/Containers/com.fly.gaming/Bottles/"* 2>/dev/null | head -1 || true)"
  fi
  [[ -n "$PREFIX" && -d "$PREFIX" ]] || fail "no bottle found. Pass --into-bottle /path/to/prefix"
  echo "==> msiexec /qn into $PREFIX"
  export WINEPREFIX="$PREFIX"
  export WINEDLLOVERRIDES="winemenubuilder.exe=d"
  "$WINE64" msiexec /i "$MSI" /qn
  echo "    installed"
fi
