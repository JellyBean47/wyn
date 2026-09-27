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
# Build the corresponding-source archive a release publishes next to Wyn.dmg.
#
#   ./scripts/package-sources.sh \
#     --wine-source  DIR   the winecx checkout the runtime was built from
#     --deps-sources DIR   build-runtime-deps.sh's verified tarballs
#     --mono-source  FILE  WineHQ's wine-mono-<version>-src.tar.xz
#     --dxmt-source  FILE  DXMT's source archive for the pinned tag
#     --dxvk-source  FILE  DXVK-macOS's source archive for the pinned tag
#     [--out FILE]         default .scratch/Wyn-<version>-runtime-source.tar
#
# The runtime's LGPL parts — Wine, the GnuTLS stack, Wine Mono — must have their
# exact source offered from the same place as the binaries (LGPL-2.1 §4, the
# same for LGPL-3 via GPL-3 §6). Pointing at upstream does not discharge that:
# branches get deleted and mirrors move. This archive is the offer, and every
# piece in it is checked against the same pins the runtime was built from.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/runtime-pins.env"
# shellcheck disable=SC1091
source "$ROOT/scripts/runtime-deps.env"

fail() { echo "error: $*" >&2; exit 1; }
field() { local IFS='|'; read -r -a parts <<<"$1"; echo "${parts[$2]}"; }
sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

WINE_SOURCE="" DEPS_SOURCES="" MONO_SOURCE="" DXMT_SOURCE="" DXVK_SOURCE="" OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wine-source) WINE_SOURCE="$2"; shift 2 ;;
    --deps-sources) DEPS_SOURCES="$2"; shift 2 ;;
    --mono-source) MONO_SOURCE="$2"; shift 2 ;;
    --dxmt-source) DXMT_SOURCE="$2"; shift 2 ;;
    --dxvk-source) DXVK_SOURCE="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,31p' "$0"; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done
for pair in "wine-source:$WINE_SOURCE" "deps-sources:$DEPS_SOURCES" "mono-source:$MONO_SOURCE" \
            "dxmt-source:$DXMT_SOURCE" "dxvk-source:$DXVK_SOURCE"; do
  [[ -n "${pair#*:}" ]] || fail "--${pair%%:*} is required"
  [[ -e "${pair#*:}" ]] || fail "--${pair%%:*}: ${pair#*:} does not exist"
done

version="$(sed -n 's/.*MARKETING_VERSION = \([0-9.]*\);.*/\1/p' "$ROOT/Wyn.xcodeproj/project.pbxproj" | head -1)"
OUT="${OUT:-$ROOT/.scratch/Wyn-$version-runtime-source.tar}"

echo "==> checking"
commit="$(git -C "$WINE_SOURCE" rev-parse HEAD)"
[[ "$commit" == "$WINECX_COMMIT" ]] || fail "winecx checkout is $commit, pin is $WINECX_COMMIT"
[[ -z "$(git -C "$WINE_SOURCE" status --porcelain --untracked-files=no)" ]] \
  || fail "the winecx checkout has local modifications"
tree="$(git -C "$WINE_SOURCE" rev-parse "$commit^{tree}")"

[[ "$(sha256 "$MONO_SOURCE")" == "$WINE_MONO_SOURCE_SHA256" ]] \
  || fail "$(basename "$MONO_SOURCE") does not match WINE_MONO_SOURCE_SHA256"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/wyn-sources.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
top="Wyn-$version-runtime-source"
mkdir -p "$STAGE/$top"/{wine,libraries,wine-mono,dxmt,dxvk,build}

echo "==> winecx $commit"
git -C "$WINE_SOURCE" archive --format=tar --prefix="winecx-$commit/" "$commit" \
  | xz -T0 -6 > "$STAGE/$top/wine/winecx-$commit.tar.xz"

echo "==> libraries"
for spec in "$DEP_GMP" "$DEP_NETTLE" "$DEP_TASN1" "$DEP_GNUTLS" "$DEP_LIBPNG" "$DEP_FREETYPE" "$DEP_SDL2"; do
  file="$DEPS_SOURCES/$(basename "$(field "$spec" 2)")"
  [[ -f "$file" ]] || fail "$file missing: run scripts/build-runtime-deps.sh"
  [[ "$(sha256 "$file")" == "$(field "$spec" 3)" ]] || fail "$(basename "$file") does not match its pin"
  cp "$file" "$STAGE/$top/libraries/"
done

cp "$MONO_SOURCE" "$STAGE/$top/wine-mono/"
cp "$DXMT_SOURCE" "$STAGE/$top/dxmt/"
cp "$DXVK_SOURCE" "$STAGE/$top/dxvk/"
for f in build-foss-game-host.sh build-runtime-deps.sh stage-runtime.sh sign-runtime.sh \
         package-sources.sh runtime-pins.env runtime-deps.env; do
  cp "$ROOT/scripts/$f" "$STAGE/$top/build/"
done

cat > "$STAGE/$top/README.md" <<README
# Wyn $version — corresponding source for the bundled runtime

Wyn.app $version carries a Wine runtime in \`Contents/SharedSupport/Runtime\`.
This archive is the source of every open-source binary in it, published next to
the release image as the LGPL requires.

| Directory | What | Licence |
| --- | --- | --- |
| \`wine/\` | winecx at \`$commit\` (CodeWeavers' CrossOver 26.3 Wine changes on WineHQ 11.15), exactly the tree the runtime was built from | LGPL-2.1-or-later |
| \`libraries/\` | GMP, Nettle, libtasn1, GnuTLS, libpng, FreeType, SDL2: the upstream release tarballs, unmodified | see each |
| \`wine-mono/\` | WineHQ's source for \`wine-mono-$WINE_MONO_VERSION-x86.msi\`, which Wyn ships unmodified | LGPL/MIT, MS-PL, zlib |
| \`dxmt/\` | DXMT $DXMT_VERSION source (the binaries are 3Shain's release) | MIT |
| \`dxvk/\` | DXVK-macOS $DXVK_MACOS_VERSION source (the binaries are Gcenx's release) | zlib |
| \`build/\` | the scripts and pins that turn all of the above into \`Runtime/\` | GPL-3.0-or-later |

MoltenVK $(field "$DEP_MOLTENVK" 1) is Khronos' own binary release (Apache-2.0):
$(field "$DEP_MOLTENVK" 2).
Apple's Game Porting Toolkit files in \`Runtime/GPTK\` are Apple's proprietary
software, redistributed unmodified under Apple's licence; they have no source here.

## Checking the Wine tree

A git tree hash covers every file's bytes and mode, so this proves the archive
is the pinned commit exactly:

    tar -xJf wine/winecx-$commit.tar.xz
    cd winecx-$commit && git init -q && git add -A -f && git write-tree
    # must print $tree

## Rebuilding

\`build/build-runtime-deps.sh\` builds \`libraries/\`;
\`build/build-foss-game-host.sh\` builds Wine against them
(\`WINECX_DEPS_PREFIX\`); \`build/stage-runtime.sh\` assembles \`Runtime/\`.
The exact configure flags are in those scripts.
README

echo "==> $OUT"
mkdir -p "$(dirname "$OUT")"
# The pieces are compressed already; the outer tar only bundles them.
tar -cf "$OUT" -C "$STAGE" "$top"
du -h "$OUT" | cut -f1 | sed 's/^/    /'
echo "    $(sha256 "$OUT")"
