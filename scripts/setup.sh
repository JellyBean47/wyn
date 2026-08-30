#!/usr/bin/env bash
# Download the hash-pinned FOSS Wine tarball. Never fetches Apple GPTK.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
source "$ROOT/scripts/runtime-pins.env"

WYN="${WYN:-$ROOT/.build/release/wyn}"
CACHE="${XDG_CACHE_HOME:-$HOME/Library/Caches}/wyn"
mkdir -p "$CACHE"
TAR="$CACHE/Libraries-v${WINE_WHISKYCDN_VERSION}.tar.gz"

fail() { echo "error: $*" >&2; exit 1; }

"$ROOT/scripts/check-environment.sh"

if [[ ! -x "$WYN" ]]; then
  echo "==> wyn CLI missing; building"
  swift build -c release
  WYN="$ROOT/.build/release/wyn"
fi

echo "==> Wine runtime ${WINE_WHISKYCDN_VERSION}"
echo "    ${WINE_WHISKYCDN_URL}"

if [[ -f "$TAR" ]]; then
  echo "    using cache $TAR"
else
  echo "    downloading (~330 MB)…"
  curl -fL --retry 3 -o "$TAR.partial" "$WINE_WHISKYCDN_URL"
  mv "$TAR.partial" "$TAR"
fi

actual="$(shasum -a 256 "$TAR" | awk '{print $1}')"
if [[ "$actual" != "$WINE_WHISKYCDN_SHA256" ]]; then
  rm -f "$TAR"
  fail "SHA-256 mismatch
  expected: $WINE_WHISKYCDN_SHA256
  actual:   $actual
  Refusing to install. See DEPENDENCIES.md."
fi
echo "    hash ok"

if tar tzf "$TAR" | grep -E 'D3DMetal\.framework|libd3dshared\.dylib|libmetalirconverter\.dylib' >/dev/null; then
  fail "Tarball listing contains Apple GPTK/D3DMetal files. Refusing to unpack."
fi
echo "    no Apple GPTK markers in archive listing"

echo "==> installing into ~/Library/Application Support/com.fly.gaming/"
"$WYN" runtime install --from "$TAR"

echo
echo "FOSS Wine runtime installed (DXMT/DXVK; no D3DMetal). This is Libraries.steam rollback."
echo "Wine Mono: ./scripts/install-wine-mono.sh (or ./install.sh). wyn steam install"
echo "runs msiexec /qn before SteamSetup — do not use the hung GUI installer."
echo "D3DMetal game-host is FOSS winecx (not this tarball):"
echo "  ./scripts/build-foss-game-host.sh"
echo "  ./scripts/install-foss-game-host.sh --directory <wine-root>"
echo "GPTK 3.0 is optional and user-supplied: wyn gptk install --from <redist>"
echo "Steam client: wyn steam install"
echo "Heroic (Epic/GOG): https://heroicgameslauncher.com"
