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
# Stage the runtime Wyn.app carries from 1.1 on, from pinned inputs, so that
# `package-dmg.sh --with-runtime` can seal it into the app.
#
#   ./scripts/stage-runtime.sh \
#     --wine-root    DIR   winecx install root from build-foss-game-host.sh
#     --wine-source  DIR   the winecx checkout it was built from (licences, VERSION)
#     --deps-prefix  DIR   build-runtime-deps.sh output the tree was built with
#     --dxvk-tarball FILE  Gcenx's DXVK-macOS release (DXVK_MACOS_* pin)
#     --dxmt-tarball FILE  3Shain's DXMT release (DXMT_* pin)
#     --mono-msi     FILE  wine-mono MSI matching the winecx pin
#     --gptk-dmg     FILE  Apple's Game_Porting_Toolkit_3.0.dmg
#     [--out DIR]          default .scratch/runtime-stage
#
# Output (DIR):
#   Libraries/            what Wyn installs into Application Support; no Apple code
#   GPTK/                 Apple's "Evaluation environment for Windows games"
#                         volume, byte for byte: License.rtf, Acknowledgements.rtf,
#                         Read Me.rtf, redist/. Wyn wires it in on first launch
#                         with the same GPTKInstaller a user's own DMG goes through.
#   licenses/             licence texts for everything in Libraries/
#   RUNTIME-MANIFEST.txt  every input, its SHA-256, and where its source is
#
# Every input is either built here from pinned source (Wine, the libraries) or
# a publisher's own release pinned by SHA-256 (DXVK, DXMT, Wine Mono, GPTK).
# Apple's files are copied, never modified, and keep Apple's signature; the
# script refuses to finish if that signature no longer verifies.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/runtime-pins.env"

fail() { echo "error: $*" >&2; exit 1; }

WINE_ROOT="" WINE_SOURCE="" DEPS_PREFIX="" DXVK_TARBALL="" DXMT_TARBALL="" MONO_MSI="" GPTK_DMG=""
OUT="$ROOT/.scratch/runtime-stage"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wine-root) WINE_ROOT="$2"; shift 2 ;;
    --wine-source) WINE_SOURCE="$2"; shift 2 ;;
    --deps-prefix) DEPS_PREFIX="$2"; shift 2 ;;
    --dxvk-tarball) DXVK_TARBALL="$2"; shift 2 ;;
    --dxmt-tarball) DXMT_TARBALL="$2"; shift 2 ;;
    --mono-msi) MONO_MSI="$2"; shift 2 ;;
    --gptk-dmg) GPTK_DMG="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,42p' "$0"; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done
for pair in "wine-root:$WINE_ROOT" "wine-source:$WINE_SOURCE" "deps-prefix:$DEPS_PREFIX" \
            "dxvk-tarball:$DXVK_TARBALL" "dxmt-tarball:$DXMT_TARBALL" \
            "mono-msi:$MONO_MSI" "gptk-dmg:$GPTK_DMG"; do
  [[ -n "${pair#*:}" ]] || fail "--${pair%%:*} is required"
  [[ -e "${pair#*:}" ]] || fail "--${pair%%:*}: ${pair#*:} does not exist"
done

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
is_macho() {
  case "$(head -c 4 "$1" | xxd -p)" in
    cffaedfe|cefaedfe|feedfacf|feedface|cafebabe|bebafeca) return 0 ;;
    *) return 1 ;;
  esac
}
pinned() {  # file, pin, what
  local got; got="$(sha256 "$1")"
  [[ "$got" == "$2" ]] || fail "$3: $(basename "$1") hashes to $got, pin is $2"
}

echo "==> checking inputs"
ntdll="$WINE_ROOT/lib/wine/x86_64-unix/ntdll.so"
[[ -f "$ntdll" ]] || fail "$ntdll missing: not a Wine install root"
grep -q CX_APPLEGPTK_LIBD3DSHARED_PATH "$ntdll" \
  || fail "ntdll.so has no CX_APPLEGPTK hook: not a winecx game-host, D3DMetal would never load"
[[ -x "$WINE_ROOT/bin/wine" ]] || fail "$WINE_ROOT/bin/wine missing"
file -b "$WINE_ROOT/bin/wine" | grep -q x86_64 || fail "bin/wine is not x86_64"

# The bundle is sealed: a symlink that leaves it dangles on every other Mac.
absolute_links="$(find "$WINE_ROOT" -type l -lname '/*' | head -5)"
[[ -z "$absolute_links" ]] || fail "absolute symlinks in the Wine tree:
$absolute_links"

# Apple's payload lives in GPTK/ and nowhere else. A Wine tree that already
# carries it would put Apple code where GPTKInstaller cannot see or replace it.
gptk_in_wine="$(find "$WINE_ROOT" \( -name D3DMetal.framework -o -name libd3dshared.dylib \
  -o -name libmetalirconverter.dylib \) | head -3)"
[[ -z "$gptk_in_wine" ]] || fail "the Wine tree already contains GPTK files:
$gptk_in_wine"

for f in LICENSE COPYING.LIB AUTHORS NOTICES.md VERSION; do
  [[ -f "$WINE_SOURCE/$f" ]] || fail "$WINE_SOURCE/$f missing: --wine-source must be the winecx checkout"
done
wine_commit="$(git -C "$WINE_SOURCE" rev-parse HEAD 2>/dev/null || echo unknown)"
[[ "$wine_commit" == "$WINECX_COMMIT" ]] \
  || fail "winecx checkout is $wine_commit, pin is $WINECX_COMMIT: the source asset would not match"
[[ -z "$(git -C "$WINE_SOURCE" status --porcelain --untracked-files=no)" ]] \
  || fail "the winecx checkout has local modifications: the source asset would not match"

# Provenance: every library in the tree must be the one build-runtime-deps.sh
# built, byte for byte — nothing borrowed from another runtime may ride along.
[[ -f "$DEPS_PREFIX/DEPS-MANIFEST.txt" ]] || fail "--deps-prefix is not build-runtime-deps.sh output"
while IFS= read -r lib; do
  name="$(basename "$lib")"
  [[ -e "$DEPS_PREFIX/lib/$name" ]] || fail "lib/$name in the Wine tree was not built by build-runtime-deps.sh"
  cmp -s "$lib" "$DEPS_PREFIX/lib/$name" || fail "lib/$name differs from the build-runtime-deps.sh copy"
done < <(find "$WINE_ROOT/lib" -maxdepth 1 -name '*.dylib' -type f)

pinned "$MONO_MSI" "$WINE_MONO_SHA256" "wine-mono $WINE_MONO_VERSION"
pinned "$GPTK_DMG" "$GPTK_DMG_SHA256" "Apple GPTK $GPTK_VERSION"
pinned "$DXVK_TARBALL" "$DXVK_MACOS_SHA256" "DXVK-macOS $DXVK_MACOS_VERSION"
pinned "$DXMT_TARBALL" "$DXMT_SHA256" "DXMT $DXMT_VERSION"

echo "==> staging into $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/Libraries" "$OUT/licenses"

# include/ is Wine's SDK. Nothing at runtime reads it, and it is 69 MB.
rsync -a --exclude '/include/' "$WINE_ROOT/" "$OUT/Libraries/Wine/"
wine="$OUT/Libraries/Wine"
[[ -e "$wine/bin/wine64" ]] || ln -s wine "$wine/bin/wine64"

# win32u.so and friends dlopen these by leaf name, and their only LC_RPATH is
# @loader_path/ — the unix directory. Unrestricted processes also fall back to
# the working directory and /usr/local/lib; a hardened one does neither. So the
# links have to be in the tree: without them FreeType, TLS and Vulkan silently
# fail to load (measured: "please install a version of FreeType" on a tree
# built before build-foss-game-host.sh grew this same loop).
unix="$wine/lib/wine/x86_64-unix"
[[ -e "$wine/lib/libvulkan.1.dylib" || ! -e "$wine/lib/libMoltenVK.dylib" ]] \
  || ln -s libMoltenVK.dylib "$wine/lib/libvulkan.1.dylib"
for name in libfreetype.6.dylib libfreetype.dylib libgnutls.30.dylib libgnutls.dylib \
            libSDL2-2.0.0.dylib libMoltenVK.dylib libvulkan.1.dylib; do
  [[ -e "$wine/lib/$name" && ! -e "$unix/$name" ]] && ln -s "../../$name" "$unix/$name"
done

# appwiz.cpl skips its hung GUI installer only when the exact MSI it wants is
# already here; WineMono.ensureDatadirPackage then has nothing to download.
mkdir -p "$wine/share/wine/mono"
install -m 0644 "$MONO_MSI" "$wine/share/wine/mono/wine-mono-$WINE_MONO_VERSION-x86.msi"

echo "==> translation layers (publishers' releases)"
layers="$(mktemp -d "${TMPDIR:-/tmp}/wyn-layers.XXXXXX")"
mkdir -p "$layers/dxvk" "$layers/dxmt"
tar -xzf "$DXVK_TARBALL" -C "$layers/dxvk"
tar -xzf "$DXMT_TARBALL" -C "$layers/dxmt"
dxvk_src="$(find "$layers/dxvk" -mindepth 1 -maxdepth 1 -type d | head -1)"
dxmt_src="$(find "$layers/dxmt" -mindepth 1 -maxdepth 1 -type d | head -1)"
for f in x64/d3d11.dll x32/d3d11.dll dxvk.conf; do
  [[ -f "$dxvk_src/$f" ]] || fail "DXVK release has no $f"
done
for f in x86_64-windows/d3d11.dll i386-windows/d3d11.dll x86_64-windows/winemetal.dll \
         i386-windows/winemetal.dll x86_64-unix/winemetal.so; do
  [[ -f "$dxmt_src/$f" ]] || fail "DXMT release has no $f"
done

mkdir -p "$OUT/Libraries/DXVK"
rsync -a "$dxvk_src/x64" "$dxvk_src/x32" "$dxvk_src/dxvk.conf" "$OUT/Libraries/DXVK/"
cp "$ROOT/Documentation/licenses/zlib-DXVK.txt" "$OUT/Libraries/DXVK/LICENSE"

# Wyn deploys DXMT's D3D trio per game, as native DLLs next to the exe. The
# release marks them "Wine builtin DLL" (16 bytes at 0x40, where a PE's DOS
# stub normally begins), and Wine never treats a builtin-marked file as native.
# Writing back the standard DOS-stub bytes gives exactly the files Wyn's DXMT
# profiles were verified with: measured 27 Sep 2026, frankea v3.1.1's trio
# differs from this release in these 16 bytes and nothing else.
nativize() {
  local f="$1"
  [[ "$(dd if="$f" bs=1 skip=64 count=16 2>/dev/null)" == "Wine builtin DLL" ]] \
    || fail "$f: expected the Wine builtin marker at 0x40"
  printf '\x0e\x1f\xba\x0e\x00\xb4\x09\xcd\x21\xb8\x01\x4c\xcd\x21\x90\x90' \
    | dd of="$f" bs=1 seek=64 count=16 conv=notrunc 2>/dev/null
}
mkdir -p "$OUT/Libraries/DXMT/x64" "$OUT/Libraries/DXMT/x32"
cp "$dxmt_src"/x86_64-windows/*.dll "$OUT/Libraries/DXMT/x64/"
cp "$dxmt_src"/i386-windows/*.dll "$OUT/Libraries/DXMT/x32/"
for arch in x64 x32; do
  for dll in d3d11.dll dxgi.dll d3d10core.dll; do
    nativize "$OUT/Libraries/DXMT/$arch/$dll"
  done
done
cp "$ROOT/Documentation/licenses/MIT-DXMT-v0.80.txt" "$OUT/Libraries/DXMT/LICENSE"
# winemetal is DXMT's bridge into Wine: a builtin PE half paired with its unixlib.
install -m 0755 "$dxmt_src/x86_64-unix/winemetal.so" "$unix/winemetal.so"
install -m 0644 "$dxmt_src/x86_64-windows/winemetal.dll" "$wine/lib/wine/x86_64-windows/winemetal.dll"
install -m 0644 "$dxmt_src/i386-windows/winemetal.dll" "$wine/lib/wine/i386-windows/winemetal.dll"
rm -rf "$layers"

wine_version="$(sed -E 's/^Wine version //' "$WINE_SOURCE/VERSION")"
IFS=. read -r v_major v_minor v_patch <<<"$wine_version"
cat > "$OUT/Libraries/WynWineVersion.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>version</key>
    <dict>
        <key>major</key><integer>${v_major:-0}</integer>
        <key>minor</key><integer>${v_minor:-0}</integer>
        <key>patch</key><integer>${v_patch:-0}</integer>
    </dict>
    <key>bundled</key><true/>
    <key>winecxCommit</key><string>$wine_commit</string>
    <key>dxvkVersion</key><string>$DXVK_MACOS_VERSION</string>
    <key>dxmtVersion</key><string>$DXMT_VERSION</string>
</dict>
</plist>
PLIST

echo "==> copying Apple's evaluation environment (unmodified)"
MNT="$(mktemp -d "${TMPDIR:-/tmp}/wyn-gptk.XXXXXX")"
detach_all() {
  for m in "$MNT/eval" "$MNT/outer"; do
    [[ -d "$m" ]] && hdiutil detach -quiet "$m" 2>/dev/null || true
  done
  rm -rf "$MNT"
}
trap detach_all EXIT
mkdir -p "$MNT/outer" "$MNT/eval"
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$MNT/outer" "$GPTK_DMG" >/dev/null
eval_dmg="$(find "$MNT/outer" -maxdepth 1 -name 'Evaluation environment for Windows games*.dmg' | head -1)"
[[ -n "$eval_dmg" ]] || fail "no 'Evaluation environment for Windows games' image inside $GPTK_DMG"
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$MNT/eval" "$eval_dmg" >/dev/null
# ditto keeps the framework's symlinks, modes and embedded signatures as-is.
ditto "$MNT/eval" "$OUT/GPTK"
rm -rf "$OUT/GPTK/.fseventsd" "$OUT/GPTK/.Trashes" "$OUT/GPTK/.DS_Store"
eval_name="$(basename "$eval_dmg")"
eval_sha="$(sha256 "$eval_dmg")"
detach_all
trap - EXIT

ext="$OUT/GPTK/redist/lib/external"
for code in "$ext/D3DMetal.framework" "$ext/libd3dshared.dylib"; do
  codesign --verify --strict -R="anchor apple" "$code" \
    || fail "$code no longer carries Apple's own signature"
done
d3dm_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$ext/D3DMetal.framework/Versions/A/Resources/version.plist")"
[[ "$d3dm_version" == "$GPTK_VERSION" ]] || fail "D3DMetal is $d3dm_version, pin is $GPTK_VERSION"

echo "==> licences"
lic="$OUT/licenses"
mkdir -p "$lic/wine" "$lic/dxvk" "$lic/dxmt" "$lic/apple-gptk" "$lic/libraries"
for f in LICENSE COPYING.LIB AUTHORS NOTICES.md VERSION; do
  cp "$WINE_SOURCE/$f" "$lic/wine/$f"
done
cp "$OUT/Libraries/DXVK/LICENSE" "$lic/dxvk/LICENSE"
cp "$OUT/Libraries/DXMT/LICENSE" "$lic/dxmt/LICENSE"
cp "$OUT/GPTK/License.rtf" "$OUT/GPTK/Acknowledgements.rtf" "$lic/apple-gptk/"
ditto "$DEPS_PREFIX/share/licenses" "$lic/libraries"
cp "$DEPS_PREFIX/DEPS-MANIFEST.txt" "$lic/libraries/"

# Where the corresponding source is. LGPL-2.1 §4 wants it offered from the
# same place as the binaries: the GitHub release that carries this image, as
# the archive scripts/package-sources.sh writes.
wyn_version="$(sed -n 's/.*MARKETING_VERSION = \([0-9.]*\);.*/\1/p' "$ROOT/Wyn.xcodeproj/project.pbxproj" | head -1)"
cat > "$lic/SOURCE.txt" <<SOURCE
Wyn $wyn_version carries Wine (winecx $wine_commit), GnuTLS and the libraries it
uses, and Wine Mono under the LGPL, and DXMT, DXVK, FreeType, libpng, SDL2 and
MoltenVK under permissive licences. Their complete corresponding source is
published on the same release page as this app's disk image, as
Wyn-$wyn_version-runtime-source.tar:

  https://github.com/JellyBean47/wyn/releases/tag/v$wyn_version

Wyn's own source (GPL-3.0-or-later): https://github.com/JellyBean47/wyn

Apple's Game Porting Toolkit files in GPTK/ are Apple's proprietary software,
redistributed unmodified and free of charge under Apple's licence
(GPTK/License.rtf, GPTK/Acknowledgements.rtf). They have no source here.
SOURCE

echo "==> manifest"
macho_count=0
while IFS= read -r f; do
  is_macho "$f" && macho_count=$((macho_count + 1))
done < <(find "$OUT/Libraries" -type f)
{
  echo "Wyn bundled runtime — staged $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "Every binary below is redistributed by Wyn. The LGPL parts oblige Wyn to"
  echo "offer their exact corresponding source from the same place as the download;"
  echo "scripts/package-sources.sh builds that archive from these same pins."
  echo
  echo "wine        winecx $wine_commit ($wine_version)  LGPL-2.1-or-later"
  echo "            built by scripts/build-foss-game-host.sh from the pinned commit"
  echo "libraries   built by scripts/build-runtime-deps.sh (see licenses/libraries/DEPS-MANIFEST.txt)"
  echo "dxvk        $DXVK_MACOS_SHA256  $(basename "$DXVK_TARBALL")  zlib"
  echo "            $DXVK_MACOS_URL"
  echo "dxmt        $DXMT_SHA256  $(basename "$DXMT_TARBALL")  MIT"
  echo "            $DXMT_URL"
  echo "            d3d11/dxgi/d3d10core: builtin marker at 0x40 replaced by the DOS stub (native variant)"
  echo "wine-mono   $WINE_MONO_SHA256  wine-mono-$WINE_MONO_VERSION-x86.msi  LGPL/MIT, MS-PL, zlib (WineHQ)"
  echo "apple-gptk  $GPTK_DMG_SHA256  $(basename "$GPTK_DMG")  Apple SLA EA18380, non-commercial redistribution"
  echo "            $eval_sha  $eval_name (copied whole into GPTK/)"
  echo "            D3DMetal $d3dm_version, Apple-signed, unmodified"
  echo
  echo "Libraries in Libraries/Wine/lib:"
  find "$OUT/Libraries/Wine/lib" -maxdepth 1 -type f -name '*.dylib' -exec basename {} \; | sort | sed 's/^/  /'
  echo
  echo "Mach-O files to sign: $macho_count"
} > "$OUT/RUNTIME-MANIFEST.txt"

du -sh "$OUT/Libraries" "$OUT/GPTK" | sed 's/^/    /'
echo "    $macho_count Mach-O files in Libraries/ to sign"
echo "Staged: $OUT"
echo "Next:   ./scripts/package-dmg.sh --with-runtime \"$OUT\" [--notarize]"
