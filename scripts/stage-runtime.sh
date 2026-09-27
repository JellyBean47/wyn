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
#     --wine-root   DIR   winecx install root (bin/ lib/ share/), GPTK-free
#     --wine-source DIR   the winecx checkout it was built from (licences, VERSION)
#     --dxvk        DIR   DXVK payload (x32/ x64/)
#     --dxmt        DIR   DXMT payload (x32/ x64/ LICENSE)
#     --winemetal   FILE  DXMT's unix half, installed as lib/wine/x86_64-unix/winemetal.so
#     --mono-msi    FILE  wine-mono MSI matching the winecx pin
#     --gptk-dmg    FILE  Apple's Game_Porting_Toolkit_3.0.dmg
#     [--out DIR]         default .scratch/runtime-stage
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
# Apple's files are copied, never modified, and keep Apple's signature. The
# script refuses to finish if that signature no longer verifies.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/runtime-pins.env"

fail() { echo "error: $*" >&2; exit 1; }

WINE_ROOT="" WINE_SOURCE="" DXVK="" DXMT="" WINEMETAL="" MONO_MSI="" GPTK_DMG=""
OUT="$ROOT/.scratch/runtime-stage"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wine-root) WINE_ROOT="$2"; shift 2 ;;
    --wine-source) WINE_SOURCE="$2"; shift 2 ;;
    --dxvk) DXVK="$2"; shift 2 ;;
    --dxmt) DXMT="$2"; shift 2 ;;
    --winemetal) WINEMETAL="$2"; shift 2 ;;
    --mono-msi) MONO_MSI="$2"; shift 2 ;;
    --gptk-dmg) GPTK_DMG="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done
for pair in "wine-root:$WINE_ROOT" "wine-source:$WINE_SOURCE" "dxvk:$DXVK" "dxmt:$DXMT" \
            "winemetal:$WINEMETAL" "mono-msi:$MONO_MSI" "gptk-dmg:$GPTK_DMG"; do
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
if [[ "$wine_commit" != "$WINECX_COMMIT" ]]; then
  echo "warning: winecx checkout is $wine_commit, pin is $WINECX_COMMIT" >&2
  echo "         the corresponding-source tarball must be cut from $wine_commit" >&2
fi

mono_sha="$(sha256 "$MONO_MSI")"
[[ "$mono_sha" == "$WINE_MONO_SHA256" ]] \
  || fail "wine-mono MSI hash $mono_sha != pin $WINE_MONO_SHA256 (WINE_MONO_VERSION $WINE_MONO_VERSION)"

gptk_sha="$(sha256 "$GPTK_DMG")"
[[ "$gptk_sha" == "$GPTK_DMG_SHA256" ]] \
  || fail "GPTK image hash $gptk_sha != pin $GPTK_DMG_SHA256. Only Apple's GPTK $GPTK_VERSION image is accepted."

for payload in "$DXVK" "$DXMT"; do
  [[ -f "$payload/x64/d3d11.dll" && -f "$payload/x32/d3d11.dll" ]] \
    || fail "$payload is missing x64/ or x32/ d3d11.dll"
done
[[ -f "$DXMT/LICENSE" ]] || fail "$DXMT/LICENSE missing"
is_macho "$WINEMETAL" || fail "$WINEMETAL is not Mach-O"

echo "==> staging into $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/Libraries" "$OUT/licenses"

# include/ is Wine's SDK. Nothing at runtime reads it, and it is 69 MB.
rsync -a --exclude '/include/' "$WINE_ROOT/" "$OUT/Libraries/Wine/"
wine="$OUT/Libraries/Wine"
[[ -e "$wine/bin/wine64" ]] || ln -s wine "$wine/bin/wine64"

install -m 0755 "$WINEMETAL" "$wine/lib/wine/x86_64-unix/winemetal.so"

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
            libMoltenVK.dylib libvulkan.1.dylib; do
  [[ -e "$wine/lib/$name" && ! -e "$unix/$name" ]] && ln -s "../../$name" "$unix/$name"
done

# appwiz.cpl skips its hung GUI installer only when the exact MSI it wants is
# already here; WineMono.ensureDatadirPackage then has nothing to download.
mkdir -p "$wine/share/wine/mono"
install -m 0644 "$MONO_MSI" "$wine/share/wine/mono/wine-mono-$WINE_MONO_VERSION-x86.msi"

rsync -a "$DXVK/" "$OUT/Libraries/DXVK/"
rsync -a "$DXMT/" "$OUT/Libraries/DXMT/"

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
mkdir -p "$lic/wine" "$lic/dxvk" "$lic/dxmt" "$lic/apple-gptk"
for f in LICENSE COPYING.LIB AUTHORS NOTICES.md VERSION; do
  cp "$WINE_SOURCE/$f" "$lic/wine/$f"
done
cp "$ROOT/Documentation/licenses/zlib-DXVK.txt" "$lic/dxvk/LICENSE"
cp "$DXMT/LICENSE" "$lic/dxmt/LICENSE"
cp "$OUT/GPTK/License.rtf" "$OUT/GPTK/Acknowledgements.rtf" "$lic/apple-gptk/"

echo "==> manifest"
macho_count=0
while IFS= read -r f; do
  is_macho "$f" && macho_count=$((macho_count + 1))
done < <(find "$OUT/Libraries" -type f)
{
  echo "Wyn bundled runtime — staged $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "Every binary below is redistributed by Wyn. The LGPL parts oblige Wyn to"
  echo "offer their exact corresponding source from the same place as the download."
  echo
  echo "wine        winecx $wine_commit ($wine_version)  LGPL-2.1-or-later"
  echo "            source: https://github.com/dappermint/winecx/tree/$wine_commit"
  echo "            wine-root: $WINE_ROOT"
  echo "winemetal   $(sha256 "$WINEMETAL")  $(basename "$WINEMETAL")  (DXMT unix half, MIT)"
  echo "dxvk        $(sha256 "$DXVK/x64/d3d11.dll")  x64/d3d11.dll  zlib"
  echo "dxmt        $(sha256 "$DXMT/x64/d3d11.dll")  x64/d3d11.dll  MIT (v0.80)"
  echo "wine-mono   $mono_sha  wine-mono-$WINE_MONO_VERSION-x86.msi  MIT and others (WineHQ)"
  echo "apple-gptk  $gptk_sha  $(basename "$GPTK_DMG")  Apple SLA EA18380, non-commercial redistribution"
  echo "            $eval_sha  $eval_name (copied whole into GPTK/)"
  echo "            D3DMetal $d3dm_version, Apple-signed, unmodified"
  echo
  echo "Companion libraries in Libraries/Wine/lib (each keeps its upstream licence):"
  find "$OUT/Libraries/Wine/lib" -maxdepth 1 -type f -name '*.dylib' -exec basename {} \; | sort | sed 's/^/  /'
  echo
  echo "Mach-O files to sign: $macho_count"
} > "$OUT/RUNTIME-MANIFEST.txt"

du -sh "$OUT/Libraries" "$OUT/GPTK" | sed 's/^/    /'
echo "    $macho_count Mach-O files in Libraries/ to sign"
echo "Staged: $OUT"
echo "Next:   ./scripts/package-dmg.sh --with-runtime \"$OUT\" [--notarize]"
