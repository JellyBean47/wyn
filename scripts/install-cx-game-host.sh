#!/usr/bin/env bash
# Install Sikarugir CrossOver-hosted Wine as Wyn's D3DMetal game-host.
# Does not download CrossOver, GPTK, or Whisky. Refuses Whisky-as-game-host.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUPPORT="${HOME}/Library/Application Support/com.fly.gaming"
LIBRARIES="${SUPPORT}/Libraries"
BAK="${SUPPORT}/Libraries.pre-gptk-aware.bak"
STEAM_LIB="${SUPPORT}/Libraries.steam"

# Parked sizes from the machine that proved Satisfactory (CX restore, 24 Aug 2026).
CX_WINESERVER_BYTES=593760
WHISKY_WINESERVER_BYTES=856608

DIRECTORY=""
LINK=0
CHECK_ONLY=0

usage() {
  cat <<'EOF'
Install Sikarugir CrossOver-hosted Wine as the D3DMetal game-host.

Wyn does not redistribute CrossOver Wine and will not fetch unofficial CX
tarballs. You supply a tree you are licensed to use.

Usage:
  ./scripts/install-cx-game-host.sh --directory /Applications/CrossOver.app
  ./scripts/install-cx-game-host.sh --directory /Applications/MyWrapper.app --link
  ./scripts/install-cx-game-host.sh --check

--directory   CrossOver.app, a Sikarugir wrapper .app, or a Wine root
              (folder with bin/wine64 or CrossOver-Hosted Application/)
--link        Symlink into ~/Library/Application Support/com.fly.gaming/Libraries/
              instead of copying
--check       Sanity-check the installed Libraries/ only (no copy)

Identity:
  Wine/bin -> CrossOver-Hosted Application
  wine64 -> wineloader
  lib64/apple_gptk present
  wineserver CX-class (~593760 / 4 Jun), not Whisky (~856608 / 25 Apr)

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

file_size() {
  local f="$1"
  [[ -e "$f" ]] || return 1
  stat -f%z "$f" 2>/dev/null || stat -c%s "$f"
}

resolves_to_wineloader() {
  local wine64="$1"
  [[ -e "$wine64" ]] || return 1
  local dest base
  dest="$wine64"
  if [[ -L "$wine64" ]]; then
    dest="$(readlink "$wine64")"
    [[ "$dest" == /* ]] || dest="$(dirname "$wine64")/$dest"
  fi
  base="$(basename "$dest")"
  [[ "$base" == "wineloader" ]]
}

bin_is_cx_hosted() {
  local bin="$1"
  [[ "$(basename "$bin")" == "CrossOver-Hosted Application" ]] && return 0
  if [[ -L "$bin" ]]; then
    local dest
    dest="$(readlink "$bin")"
    [[ "$(basename "$dest")" == "CrossOver-Hosted Application" ]] && return 0
  fi
  return 1
}

looks_like_wine_root() {
  local root="$1"
  local bin
  bin="$(bin_of "$root")"
  [[ -e "$bin/wine64" || -e "$bin/wineloader" || -e "$bin/wine" ]]
}

resolve_wine_root() {
  local user="$1"
  local c
  for c in \
    "$user" \
    "$user/Wine" \
    "$user/Contents/SharedSupport/CrossOver" \
    "$user/Contents/SharedSupport/wine"
  do
    [[ -e "$c" ]] || continue
    if looks_like_wine_root "$c"; then
      echo "$c"
      return 0
    fi
    if looks_like_wine_root "$c/CrossOver-Hosted Application"; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

inspect_and_print() {
  local wine_root="$1"
  local bin wine64 wineserver apple bytes
  bin="$(bin_of "$wine_root")"
  wine64="$bin/wine64"
  wineserver="$bin/wineserver"
  apple="$wine_root/lib64/apple_gptk"

  echo "Game-host Wine:    $wine_root"
  echo "Wine/bin:          $bin"

  if bin_is_cx_hosted "$bin"; then
    echo "bin is CX-hosted:  yes"
  else
    echo "bin is CX-hosted:  no"
  fi

  if resolves_to_wineloader "$wine64"; then
    echo "wine64 wineloader: yes"
  else
    echo "wine64 wineloader: no"
  fi

  if [[ -d "$apple" ]]; then
    echo "lib64/apple_gptk:  yes"
  else
    echo "lib64/apple_gptk:  no"
  fi

  if bytes="$(file_size "$wineserver" 2>/dev/null)"; then
    echo "wineserver bytes:  $bytes"
  else
    echo "wineserver bytes:  (missing)"
    bytes=""
  fi
}

refuse_if_bad() {
  local wine_root="$1"
  local bin wine64 wineserver apple bytes loader=0 whisky=0
  bin="$(bin_of "$wine_root")"
  wine64="$bin/wine64"
  wineserver="$bin/wineserver"
  apple="$wine_root/lib64/apple_gptk"

  if resolves_to_wineloader "$wine64"; then
    loader=1
  fi

  bytes="$(file_size "$wineserver" 2>/dev/null || true)"
  if [[ -n "${bytes:-}" ]]; then
    local delta=$(( bytes - WHISKY_WINESERVER_BYTES ))
    if [[ $delta -lt 0 ]]; then delta=$((-delta)); fi
    if [[ $delta -lt 80000 && $loader -eq 0 ]]; then
      whisky=1
    fi
  fi
  if [[ -f "$wine_root/../WhiskyWineVersion.plist" && $loader -eq 0 ]]; then
    whisky=1
  fi

  if [[ $whisky -eq 1 ]]; then
    fail "Refusing Whisky-as-game-host.
D3DMetal needs Sikarugir CrossOver-hosted Wine (wine64 -> wineloader, lib64/apple_gptk),
not Whisky 11 + GPTK. Parked Whisky wineserver is ~${WHISKY_WINESERVER_BYTES} (25 Apr);
CX is ~${CX_WINESERVER_BYTES} (4 Jun). frankea/setup.sh stays DXMT rollback."
  fi

  [[ $loader -eq 1 ]] || fail "wine64 is not wineloader at $wine64
$(cat <<HINT
$GameHostHint
HINT
)"
  [[ -d "$apple" ]] || fail "missing lib64/apple_gptk under $wine_root"
}

GameHostHint="$(cat <<'HINT'
Get CrossOver from https://www.codeweavers.com/crossover (trial or purchase),
or a Sikarugir wrapper whose engine is that CrossOver-hosted Wine
(https://github.com/Sikarugir-App/Sikarugir). Wyn will not download unofficial
CX binaries. Then rerun with --directory pointing at CrossOver.app or the wrapper.
HINT
)"

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  [[ -d "$LIBRARIES/Wine" ]] || fail "no Libraries/Wine at $LIBRARIES
Run ./scripts/setup.sh for frankea, or this script --directory for the game-host."
  inspect_and_print "$LIBRARIES/Wine"
  refuse_if_bad "$LIBRARIES/Wine"
  echo "CX game-host:      yes"
  echo "Next: wyn gptk install --from /path/to/Apple/GPTK/redist  (GPTK 3.0, not Wine)"
  exit 0
fi

[[ -n "$DIRECTORY" ]] || fail "--directory is required (Wyn does not download CrossOver Wine).
$GameHostHint"

[[ -e "$DIRECTORY" ]] || fail "not found: $DIRECTORY"

WINE_ROOT="$(resolve_wine_root "$DIRECTORY")" || fail "No CrossOver-hosted Wine under $DIRECTORY
$GameHostHint"

echo "==> source Wine root: $WINE_ROOT"
inspect_and_print "$WINE_ROOT"
refuse_if_bad "$WINE_ROOT"

if [[ -x "$ROOT/.build/release/wyn" ]]; then
  echo "==> delegating to wyn runtime install --gptk-aware"
  extra=()
  if [[ "$LINK" -eq 1 ]]; then extra+=(--link); fi
  exec "$ROOT/.build/release/wyn" runtime install --gptk-aware --directory "$DIRECTORY" "${extra[@]+"${extra[@]}"}"
fi

mkdir -p "$SUPPORT"

if [[ -d "$LIBRARIES" ]]; then
  if [[ -d "$LIBRARIES/Wine" ]] && resolves_to_wineloader "$(bin_of "$LIBRARIES/Wine")/wine64" && [[ -d "$LIBRARIES/Wine/lib64/apple_gptk" ]]; then
    echo "==> replacing existing CX Libraries/Wine"
    rm -rf "$LIBRARIES/Wine"
  else
    echo "==> parking non-CX Libraries/ as frankea rollback"
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

HOSTED="$WINE_ROOT/CrossOver-Hosted Application"
if [[ -d "$HOSTED" ]]; then
  SRC_BIN="$HOSTED"
else
  SRC_BIN="$(bin_of "$WINE_ROOT")"
fi

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
echo "CX game-host:      yes"
echo
echo "Next: wyn gptk install --from /path/to/Apple/GPTK/redist"
echo "Steam UI for D3DMetal 3.0 uses this wineserver. Isolation AppDefaults =b"
echo "for steam.exe / steamwebhelper. frankea remains Libraries.steam (DXMT rollback)."
