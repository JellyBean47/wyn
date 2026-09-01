#!/usr/bin/env bash
# Wyn installer: build CLI, then hash-pinned FOSS Wine (no GPTK).
#
# One command for the standard install. D3DMetal is opt-in and needs two
# flags, because it compiles Wine from source and uses Apple's Game Porting
# Toolkit under Apple's licence.
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"

GPTK_LICENCE_URL="https://developer.apple.com/download/all/?q=game%20porting%20toolkit"

WITH_D3DMETAL=0
ACCEPT_GPTK=0

usage() {
  cat <<EOF
Usage:
  ./install.sh                                          Standard install (DXMT)
  ./install.sh --with-d3dmetal --accept-gptk-licence    Also build the D3DMetal game-host

Options:
  --with-d3dmetal          After the standard install, build the FOSS winecx
                           game-host, install it, add Apple GPTK/D3DMetal from
                           your Downloads, and select D3DMetal as the renderer.
  --accept-gptk-licence    Required with --with-d3dmetal. Confirms you have read
                           and accepted Apple's Game Porting Toolkit licence:
                           $GPTK_LICENCE_URL
  -h, --help               This message.

The standard install gives you DXMT (D3D11 to Metal), which is the default
renderer and needs no compile. D3DMetal is an opt-in upgrade for D3D12-only
titles, not a replacement.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-d3dmetal) WITH_D3DMETAL=1; shift ;;
    --accept-gptk-licence|--accept-gptk-license) ACCEPT_GPTK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; echo; usage >&2; exit 1 ;;
  esac
done

# Fail before the standard install rather than after it: a user who asked for
# D3DMetal should not sit through setup.sh only to be stopped at the licence.
if [[ "$WITH_D3DMETAL" -eq 1 && "$ACCEPT_GPTK" -eq 0 ]]; then
  cat >&2 <<EOF
error: --with-d3dmetal also needs --accept-gptk-licence.

D3DMetal comes from Apple's Game Porting Toolkit. Wyn never downloads it —
you supply the DMG — and Wyn will not assume you have accepted Apple's terms.

Read the licence:
  $GPTK_LICENCE_URL

Then:
  ./install.sh --with-d3dmetal --accept-gptk-licence
EOF
  exit 1
fi

./scripts/check-environment.sh
./scripts/build.sh
./scripts/setup.sh
./scripts/install-wine-mono.sh

BIN_DIR="${HOME}/.local/bin"
mkdir -p "$BIN_DIR"
cp ".build/release/wyn" "$BIN_DIR/wyn"
chmod +x "$BIN_DIR/wyn"
ln -sfn "$BIN_DIR/wyn" "$BIN_DIR/fly"

WYN="$BIN_DIR/wyn"

if [[ "$WITH_D3DMETAL" -eq 1 ]]; then
  echo
  echo "==> D3DMetal game-host (this compiles Wine from source and takes a while)"
  ./scripts/build-foss-game-host.sh

  # Mirrors build-foss-game-host.sh so a custom build dir still resolves.
  SCRATCH="${WINECX_BUILD_DIR:-$ROOT/.scratch/winecx-gptk-build}"
  PREFIX="${WINECX_PREFIX:-$SCRATCH/prefix}"
  WINE_ROOT="$PREFIX/wine-root"

  [[ -d "$WINE_ROOT" ]] || {
    echo "error: winecx build finished but no wine-root at $WINE_ROOT" >&2
    exit 1
  }

  echo "==> installing game-host"
  "$WYN" runtime install --gptk-aware --directory "$WINE_ROOT"

  echo "==> Apple GPTK/D3DMetal"
  "$WYN" gptk install

  echo "==> selecting D3DMetal"
  "$WYN" renderer set d3dmetal
fi

echo
echo "Installed $BIN_DIR/wyn (also linked as fly)"
echo "App:               /Applications/Wyn.app"
if [[ ":${PATH}:" != *":${BIN_DIR}:"* ]]; then
  echo "Add to ~/.zshrc:  export PATH=\"${BIN_DIR}:\$PATH\""
fi
echo "Steam (optional):  wyn steam install   # silent SteamSetup, then CEF-shimmed client"
echo "Heroic:            https://heroicgameslauncher.com"
if [[ "$WITH_D3DMETAL" -eq 1 ]]; then
  echo "Renderer:          D3DMetal selected (wyn renderer set dxmt to go back)"
else
  echo "Renderer:          DXMT (default). D3DMetal: ./install.sh --with-d3dmetal --accept-gptk-licence"
fi
