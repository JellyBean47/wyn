#!/usr/bin/env bash
# Install a self-built FOSS winecx tree as Wyn's D3DMetal game-host.
# Does not download Wine, GPTK, or Whisky.
# Refuses proprietary Wine.app / wineloader layouts and Whisky 11 without
# the winecx ntdll CX_APPLEGPTK hook.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUPPORT="${HOME}/Library/Application Support/com.fly.gaming"
LIBRARIES="${SUPPORT}/Libraries"
BAK="${SUPPORT}/Libraries.pre-gptk-aware.bak"
STEAM_LIB="${SUPPORT}/Libraries.steam"

WHISKY_WINESERVER_BYTES=856608

DIRECTORY=""
LINK=0
CHECK_ONLY=0

usage() {
  cat <<'EOF'
Install self-built FOSS winecx as the D3DMetal game-host.

Wyn does not download Wine for this path. Proprietary Wine.app bundles and
wineloader layouts are refused. Build winecx first
(./scripts/build-foss-game-host.sh).

Usage:
  ./scripts/install-foss-game-host.sh --directory /path/to/wine-prefix
  ./scripts/install-foss-game-host.sh --directory /path/to/Libraries --link
  ./scripts/install-foss-game-host.sh --check

--directory   Wine prefix / Wine root / Wyn Libraries tree (bin/wine64 + ntdll.so)
--link        Symlink into ~/Library/Application Support/com.fly.gaming/Libraries/
              instead of copying
--check       Sanity-check the installed Libraries/ only (no copy)

Identity:
  ntdll.so contains CX_APPLEGPTK_LIBD3DSHARED_PATH (winecx GPTK hook)
  wine64 is not wineloader
  Wine/bin is an ordinary bin/ directory

GPTK 3.0 is separate: wyn gptk install --from <Apple redist or DMG>
frankea (./scripts/setup.sh) stays DXMT / window rollback as Libraries.steam.
EOF
}

fail() { echo "error: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --directory)
      DIRECTORY="${2:-}"
      [[ -n "$DIRECTORY" ]] || fail "--directory needs a path"
      shift 2
      ;;
    --link)
      LINK=1
      shift
      ;;
    --check)
      CHECK_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown arg: $1
$(usage)"
      ;;
  esac
done

bin_of() {
  local wine_root="$1"
  if [[ -d "$wine_root/CrossOver-Hosted Application" ]]; then
    echo "$wine_root/CrossOver-Hosted Application"
  else
    echo "$wine_root/bin"
  fi
}

resolves_to_wineloader() {
  local wine64="$1"
  [[ -e "$wine64" ]] || return 1
  local base
  base="$(basename "$wine64")"
  if [[ "$base" == "wineloader" ]]; then return 0; fi
  if [[ -L "$wine64" ]]; then
    local dest
    dest="$(readlink "$wine64" || true)"
    [[ "$(basename "$dest")" == "wineloader" ]] && return 0
  fi
  local resolved
  resolved="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$wine64" 2>/dev/null || readlink -f "$wine64" 2>/dev/null || echo "$wine64")"
  [[ "$(basename "$resolved")" == "wineloader" ]]
}

bin_is_cx_hosted() {
  local bin="$1"
  [[ "$(basename "$bin")" == "CrossOver-Hosted Application" ]] && return 0
  if [[ -L "$bin" ]]; then
    local dest
    dest="$(readlink "$bin" || true)"
    [[ "$(basename "$dest")" == "CrossOver-Hosted Application" ]] && return 0
  fi
  return 1
}

is_wine_root() {
  local wine_root="$1"
  local bin
  bin="$(bin_of "$wine_root")"
  [[ -e "$bin/wine64" || -e "$bin/wineloader" || -e "$bin/wine" ]]
}

resolve_wine_root() {
  local user="$1"
  local candidates=("$user" "$user/Wine")
  if [[ "$user" == *.app ]]; then
    candidates+=("$user/Contents/SharedSupport/CrossOver" "$user/Contents/SharedSupport/wine")
  fi
  candidates+=("$user/Contents/SharedSupport/CrossOver" "$user/Contents/SharedSupport/wine")
  local c
  for c in "${candidates[@]}"; do
    if is_wine_root "$c"; then
      echo "$c"
      return 0
    fi
    if [[ -d "$c/CrossOver-Hosted Application" ]] && is_wine_root "$c"; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

file_size() {
  python3 -c 'import os,sys; print(os.path.getsize(os.path.realpath(sys.argv[1])))' "$1"
}

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

inspect_and_print() {
  local wine_root="$1"
  local bin wine64 wineserver
  bin="$(bin_of "$wine_root")"
  wine64="$bin/wine64"
  wineserver="$bin/wineserver"

  echo "Game-host Wine:    $wine_root"
  echo "Wine/bin:          $bin"

  if bin_is_cx_hosted "$bin"; then
    echo "bin hosted layout: yes — refused"
  else
    echo "bin hosted layout: no"
  fi

  if resolves_to_wineloader "$wine64"; then
    echo "wine64 wineloader: yes — refused"
  else
    echo "wine64 wineloader: no"
  fi

  if ntdll_has_hook "$wine_root"; then
    echo "ntdll CX_APPLEGPTK: yes"
  else
    echo "ntdll CX_APPLEGPTK: no"
  fi

  if bytes="$(file_size "$wineserver" 2>/dev/null)"; then
    echo "wineserver bytes:  $bytes"
  else
    echo "wineserver bytes:  (missing)"
    bytes=""
  fi
}

GameHostHint="$(cat <<'HINT'
Build FOSS winecx (./scripts/build-foss-game-host.sh) and pass that prefix
to --directory. Wyn will not download Wine here and will not accept
proprietary Wine.app bundles or wineloader.
HINT
)"

refuse_if_bad() {
  local wine_root="$1"
  local bin wine64 wineserver bytes loader=0 hosted=0 whisky=0 ntdll=0
  bin="$(bin_of "$wine_root")"
  wine64="$bin/wine64"
  wineserver="$bin/wineserver"

  if [[ "$wine_root" == *CrossOver.app* ]] || [[ "$DIRECTORY" == *CrossOver.app* ]]; then
    fail "Refusing a proprietary Wine.app bundle.
$GameHostHint"
  fi

  if resolves_to_wineloader "$wine64"; then
    loader=1
  fi
  if bin_is_cx_hosted "$bin"; then
    hosted=1
  fi
  if ntdll_has_hook "$wine_root"; then
    ntdll=1
  fi

  if [[ $loader -eq 1 || $hosted -eq 1 ]]; then
    fail "Refusing proprietary Wine loader layout (wineloader / hosted-application bin).
$GameHostHint"
  fi

  bytes="$(file_size "$wineserver" 2>/dev/null || true)"
  if [[ $ntdll -eq 0 ]]; then
    if [[ -n "${bytes:-}" ]]; then
      local delta=$(( bytes - WHISKY_WINESERVER_BYTES ))
      if [[ $delta -lt 0 ]]; then delta=$((-delta)); fi
      if [[ $delta -lt 80000 ]]; then
        whisky=1
      fi
    fi
    if [[ -f "$wine_root/../WhiskyWineVersion.plist" ]]; then
      whisky=1
    fi
  fi

  if [[ $whisky -eq 1 ]]; then
    fail "Refusing Whisky-as-game-host (no ntdll CX_APPLEGPTK hook).
Parked Whisky wineserver is ~${WHISKY_WINESERVER_BYTES} (25 Apr).
frankea/setup.sh stays DXMT rollback.
$GameHostHint"
  fi

  [[ $ntdll -eq 1 ]] || fail "ntdll.so missing CX_APPLEGPTK_LIBD3DSHARED_PATH at $wine_root
$GameHostHint"
}

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  [[ -d "$LIBRARIES/Wine" ]] || fail "no Libraries/Wine at $LIBRARIES
Run ./scripts/setup.sh for frankea, or this script --directory for the game-host."
  inspect_and_print "$LIBRARIES/Wine"
  refuse_if_bad "$LIBRARIES/Wine"
  echo "FOSS GPTK host:    yes"
  echo "Next: wyn gptk install --from /path/to/Apple/GPTK/redist  (GPTK 3.0, not Wine)"
  exit 0
fi

[[ -n "$DIRECTORY" ]] || fail "--directory is required (Wyn does not download game-host Wine).
$GameHostHint"

[[ -e "$DIRECTORY" ]] || fail "not found: $DIRECTORY"

if [[ "$DIRECTORY" == *CrossOver.app* ]]; then
  fail "Refusing a proprietary Wine.app bundle.
$GameHostHint"
fi

WINE_ROOT="$(resolve_wine_root "$DIRECTORY")" || fail "No Wine tree under $DIRECTORY
$GameHostHint"

echo "==> source Wine root: $WINE_ROOT"
inspect_and_print "$WINE_ROOT"
refuse_if_bad "$WINE_ROOT"

if [[ -x "$ROOT/.build/release/wyn" ]]; then
  echo "==> delegating to wyn runtime install --gptk-aware"
  extra=()
  if [[ "$LINK" -eq 1 ]]; then extra+=(--link); fi
  "$ROOT/.build/release/wyn" runtime install --gptk-aware --directory "$DIRECTORY" "${extra[@]+"${extra[@]}"}"
  echo "==> Wine Mono into live winecx datadir (wineboot GUI hang otherwise)"
  "$ROOT/scripts/install-wine-mono.sh"
  exit 0
fi

mkdir -p "$SUPPORT"

if [[ -d "$LIBRARIES" ]]; then
  if [[ -d "$LIBRARIES/Wine" ]] && ntdll_has_hook "$LIBRARIES/Wine" && ! resolves_to_wineloader "$(bin_of "$LIBRARIES/Wine")/wine64"; then
    echo "==> replacing existing FOSS Libraries/Wine"
    rm -rf "$LIBRARIES/Wine"
  else
    echo "==> parking non-host Libraries/ as frankea rollback"
    if [[ -d "$BAK" ]]; then
      mkdir -p "$STEAM_LIB"
      if [[ ! -e "$STEAM_LIB/Wine/bin/wine64" ]]; then
        ln -sfn "$BAK" "$STEAM_LIB"
      fi
      rm -rf "$LIBRARIES"
    else
      mv "$LIBRARIES" "$BAK"
      ln -sfn "$BAK" "$STEAM_LIB"
    fi
  fi
fi

mkdir -p "$LIBRARIES/Wine"

SRC_BIN="$(bin_of "$WINE_ROOT")"

place() {
  local src="$1" dst="$2"
  if [[ "$LINK" -eq 1 ]]; then
    ln -sfn "$src" "$dst"
  else
    ditto "$src" "$dst"
  fi
}

echo "==> installing Wine/bin from $SRC_BIN"
place "$SRC_BIN" "$LIBRARIES/Wine/bin"
for name in lib lib64 share include; do
  if [[ -e "$WINE_ROOT/$name" ]]; then
    place "$WINE_ROOT/$name" "$LIBRARIES/Wine/$name"
  fi
done

inspect_and_print "$LIBRARIES/Wine"
refuse_if_bad "$LIBRARIES/Wine"
echo "FOSS GPTK host:    yes"
echo "==> Wine Mono into live winecx datadir (wineboot GUI hang otherwise)"
"$ROOT/scripts/install-wine-mono.sh"
echo
echo "Next: wyn gptk install --from /path/to/Apple/GPTK/redist"
echo "Steam UI for D3DMetal 3.0 uses this wineserver. Isolation AppDefaults =b"
echo "for steam.exe / steamwebhelper. frankea remains Libraries.steam (DXMT rollback)."
