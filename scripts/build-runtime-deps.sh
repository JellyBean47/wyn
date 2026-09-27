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
# Build the x86_64 libraries the bundled Wine runtime loads, from the pinned
# upstream tarballs in scripts/runtime-deps.env: FreeType (+libpng), GnuTLS
# (+Nettle, GMP, libtasn1), SDL2; MoltenVK from Khronos' release.
#
#   ./scripts/build-runtime-deps.sh [--work DIR]    # default .scratch/runtime-deps
#
# No Nix, no Homebrew bottles, no MacPorts. Every binary is built here from a
# tarball whose SHA-256 is pinned, so those tarballs are exactly the LGPL
# corresponding source (package-sources.sh ships them). The libraries are
# cut down to what Wine uses: no p11-kit, IDN, NLS, compression or C++ in
# GnuTLS, and no HarfBuzz or Brotli in FreeType. The ~40 MacPorts dylibs of
# the old trees (ICU alone was 32 MB) were dependencies of those extras.
#
# Output, in DIR:
#   prefix/lib     runtime dylibs: install name @rpath/<soname>, LC_RPATHs
#                  @loader_path and @loader_path/../.. — they load from Wine/lib
#                  and through the lib/wine/x86_64-unix symlinks alike
#   prefix/include, prefix/lib/pkgconfig   for the winecx build
#   sources/       the verified tarballs
#   prefix/DEPS-MANIFEST.txt
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/runtime-pins.env"
# shellcheck disable=SC1091
source "$ROOT/scripts/runtime-deps.env"

WORK="$ROOT/.scratch/runtime-deps"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --work) WORK="$2"; shift 2 ;;
    -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

fail() { echo "error: $*" >&2; exit 1; }
arch -x86_64 /usr/bin/true 2>/dev/null || fail "Rosetta is required to check the x86_64 libraries"

SOURCES="$WORK/sources"
BUILD="$WORK/build"
PREFIX="$WORK/prefix"
mkdir -p "$SOURCES" "$BUILD"
rm -rf "$PREFIX"
mkdir -p "$PREFIX/lib" "$PREFIX/include"

# Cross-compile with the native compiler: x86_64 output, arm64 speed. Nothing
# from Homebrew may leak in — its headers and .pc files describe arm64 builds.
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH PKG_CONFIG_PATH
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-15.0}"
export CC="clang -arch x86_64" CXX="clang++ -arch x86_64"
export CC_FOR_BUILD="clang" CFLAGS="-O2" CXXFLAGS="-O2"
export CPPFLAGS="-I$PREFIX/include"
export LDFLAGS="-L$PREFIX/lib -Wl,-headerpad_max_install_names"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
JOBS="$(sysctl -n hw.logicalcpu)"
CONFIGURE=(--host=x86_64-apple-darwin --build=aarch64-apple-darwin
           --prefix="$PREFIX" --enable-shared --disable-static)

# zlib and bzip2 are macOS's own. They ship no .pc files, and libpng's and
# FreeType's .pc files require them (Requires.private), so pkg-config refuses
# every query that touches either — FreeType's configure then reports libpng
# "not found" — until these describe the system copies.
mkdir -p "$PREFIX/lib/pkgconfig"
sdk_zlib="$(sed -n 's/^#define ZLIB_VERSION "\(.*\)"/\1/p' "$(xcrun --show-sdk-path)/usr/include/zlib.h")"
printf 'Name: zlib\nDescription: macOS system zlib\nVersion: %s\nLibs: -lz\nCflags:\n' \
  "${sdk_zlib:-1.2.12}" > "$PREFIX/lib/pkgconfig/zlib.pc"
printf 'Name: bzip2\nDescription: macOS system bzip2\nVersion: 1.0.8\nLibs: -lbz2\nCflags:\n' \
  > "$PREFIX/lib/pkgconfig/bzip2.pc"

field() { local IFS='|'; read -r -a parts <<<"$1"; echo "${parts[$2]}"; }

# Download (resumable, the line here can be slow), then refuse anything whose
# SHA-256 is not the pinned one. A placeholder pin prints the hash and stops:
# pinning a new version is a decision, not something a build does silently.
fetch() {
  local spec="$1" url sha file got
  url="$(field "$spec" 2)"; sha="$(field "$spec" 3)"
  file="$SOURCES/$(basename "$url")"
  if [[ ! -f "$file" ]]; then
    echo "    fetching $(basename "$url")" >&2
    curl -fL -C - --retry 20 --retry-all-errors --retry-delay 5 -sS -o "$file.partial" "$url"
    mv "$file.partial" "$file"
  fi
  got="$(shasum -a 256 "$file" | awk '{print $1}')"
  if [[ "$sha" != "$got" ]]; then
    if [[ "$sha" == SHA_* ]]; then
      fail "$(basename "$file") has no pinned hash yet. Its SHA-256 is $got; pin it in scripts/runtime-deps.env as $sha."
    fi
    fail "$(basename "$file"): SHA-256 $got, pinned $sha"
  fi
  echo "$file"
}

unpack() {
  local tarball="$1" dir
  dir="$BUILD/$(basename "$tarball" | sed -E 's/\.tar\.(gz|xz|bz2)$//')"
  rm -rf "$dir"
  tar -xf "$tarball" -C "$BUILD"
  echo "$dir"
}

autotools() {
  local spec="$1"; shift
  local name src
  name="$(field "$spec" 0)-$(field "$spec" 1)"
  echo "==> $name"
  src="$(unpack "$(fetch "$spec")")"
  (
    cd "$src"
    ./configure "${CONFIGURE[@]}" "$@" >"$BUILD/$name.configure.log" 2>&1 \
      || { tail -30 "$BUILD/$name.configure.log" >&2; exit 1; }
    make -j"$JOBS" >"$BUILD/$name.make.log" 2>&1 \
      || { tail -30 "$BUILD/$name.make.log" >&2; exit 1; }
    make install >"$BUILD/$name.install.log" 2>&1 \
      || { tail -30 "$BUILD/$name.install.log" >&2; exit 1; }
  )
}

autotools "$DEP_GMP" --disable-cxx
autotools "$DEP_NETTLE" --disable-documentation --disable-openssl
autotools "$DEP_TASN1" --disable-doc
# Secur32 (schannel) is the only user: Steam's CM login and every HTTPS a game
# makes through Windows APIs. Certificates are checked by Wine's crypt32 against
# the macOS keychain, not by GnuTLS, so its trust-store options do not matter.
autotools "$DEP_GNUTLS" \
  --with-included-unistring --without-p11-kit --without-idn --disable-nls \
  --disable-cxx --disable-tools --disable-doc --disable-manpages --disable-tests \
  --disable-guile --without-zlib --without-zstd --without-brotli \
  --without-tpm --without-tpm2 --disable-libdane --disable-openssl-compatibility
autotools "$DEP_LIBPNG"
# zlib and bzip2 are macOS's own (/usr/lib); HarfBuzz and Brotli are not used by Wine.
autotools "$DEP_FREETYPE" --with-zlib=yes --with-bzip2=yes --with-png=yes \
  --with-harfbuzz=no --with-brotli=no --with-librsvg=no

echo "==> SDL2-$(field "$DEP_SDL2" 1)"
sdl_src="$(unpack "$(fetch "$DEP_SDL2")")"
cmake -S "$sdl_src" -B "$BUILD/sdl2-build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
  -DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew -DCMAKE_SYSTEM_IGNORE_PREFIX_PATH=/opt/homebrew \
  -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TEST=OFF \
  -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-headerpad_max_install_names" \
  >"$BUILD/sdl2.configure.log" 2>&1 || { tail -30 "$BUILD/sdl2.configure.log" >&2; exit 1; }
cmake --build "$BUILD/sdl2-build" -j "$JOBS" >"$BUILD/sdl2.make.log" 2>&1 \
  || { tail -30 "$BUILD/sdl2.make.log" >&2; exit 1; }
cmake --install "$BUILD/sdl2-build" >"$BUILD/sdl2.install.log" 2>&1

echo "==> MoltenVK-$(field "$DEP_MOLTENVK" 1) (Khronos release)"
mvk_tar="$(fetch "$DEP_MOLTENVK")"
rm -rf "$BUILD/moltenvk" && mkdir -p "$BUILD/moltenvk"
tar -xf "$mvk_tar" -C "$BUILD/moltenvk"
mvk_dylib="$(find "$BUILD/moltenvk" -path '*dynamic*' -name libMoltenVK.dylib | grep -i macos | head -1)"
[[ -n "$mvk_dylib" ]] || fail "no macOS libMoltenVK.dylib in $(basename "$mvk_tar")"
# Wine's unix half is x86_64 only; the arm64 slice would double the size for nothing.
lipo "$mvk_dylib" -thin x86_64 -output "$PREFIX/lib/libMoltenVK.dylib" 2>/dev/null \
  || cp "$mvk_dylib" "$PREFIX/lib/libMoltenVK.dylib"
ln -sf libMoltenVK.dylib "$PREFIX/lib/libvulkan.1.dylib"
mkdir -p "$PREFIX/share/licenses/MoltenVK"
find "$BUILD/moltenvk" -maxdepth 3 -name 'LICENSE*' -exec cp {} "$PREFIX/share/licenses/MoltenVK/" \;

echo "==> licences"
# Each library's own licence texts travel with its binary (stage-runtime.sh
# copies share/licenses into the app and the image's Legal/).
for spec in "$DEP_GMP" "$DEP_NETTLE" "$DEP_TASN1" "$DEP_GNUTLS" "$DEP_LIBPNG" "$DEP_FREETYPE" "$DEP_SDL2"; do
  name="$(field "$spec" 0)"
  src="$BUILD/$name-$(field "$spec" 1)"
  mkdir -p "$PREFIX/share/licenses/$name"
  find "$src" -maxdepth 1 -type f \( -name 'COPYING*' -o -name 'LICENSE*' -o -name 'AUTHORS' \) \
    -exec cp {} "$PREFIX/share/licenses/$name/" \;
  # FreeType keeps its FTL and GPLv2 texts under docs/.
  find "$src/docs" -maxdepth 1 -type f \( -name 'LICENSE.TXT' -o -name 'FTL.TXT' -o -name 'GPLv2.TXT' \) \
    -exec cp {} "$PREFIX/share/licenses/$name/" \; 2>/dev/null || true
  [[ -n "$(ls -A "$PREFIX/share/licenses/$name")" ]] || fail "no licence file found for $name in $src"
done

echo "==> relocating"
rm -f "$PREFIX"/lib/*.la
has_rpath() { otool -l "$1" | awk '/cmd LC_RPATH/{getline; getline; print $2}' | grep -Fqx "$2"; }
for lib in "$PREFIX"/lib/*.dylib; do
  [[ -L "$lib" ]] && continue
  id="$(otool -D "$lib" | tail -n +2)"
  install_name_tool -id "@rpath/$(basename "$id")" "$lib" 2>/dev/null
  while IFS= read -r dep; do
    install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$lib" 2>/dev/null
  done < <(otool -L "$lib" | tail -n +2 | awk -v p="$PREFIX/" 'index($1, p) == 1 { print $1 }')
  for rp in @loader_path @loader_path/../..; do
    has_rpath "$lib" "$rp" || install_name_tool -add_rpath "$rp" "$lib" 2>/dev/null
  done
  strip -x "$lib" 2>/dev/null || true
  codesign --force --sign - "$lib" 2>/dev/null
done

echo "==> checking"
# 1. Nothing may point outside the tree except macOS itself.
bad=""
for lib in "$PREFIX"/lib/*.dylib; do
  [[ -L "$lib" ]] && continue
  lipo -archs "$lib" | grep -qx x86_64 || bad+="  $(basename "$lib"): not x86_64-only ($(lipo -archs "$lib"))\n"
  while IFS= read -r dep; do
    case "$dep" in
      @rpath/*|/usr/lib/*|/System/Library/*) ;;
      *) bad+="  $(basename "$lib") -> $dep\n" ;;
    esac
  done < <(otool -L "$lib" | tail -n +2 | awk '{print $1}')
done
[[ -z "$bad" ]] || fail "non-relocatable references:\n$bad"

# 2. Every library loads, from a copy laid out like Wine/lib, through the same
#    unix-directory symlinks Wine uses, with this build tree out of reach.
check="$WORK/loadcheck"
rm -rf "$check" && mkdir -p "$check/lib/wine/x86_64-unix"
cp -a "$PREFIX"/lib/*.dylib "$check/lib/"
for name in libfreetype.6.dylib libgnutls.30.dylib libSDL2-2.0.0.dylib libMoltenVK.dylib libvulkan.1.dylib; do
  [[ -e "$check/lib/$name" ]] || fail "$name was not built"
  ln -s "../../$name" "$check/lib/wine/x86_64-unix/$name"
done
cat > "$check/dlopen-check.c" <<'C'
#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char **argv) {
    int failed = 0;
    for (int i = 1; i < argc; i++) {
        void *h = dlopen(argv[i], RTLD_NOW | RTLD_LOCAL);
        printf("  %-4s %s%s%s\n", h ? "ok" : "FAIL", argv[i], h ? "" : ": ", h ? "" : dlerror());
        failed |= !h;
    }
    return failed;
}
C
clang -arch x86_64 -o "$check/dlopen-check" "$check/dlopen-check.c"
mv "$PREFIX" "$PREFIX.masked"
trap 'mv "$PREFIX.masked" "$PREFIX" 2>/dev/null || true' EXIT
unix="$check/lib/wine/x86_64-unix"
env -i PATH=/usr/bin:/bin "$check/dlopen-check" \
  "$unix/libfreetype.6.dylib" "$unix/libgnutls.30.dylib" "$unix/libSDL2-2.0.0.dylib" \
  "$unix/libvulkan.1.dylib" || fail "a runtime library does not load from the relocated tree"
mv "$PREFIX.masked" "$PREFIX"
trap - EXIT

{
  echo "Wyn runtime libraries — built $(date -u +%Y-%m-%dT%H:%M:%SZ), x86_64, macOS $MACOSX_DEPLOYMENT_TARGET+"
  echo
  for spec in "$DEP_GMP" "$DEP_NETTLE" "$DEP_TASN1" "$DEP_GNUTLS" "$DEP_LIBPNG" "$DEP_FREETYPE" "$DEP_SDL2" "$DEP_MOLTENVK"; do
    printf '%-10s %-8s %s  %s\n' "$(field "$spec" 0)" "$(field "$spec" 1)" "$(field "$spec" 3)" "$(field "$spec" 4)"
    printf '%-19s %s\n' "" "$(field "$spec" 2)"
  done
  echo
  echo "Runtime dylibs:"
  (cd "$PREFIX/lib" && ls -1 ./*.dylib | sed 's|^\./|  |')
} > "$PREFIX/DEPS-MANIFEST.txt"

du -sh "$PREFIX/lib" | sed 's/^/    /'
echo "Built: $PREFIX"
echo "Next:  WINECX_DEPS_PREFIX=\"$PREFIX\" ./scripts/build-foss-game-host.sh"
