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
INSTALL_MISSING_TOOLS=0

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
  --install-missing-tools  Let Wyn run 'brew install' for build tools it needs
                           and cannot find (ccache, mingw-w64). Without this,
                           Wyn prints the brew command and stops. Wyn never runs
                           brew unless you ask, and never installs Homebrew.
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
    --install-missing-tools) INSTALL_MISSING_TOOLS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; echo; usage >&2; exit 1 ;;
  esac
done

if [[ "$INSTALL_MISSING_TOOLS" -eq 1 && "$WITH_D3DMETAL" -eq 0 ]]; then
  echo "note: --install-missing-tools does nothing without --with-d3dmetal." >&2
  echo "      The standard install needs no extra build tools." >&2
fi

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

# check-environment.sh covers the standard install. The game-host build needs
# more than that, and it runs LAST — so without this a user would build the
# CLI, download ~317 MB of Wine and install Wine Mono before being told to
# brew install ccache. Check the extra tools now, while nothing has happened.
if [[ "$WITH_D3DMETAL" -eq 1 ]]; then
  missing=()
  command -v ccache >/dev/null || missing+=("ccache")
  command -v i686-w64-mingw32-gcc >/dev/null || missing+=("mingw-w64")
  command -v x86_64-w64-mingw32-gcc >/dev/null || missing+=("mingw-w64")

  if [[ ${#missing[@]} -gt 0 ]]; then
    # Same package can be named twice above (mingw-w64 ships both compilers).
    unique=$(printf '%s\n' "${missing[@]}" | sort -u | tr '\n' ' ')
    packages="${unique% }"

    if [[ "$INSTALL_MISSING_TOOLS" -eq 0 ]]; then
      cat >&2 <<EOF
error: --with-d3dmetal needs tools this Mac does not have.

Missing: $packages

Install them:
  brew install $packages

Then re-run:
  ./install.sh --with-d3dmetal --accept-gptk-licence

Or let Wyn install them for you:
  ./install.sh --with-d3dmetal --accept-gptk-licence --install-missing-tools

The standard install (./install.sh, DXMT) does not need these.
EOF
      exit 1
    fi

    # Opted in. Wyn still never installs Homebrew itself — that is a large,
    # sudo-requiring change to someone's machine and not ours to make.
    if ! command -v brew >/dev/null; then
      cat >&2 <<EOF
error: --install-missing-tools needs Homebrew, which is not installed.

Wyn will not install Homebrew for you. Get it from:
  https://brew.sh

Then either:
  brew install $packages
  ./install.sh --with-d3dmetal --accept-gptk-licence
EOF
      exit 1
    fi

    echo "==> brew install $packages  (--install-missing-tools)"
    echo "    mingw-w64 is a full GCC toolchain; this can take several minutes."
    # shellcheck disable=SC2086
    brew install $packages

    # Trust the tools, not the exit code: a formula can succeed while leaving
    # nothing on PATH (already-installed-but-unlinked is the common one).
    still_missing=()
    command -v ccache >/dev/null || still_missing+=("ccache")
    command -v i686-w64-mingw32-gcc >/dev/null || still_missing+=("i686-w64-mingw32-gcc")
    command -v x86_64-w64-mingw32-gcc >/dev/null || still_missing+=("x86_64-w64-mingw32-gcc")

    if [[ ${#still_missing[@]} -gt 0 ]]; then
      cat >&2 <<EOF
error: brew finished but these are still not on PATH:
$(printf '  %s\n' "${still_missing[@]}")

If Homebrew says they are installed, they may just need linking:
  brew link ccache mingw-w64
Check that Homebrew's bin directory is on your PATH, then re-run.
EOF
      exit 1
    fi
  fi

  arch -x86_64 /usr/bin/true >/dev/null 2>&1 || {
    echo "error: --with-d3dmetal needs Rosetta 2 (the Wine unix half is x86_64)." >&2
    echo "  softwareupdate --install-rosetta" >&2
    exit 1
  }
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
echo "Check setup:       ./scripts/doctor.sh"
echo "Steam (optional):  wyn steam install   # silent SteamSetup, then CEF-shimmed client"
echo "Heroic:            https://heroicgameslauncher.com"
if [[ "$WITH_D3DMETAL" -eq 1 ]]; then
  echo "Renderer:          D3DMetal selected (wyn renderer set dxmt to go back)"
else
  echo "Renderer:          DXMT (default). D3DMetal: ./install.sh --with-d3dmetal --accept-gptk-licence"
fi
