#!/usr/bin/env bash
# Read-only snapshot of Satisfactory input-related config around a play.
# Never wineserver -k. Does not launch or quit the game.
#
#   bash scripts/snapshot-cursor-config.sh <label>
#   bash scripts/snapshot-cursor-config.sh --diff <label-a> <label-b>
#   bash scripts/snapshot-cursor-config.sh --manifest-diff <label-a> <label-b>
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BOTTLE="${WYN_BOTTLE:-$HOME/Library/Containers/com.fly.gaming/Bottles/7F5EE61C-CFB8-42B4-BFCA-2B6CDE901A4A}"
OUT_ROOT="${WYN_CURSOR_SNAP:-$ROOT/.scratch/foss-gptk-observe/cursor-ab/snapshots}"
USER_WIN="${WYN_WINE_USER:-crossover}"
STEAM_ACCOUNT="${WYN_STEAM_ACCOUNT:-1820256332}"
APP_ID="${WYN_STEAM_APP:-526870}"
SAVED="$BOTTLE/drive_c/users/$USER_WIN/AppData/Local/FactoryGame/Saved"
GUS="$SAVED/Config/Windows/GameUserSettings.ini"
ENG="$SAVED/Config/Windows/Engine.ini"
REG="$BOTTLE/user.reg"
SYSTEM_REG="$BOTTLE/system.reg"
DEBUGUI="$SAVED/DebugUI/Settings.data"
SERVERMGR="$SAVED/SaveGames/ServerManager_V2.sav"
STEAM_ROOT="$BOTTLE/drive_c/Program Files (x86)/Steam"
STATS="$STEAM_ROOT/appcache/stats/UserGameStats_${STEAM_ACCOUNT}_${APP_ID}.bin"
REMOTECACHE="$STEAM_ROOT/userdata/${STEAM_ACCOUNT}/${APP_ID}/remotecache.vdf"
LOCALCONFIG="$STEAM_ROOT/userdata/${STEAM_ACCOUNT}/config/localconfig.vdf"

mtime_of() {
  if [[ -f "$1" ]]; then
    stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$1"
  else
    echo missing
  fi
}

usage() {
  echo "usage: $0 <label>" >&2
  echo "       $0 --diff <label-a> <label-b>" >&2
  echo "       $0 --manifest-diff <label-a> <label-b>" >&2
  exit 2
}

# One line per file: relpath<TAB>mtime<TAB>size<TAB>sha1, relative to $BOTTLE.
# Trees: FactoryGame Saved minus Logs/Crashes, Steam userdata/appcache/config,
# bottle *.reg. Sorted so --manifest-diff is stable.
write_manifest() {
  local out="$1"
  local tmp
  tmp="$(mktemp -t wyn-cursor-manifest)"
  {
    if [[ -d "$SAVED" ]]; then
      find "$SAVED" -type f ! -path '*/Logs/*' ! -path '*/Crashes/*' -print0
    fi
    for d in "$STEAM_ROOT/userdata" "$STEAM_ROOT/appcache" "$STEAM_ROOT/config"; do
      if [[ -d "$d" ]]; then
        find "$d" -type f -print0
      fi
    done
    for r in "$BOTTLE/system.reg" "$BOTTLE/user.reg" "$BOTTLE/userdef.reg"; do
      if [[ -f "$r" ]]; then
        printf '%s\0' "$r"
      fi
    done
  } >"$tmp.null"
  while IFS= read -r -d '' f; do
    rel="${f#"$BOTTLE"/}"
    mtime="$(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$f")"
    size="$(stat -f '%z' "$f")"
    sha="$(shasum -a 1 "$f" | awk '{print $1}')"
    printf '%s\t%s\t%s\t%s\n' "$rel" "$mtime" "$size" "$sha"
  done <"$tmp.null" | LC_ALL=C sort >"$tmp"
  rm -f "$tmp.null"
  {
    echo "# snapshot-cursor-config manifest"
    echo "# bottle=$BOTTLE"
    echo "# columns: relpath<TAB>mtime<TAB>size<TAB>sha1"
    echo "# trees: Saved (minus Logs/Crashes), Steam userdata/appcache/config, bottle *.reg"
    cat "$tmp"
  } >"$out"
  rm -f "$tmp"
}

latest_dir_for() {
  local label="$1"
  ls -1d "$OUT_ROOT"/*-"$label" 2>/dev/null | tail -1
}

summarize() {
  local gus="$1" eng="$2"
  echo "--- GameUserSettings.ini ---"
  if [[ -f "$gus" ]]; then
    rg -n "mBoolValues|mIntValues|InputMode|GamepadDisconnect|ForceMouse" "$gus" || echo "(no matching keys)"
  else
    echo "(missing)"
  fi
  echo "--- Engine.ini [Core.Log] ---"
  if [[ -f "$eng" ]]; then
    awk 'BEGIN{p=0} /^\[/{p=0} /^\[Core\.Log\]/{p=1} p' "$eng"
  else
    echo "(missing)"
  fi
  echo "--- Engine.ini [ConsoleVariables] ---"
  if [[ -f "$eng" ]]; then
    awk 'BEGIN{p=0} /^\[/{p=0} /^\[ConsoleVariables\]/{p=1} p' "$eng"
  else
    echo "(missing)"
  fi
}

if [[ "${1:-}" == "--diff" ]]; then
  [[ $# -eq 3 ]] || usage
  a="$(latest_dir_for "$2")"
  b="$(latest_dir_for "$3")"
  [[ -n "$a" && -d "$a" ]] || { echo "error: no snapshot for label $2" >&2; exit 1; }
  [[ -n "$b" && -d "$b" ]] || { echo "error: no snapshot for label $3" >&2; exit 1; }
  echo "diff $a"
  echo "  vs $b"
  diff -u "$a/GameUserSettings.ini" "$b/GameUserSettings.ini" || true
  echo
  diff -u "$a/Engine.ini" "$b/Engine.ini" || true
  echo
  diff -u "$a/user.reg" "$b/user.reg" | head -80 || true
  echo
  for extra in DebugUI-Settings.data ServerManager_V2.sav \
               UserGameStats.bin remotecache.vdf winebus-hid.txt \
               steam-controller.txt processes.txt; do
    if [[ -f "$a/$extra" || -f "$b/$extra" ]]; then
      echo "--- $extra ---"
      diff -u "$a/$extra" "$b/$extra" || true
      echo
    fi
  done
  exit 0
fi

if [[ "${1:-}" == "--manifest-diff" ]]; then
  [[ $# -eq 3 ]] || usage
  a="$(latest_dir_for "$2")"
  b="$(latest_dir_for "$3")"
  [[ -n "$a" && -d "$a" ]] || { echo "error: no snapshot for label $2" >&2; exit 1; }
  [[ -n "$b" && -d "$b" ]] || { echo "error: no snapshot for label $3" >&2; exit 1; }
  [[ -f "$a/manifest.txt" ]] || { echo "error: no manifest.txt in $a" >&2; exit 1; }
  [[ -f "$b/manifest.txt" ]] || { echo "error: no manifest.txt in $b" >&2; exit 1; }
  echo "manifest-diff $a"
  echo "  vs $b"
  echo "files: $(grep -c $'\t' "$a/manifest.txt" || true) -> $(grep -c $'\t' "$b/manifest.txt" || true)"
  diff -u "$a/manifest.txt" "$b/manifest.txt" || true
  exit 0
fi

[[ $# -eq 1 ]] || usage
label="$1"
[[ "$label" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "error: label must be [A-Za-z0-9][A-Za-z0-9._-]*" >&2; exit 1; }

stamp="$(date +%Y%m%d-%H%M%S)"
dest="$OUT_ROOT/${stamp}-${label}"
mkdir -p "$dest"

copy_if() {
  local src="$1" name="$2"
  if [[ -f "$src" ]]; then
    cp -p "$src" "$dest/$name"
  else
    echo "(missing) $src" >"$dest/${name}.MISSING"
  fi
}

copy_if "$GUS" "GameUserSettings.ini"
copy_if "$ENG" "Engine.ini"
copy_if "$REG" "user.reg"
copy_if "$DEBUGUI" "DebugUI-Settings.data"
copy_if "$SERVERMGR" "ServerManager_V2.sav"
copy_if "$STATS" "UserGameStats.bin"
copy_if "$REMOTECACHE" "remotecache.vdf"
copy_if "$LOCALCONFIG" "localconfig.vdf"

write_manifest "$dest/manifest.txt"

if [[ -f "$SYSTEM_REG" ]]; then
  rg -n -A 16 \
    'WINEBUS|winehid|winexinput|VID_845E|DeviceClasses\\\\\{378DE44C|DeviceClasses\\\\\{4D1E55B2|DeviceClasses\\\\\{884B96C3|Services\\\\winebus|Services\\\\winehid|Services\\\\winexinput' \
    "$SYSTEM_REG" >"$dest/winebus-hid.txt" || true
  if [[ ! -s "$dest/winebus-hid.txt" ]]; then
    echo "(no winebus/winehid/winexinput matches)" >"$dest/winebus-hid.txt"
  fi
else
  echo "(missing) $SYSTEM_REG" >"$dest/winebus-hid.txt.MISSING"
fi

{
  echo "UseSteamControllerConfig for $APP_ID:"
  if [[ -f "$LOCALCONFIG" ]]; then
    awk -v app="\"$APP_ID\"" '
      $0 ~ app { inapp=1; depth=0 }
      inapp {
        print
        if ($0 ~ /\{/) depth++
        if ($0 ~ /\}/) { depth--; if (depth<=0) { inapp=0 } }
      }
    ' "$LOCALCONFIG" | rg -n "UseSteamControllerConfig|$APP_ID|LastPlayed" || echo "(no UseSteamControllerConfig in $APP_ID blocks)"
  else
    echo "(missing) $LOCALCONFIG"
  fi
} >"$dest/steam-controller.txt"

{
  echo "=== wineserver / steam.exe / FactoryGame ==="
  ps -Ao pid,ppid,etime,comm | rg -i 'wineserver|winedevice|steam\.exe|FactoryGame|crashpad_handler|CrashReport' \
    | rg -v 'rg -i|Cursor Helper|CrashReporterSupportHelper|chrome_crashpad' || echo "(none)"
} >"$dest/processes.txt"

{
  echo "label=$label"
  echo "stamp=$stamp"
  echo "bottle=$BOTTLE"
  echo "wine_user=$USER_WIN"
  echo "steam_account=$STEAM_ACCOUNT"
  echo "app_id=$APP_ID"
  echo "gus_mtime=$(mtime_of "$GUS")"
  echo "eng_mtime=$(mtime_of "$ENG")"
  echo "debugui_mtime=$(mtime_of "$DEBUGUI")"
  echo "servermgr_mtime=$(mtime_of "$SERVERMGR")"
  echo "usergamestats_mtime=$(mtime_of "$STATS")"
  echo "remotecache_mtime=$(mtime_of "$REMOTECACHE")"
  echo "manifest_files=$(grep -c $'\t' "$dest/manifest.txt" || true)"
  echo "factorygame=$(pgrep -lf FactoryGameSteam-Win64-Shipping | head -1 || echo none)"
  echo "wineserver=$(pgrep -lf '/bin/wineserver' | head -1 || echo none)"
  echo "steam_exe=$(pgrep -lf 'C:\\\\Program Files (x86)\\\\Steam\\\\steam.exe' | head -1 || echo none)"
} >"$dest/meta.txt"

{
  summarize "$dest/GameUserSettings.ini" "$dest/Engine.ini"
  echo
  echo "--- world-quit files ---"
  echo "DebugUI/Settings.data mtime=$(mtime_of "$DEBUGUI")"
  echo "SaveGames/ServerManager_V2.sav mtime=$(mtime_of "$SERVERMGR")"
  echo "UserGameStats bin mtime=$(mtime_of "$STATS")"
  echo "remotecache.vdf mtime=$(mtime_of "$REMOTECACHE")"
  echo
  echo "--- manifest ---"
  echo "files=$(grep -c $'\t' "$dest/manifest.txt" || true)  $dest/manifest.txt"
  echo
  echo "--- steam controller ---"
  cat "$dest/steam-controller.txt"
  echo
  echo "--- processes ---"
  cat "$dest/processes.txt"
} | tee "$dest/summary.txt"
echo
echo "wrote $dest"
