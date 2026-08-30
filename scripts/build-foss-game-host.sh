#!/usr/bin/env bash
# Build FOSS winecx (Wine 11.15 + in-tree GPTK ntdll hook) for Wyn's D3DMetal
# game-host. Does not download CrossOver, GPTK, or Whisky. Does not vendor Wine.
#
# Pins match frankea/winecx-gptk CI (WINECX_COMMIT / NIXPKGS_REV).
# PE half: mingw-w64 gcc — llvm-mingw kernelbase stalls Steam CM login.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/runtime-pins.env"

WINECX_REPO="${WINECX_REPO:-https://github.com/dappermint/winecx.git}"
WINECX_COMMIT="${WINECX_COMMIT:-c2cce0e61e01dd6e03ee854af526cc17d4412b52}"
NIXPKGS_REV="${NIXPKGS_REV:-ac62194c3917d5f474c1a844b6fd6da2db95077d}"
MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-15.0}"
export MACOSX_DEPLOYMENT_TARGET

SCRATCH="${WINECX_BUILD_DIR:-$ROOT/.scratch/winecx-gptk-build}"
PREFIX="${WINECX_PREFIX:-$SCRATCH/prefix}"
JOBS="${WINECX_JOBS:-$(( $(sysctl -n hw.logicalcpu) + $(sysctl -n hw.logicalcpu) / 2 ))}"

fail() { echo "error: $*" >&2; exit 1; }

command -v x86_64-w64-mingw32-gcc >/dev/null || fail "need x86_64-w64-mingw32-gcc (brew install mingw-w64). llvm-mingw is not accepted."
command -v i686-w64-mingw32-gcc >/dev/null || fail "need i686-w64-mingw32-gcc (brew install mingw-w64)."
arch -x86_64 /usr/bin/true >/dev/null || fail "Rosetta required (x86_64 Wine unix half)."
command -v ccache >/dev/null || fail "need ccache (brew install ccache)"

USE_NIX=0
FRANKEA_LIB=""
if command -v nix >/dev/null; then
  USE_NIX=1
else
  echo "note: Nix not installed (sudo required). Using frankea x86_64 dylibs for"
  echo "      freetype/gnutls and skipping gstreamer/ffmpeg. Install Nix with"
  echo "      extra-platforms = x86_64-darwin for a CI-matching build."
  FRANKEA_LIB="${WINECX_X86_LIB:-$HOME/Library/Application Support/com.fly.gaming/Libraries.pre-gptk-aware.bak/Wine/lib}"
  [[ -f "$FRANKEA_LIB/libgnutls.30.dylib" ]] || fail "no x86_64 libgnutls at $FRANKEA_LIB
Install Nix, or restore frankea via ./scripts/setup.sh first."
  file "$FRANKEA_LIB/libgnutls.30.dylib" | grep -q x86_64 || fail "$FRANKEA_LIB/libgnutls.30.dylib is not x86_64"
  # Autoconf splits LDFLAGS on spaces; "Application Support" would break -L.
fi

echo "==> winecx $WINECX_COMMIT"
echo "    scratch $SCRATCH"
mkdir -p "$SCRATCH"
cd "$SCRATCH"

if [[ ! -d winecx/.git ]]; then
  git clone --filter=blob:none --single-branch --branch wine1115 "$WINECX_REPO" winecx
fi
git -C winecx fetch --depth 1 origin "$WINECX_COMMIT"
git -C winecx checkout --detach "$WINECX_COMMIT"
git -C winecx --no-pager log -1 --oneline
got="$(git -C winecx rev-parse HEAD)"
[[ "$got" == "$WINECX_COMMIT" ]] || fail "winecx HEAD $got != pin $WINECX_COMMIT"

grep -q CX_APPLEGPTK_LIBD3DSHARED_PATH winecx/dlls/ntdll/unix/loader.c \
  || fail "ntdll tree missing CX_APPLEGPTK_LIBD3DSHARED_PATH"

export CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"
export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-4G}"
export CCACHE_COMPILERCHECK=content
export CCACHE_SLOPPINESS="time_macros,locale,include_file_mtime,include_file_ctime"
export CCACHE_BASEDIR="$SCRATCH"
export CCACHE_NOHASHDIR=1
export CCACHE_FILECLONE=1
export CCACHE_INODECACHE=1

mkdir -p ccache-bin
for t in x86_64-w64-mingw32-gcc i686-w64-mingw32-gcc; do
  real="$(command -v "$t")"
  printf '#!/bin/sh\nexec ccache "%s" "$@"\n' "$real" > "ccache-bin/$t"
  chmod +x "ccache-bin/$t"
done

NIX_TOOL_PATH=""
NIX_PKG_CONFIG_PATH=""
NIX_INCS=""
NIX_LDFS=""
native_pc=""
EXTRA_WITHOUT=()
if [[ "$USE_NIX" -eq 1 ]]; then
  NIXPKGS="github:NixOS/nixpkgs/$NIXPKGS_REV"
  echo "==> nix tools + x86_64-darwin libs ($NIXPKGS_REV)"
  tools=$(nix build --no-link --print-out-paths \
    "$NIXPKGS#bison" "$NIXPKGS#flex" "$NIXPKGS#pkg-config")
  for t in $tools; do NIX_TOOL_PATH="$t/bin:$NIX_TOOL_PATH"; done

  outs=""
  for p in freetype gnutls libpng zlib brotli bzip2 nettle libtasn1 libidn2 p11-kit libunistring gmp vulkan-headers ffmpeg-headless \
    glib orc \
    gst_all_1.gstreamer gst_all_1.gst-plugins-base gst_all_1.gst-plugins-good \
    gst_all_1.gst-plugins-bad gst_all_1.gst-libav; do
    for o in dev out lib; do
      if path=$(nix build --no-link --print-out-paths \
        "$NIXPKGS#legacyPackages.x86_64-darwin.$p.$o" 2>/dev/null); then
        outs="$outs $path"
      fi
    done
  done

  for d in $outs; do
    [[ -d "$d/lib/pkgconfig" ]] && NIX_PKG_CONFIG_PATH="$d/lib/pkgconfig:$NIX_PKG_CONFIG_PATH"
    [[ -d "$d/include" ]] && NIX_INCS="$NIX_INCS -I$d/include"
    [[ -d "$d/lib" ]] && NIX_LDFS="$NIX_LDFS -L$d/lib"
  done

  native_outs=$(nix build --no-link --print-out-paths \
    "$NIXPKGS#freetype.dev" "$NIXPKGS#freetype.out" \
    "$NIXPKGS#libpng.dev" "$NIXPKGS#zlib.dev" \
    "$NIXPKGS#brotli.dev" "$NIXPKGS#bzip2.dev")
  for d in $native_outs; do
    [[ -d "$d/lib/pkgconfig" ]] && native_pc="$d/lib/pkgconfig:$native_pc"
  done
else
  BISON_BIN="$(brew --prefix bison 2>/dev/null)/bin"
  [[ -x "$BISON_BIN/bison" ]] || fail "need brew bison 3.x (system bison 2.3 is too old for Wine)"
  NIX_TOOL_PATH="$BISON_BIN:"
  native_pc="$(brew --prefix freetype)/lib/pkgconfig:$(brew --prefix libpng)/lib/pkgconfig:$(brew --prefix zlib)/lib/pkgconfig:"
  # Headers from Homebrew (arch-independent); link x86_64 dylibs from frankea.
  # Do not use Homebrew PKG_CONFIG_PATH on the x86_64 configure — those .pc files point at arm64.
  mkdir -p "$SCRATCH"
  X86_LIB="$SCRATCH/x86_64-lib"
  ln -sfn "$FRANKEA_LIB" "$X86_LIB"
  NIX_INCS="-I$(brew --prefix freetype)/include/freetype2 -I$(brew --prefix gnutls)/include -I$(brew --prefix libpng)/include"
  NIX_LDFS="-L$X86_LIB"
  EXTRA_WITHOUT=(--without-gstreamer --without-ffmpeg)
  export FREETYPE_CFLAGS="-I$(brew --prefix freetype)/include/freetype2"
  export FREETYPE_LIBS="-L$X86_LIB -lfreetype"
  export GNUTLS_CFLAGS="-I$(brew --prefix gnutls)/include"
  export GNUTLS_LIBS="-L$X86_LIB -lgnutls"
fi

export PATH="$SCRATCH/ccache-bin:$NIX_TOOL_PATH$PATH"
export SDKROOT
SDKROOT="$(/usr/bin/xcrun --show-sdk-path)"

if [[ ! -d build-tools/include ]]; then
  echo "==> native tools (__tooldeps__)"
  mkdir -p build-tools
  (
    cd build-tools
    export CC="ccache /usr/bin/clang"
    export PKG_CONFIG_PATH="$native_pc"
    unset FREETYPE_CFLAGS FREETYPE_LIBS GNUTLS_CFLAGS GNUTLS_LIBS
    ../winecx/configure \
      --enable-archs=i386,x86_64 \
      --without-x --without-wayland --without-gstreamer \
      --without-oss --without-alsa --without-pulse --without-sane \
      --without-usb --without-v4l2 --without-pcap --without-capi \
      --without-opencl --without-ffmpeg --without-cups \
      --disable-tests
    make -j"$JOBS" __tooldeps__
    rm -rf nls && mkdir nls && ln -s ../../winecx/nls/locale.nls nls/locale.nls
    test -r nls/locale.nls
  )
fi

echo "==> configure x86_64 unix + mingw PE"
export CC="ccache /usr/bin/clang -arch x86_64"
export CXX="ccache /usr/bin/clang++ -arch x86_64"
export PKG_CONFIG_PATH="$NIX_PKG_CONFIG_PATH"
export CFLAGS="-O2 -Wno-error=implicit-function-declaration $NIX_INCS"
export CROSSCFLAGS="-O2"
export LDFLAGS="$NIX_LDFS"
export ac_cv_lib_soname_freetype="libfreetype.6.dylib"
export ac_cv_lib_soname_gnutls="libgnutls.30.dylib"
export ac_cv_lib_soname_MoltenVK="libMoltenVK.dylib"

mkdir -p build
(
  cd build
  if [[ ! -f Makefile ]]; then
    ../winecx/configure \
      --host=x86_64-apple-darwin24 \
      --with-wine-tools=../build-tools \
      --enable-archs=i386,x86_64 \
      --disable-tests \
      --without-x --without-wayland \
      --without-oss --without-alsa --without-pulse --without-sane \
      --without-usb --without-v4l2 --without-pcap --without-capi \
      --without-opencl --without-cups \
      --prefix=/opt/whiskywine \
      "${EXTRA_WITHOUT[@]+"${EXTRA_WITHOUT[@]}"}"
  fi
  if [[ "$USE_NIX" -eq 1 ]]; then
    grep -q '^#define HAVE_FFMPEG 1' include/config.h \
      || fail "ffmpeg was not found; fix Nix PKG_CONFIG_PATH"
    grep -qE '^GSTREAMER_LIBS *= *.+' Makefile \
      || fail "gstreamer was not found; winegstreamer would be missing"
  else
    grep -q 'ac_cv_lib_soname_gnutls' include/config.h config.log 2>/dev/null || true
    grep -q '^#define SONAME_LIBGNUTLS' include/config.h \
      || fail "gnutls was not found; Steam login needs schannel. Check FRANKEA_LIB + GNUTLS_CFLAGS."
    echo "note: built without gstreamer/ffmpeg (no Nix). Steam video decode may be missing."
  fi
  echo "==> make -j$JOBS"
  make -j"$JOBS"
)

echo "==> destroot $PREFIX"
rm -rf "$PREFIX"
mkdir -p "$PREFIX"
make -C build DESTDIR="$PREFIX" prefix=/opt/whiskywine install
# Relocate from DESTDIR/opt/whiskywine → prefix root Wyn expects (bin/, lib/).
if [[ -d "$PREFIX/opt/whiskywine" ]]; then
  rsync -a "$PREFIX/opt/whiskywine/" "$PREFIX/wine-root/"
  if [[ "$USE_NIX" -eq 0 && -d "$FRANKEA_LIB" ]]; then
    echo "==> copy frankea x86_64 companion dylibs into wine-root/lib"
    rsync -a --exclude wine --exclude external "$FRANKEA_LIB/" "$PREFIX/wine-root/lib/"
    # frankea dylibs use bare install names; LC_RPATH only applies to @rpath/.
    if [[ -x "$PREFIX/wine-root/bin/wineserver" ]]; then
      install_name_tool -add_rpath '@loader_path/../lib' "$PREFIX/wine-root/bin/wineserver" 2>/dev/null || true
      install_name_tool -change libinotify.dylib '@rpath/libinotify.dylib' "$PREFIX/wine-root/bin/wineserver" 2>/dev/null || true
    fi
    if [[ -f "$PREFIX/wine-root/lib/wine/x86_64-unix/winebus.so" ]]; then
      winebus="$PREFIX/wine-root/lib/wine/x86_64-unix/winebus.so"
      # winebus.so lives in lib/wine/x86_64-unix/; libinotify.dylib lives in
      # lib/. @loader_path/../.. is lib/. @loader_path/../../.. is Wine/ and
      # misses the dylib (30 Aug 2026: dlopen @rpath/libinotify.dylib failed,
      # ZwLoadDriver c0000135, setupapi error 126). Do not swallow a failed
      # rpath/codesign: a silent || true shipped a broken bus for a week.
      # Match the LC_RPATH path exactly — a substring grep for ../.. also
      # matches the wrong ../../.. path. otool prints "path … (offset N)".
      command -v otool >/dev/null || fail "need otool to verify winebus rpath"
      winebus_rpaths=$(otool -l "$winebus" | awk '/cmd LC_RPATH/{getline; getline; print $2}')
      if ! printf '%s\n' "$winebus_rpaths" | grep -qx '@loader_path/../..'; then
        if ! install_name_tool -add_rpath '@loader_path/../..' "$winebus" 2>/dev/null; then
          install_name_tool -rpath '@loader_path/../../..' '@loader_path/../..' "$winebus" \
            || fail "winebus rpath: cannot add or replace @loader_path/../.."
        fi
      fi
      install_name_tool -change libinotify.dylib '@rpath/libinotify.dylib' "$winebus" 2>/dev/null || true
      codesign -f -s - "$winebus" || fail "winebus rpath: codesign failed"
      otool -l "$winebus" | awk '/cmd LC_RPATH/{getline; getline; print $2}' \
        | grep -qx '@loader_path/../..' \
        || fail "winebus rpath fix FAILED: missing @loader_path/../.. (libinotify would not load)"
    fi
    unix="$PREFIX/wine-root/lib/wine/x86_64-unix"
    for name in libfreetype.6.dylib libfreetype.dylib libgnutls.30.dylib libgnutls.dylib libMoltenVK.dylib libvulkan.1.dylib; do
      if [[ -e "$PREFIX/wine-root/lib/$name" ]]; then
        ln -sfn "../../$name" "$unix/$name"
      fi
    done
  fi
  # Wine 11 installs `wine`, not `wine64`. Wyn's launcher still looks for wine64.
  if [[ -x "$PREFIX/wine-root/bin/wine" && ! -e "$PREFIX/wine-root/bin/wine64" ]]; then
    ln -s wine "$PREFIX/wine-root/bin/wine64"
  fi
  echo "Installed wine root: $PREFIX/wine-root"
  echo "Next:"
  echo "  wyn runtime install --gptk-aware --directory $PREFIX/wine-root"
  echo "  wyn gptk install --from /path/to/Apple/GPTK/redist"
else
  echo "Installed destroot: $PREFIX"
fi
