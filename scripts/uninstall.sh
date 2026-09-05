#!/usr/bin/env bash
# Remove Wyn from this Mac: app, CLI, preferences, Wine runtime, caches, logs
# and bottles.
#
# Plain bash, no dependency on the Wyn CLI — the CLI is one of the things being
# removed, and a half-broken install is exactly when you want to start over.
#
# What it never touches:
#   - Homebrew packages (mingw-w64, ccache). Those are yours, not Wyn's, and
#     other things on your Mac use them.
#   - Anything in ~/Downloads, including the Apple GPTK disk image.
#   - The source checkout, unless --remove-checkout. --clean-build handles
#     build artifacts, --fresh-machine makes the checkout match a fresh clone,
#     and --remove-checkout deletes it outright for "leave no trace".
#
# Reports before it removes, and asks you to type the word. The report is du's
# estimate; what the volume actually gave back is measured and printed at the
# end, because on APFS those are not the same number.
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

# Free space on the volume holding $HOME, in bytes.
#
# The size report below cannot be trusted on its own. It comes from du, which
# counts logical bytes, and an APFS clone shares every block with its twin --
# so du bills the clone at full size and removing it frees nothing. That is not
# a corner case here: 'cp -Rc' is how a bottle gets parked, so a parked bottle
# and the live one under Library/Containers are the same blocks. Uninstall then
# reports "about 34 GB", removes the bottle, prints "Wyn is off this Mac", and
# hands back no disk at all.
#
# Measured on this Mac with a 500 MB file: the clone cost 0 bytes to make, du
# called it 477M, and deleting it returned 0 bytes. Deleting the original
# returned all 500 MB.
#
# So du stays -- it is the only thing that can size a target before it is gone
# -- but it is labelled an estimate, and what actually came back is measured
# afterwards and printed. A number that is checked is worth more than a number
# that is predicted.
volume_free_bytes() {
  df -k "$HOME" 2>/dev/null | tail -1 | awk '{ print $4 * 1024 }'
}

human_gb() {
  awk -v b="${1:-0}" 'BEGIN { printf "%.1f", b / 1073741824 }'
}

# Whether the gap between what du promised and what the volume gave back is
# worth saying out loud: more than 1 GiB, and more than a quarter of the
# estimate. Small gaps are ordinary -- a log written mid-run, rounding -- and a
# warning that fires every time is one nobody reads.
#
# Its own function so it can be tested without uninstalling anything:
# scripts/test-uninstall-helpers.sh.
shortfall_is_significant() {
  local estimate_bytes="${1:-0}"
  local reclaimed_bytes="${2:-0}"
  local shortfall=$(( estimate_bytes - reclaimed_bytes ))
  (( estimate_bytes > 0 ))            || return 1
  (( shortfall > 1073741824 ))        || return 1
  (( shortfall * 4 > estimate_bytes )) || return 1
  return 0
}

# Sourcing with WYN_UNINSTALL_LIB=1 defines the helpers above and stops before
# anything is inspected or removed. That is how the test script exercises them.
if [[ -n "${WYN_UNINSTALL_LIB:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi

KEEP_BOTTLES=0
KEEP_CACHE=0
CLEAN_BUILD=0
FRESH_MACHINE=0
DROP_CCACHE=0
REMOVE_CHECKOUT=0
ASSUME_YES=0
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage:
  ./scripts/uninstall.sh [options]

Removes Wyn from this Mac: /Applications/Wyn.app, ~/.local/bin/wyn, the Wine
runtime, caches, logs, preferences and bottles.

Options:
  --keep-bottles   Keep your bottles and everything installed in them.
  --keep-cache     Keep ~/Library/Caches/wyn (saves re-downloading ~317 MB).
  --clean-build    Also remove this checkout's .build, Tools/bin and .scratch.
                   .scratch is the compiled winecx tree — removing it means
                   recompiling Wine from source, which takes hours.
  --fresh-machine  Simulate a machine that has never seen Wyn: everything
                   above, plus --clean-build, plus `git clean -xdff` so the
                   checkout matches a fresh clone. Use before testing the
                   clone -> install -> compile path. Deletes untracked files
                   in the checkout — they are listed before you confirm.
  --remove-checkout
                   Also delete this checkout itself, so nothing named wyn is
                   left on the Mac. Implies --fresh-machine. Refuses if the
                   repository has uncommitted changes or unpushed commits —
                   deleting those loses work that exists nowhere else. You
                   get it back with: git clone <url>
  --drop-ccache    Also clear ccache. Without this a "cold" winecx rebuild is
                   not cold: ccache serves most of the compile, so it finishes
                   in minutes instead of hours and the timing means nothing.
                   ccache is shared with your other projects, so they rebuild
                   cold once too.
  --dry-run        Show what would be removed and exit. Removes nothing.
  -y, --yes        Do not ask for confirmation. Required when not on a terminal.
  -h, --help       This message.

Never removed: Homebrew packages (mingw-w64, ccache) and anything in
~/Downloads. The source checkout survives unless --remove-checkout.
--fresh-machine reports what still differs from a genuinely new Mac.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-bottles) KEEP_BOTTLES=1; shift ;;
    --keep-cache)   KEEP_CACHE=1; shift ;;
    --clean-build)  CLEAN_BUILD=1; shift ;;
    --fresh-machine) FRESH_MACHINE=1; CLEAN_BUILD=1; shift ;;
    --drop-ccache)  DROP_CCACHE=1; shift ;;
    --remove-checkout) REMOVE_CHECKOUT=1; FRESH_MACHINE=1; CLEAN_BUILD=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    -y|--yes)       ASSUME_YES=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; echo; usage >&2; exit 1 ;;
  esac
done

if [[ -t 1 ]]; then
  C_HEAD=$'\033[1m'; C_DIM=$'\033[2m'; C_WARN=$'\033[33m'; C_OFF=$'\033[0m'
else
  C_HEAD=""; C_DIM=""; C_WARN=""; C_OFF=""
fi

SUPPORT="$HOME/Library/Application Support/com.fly.gaming"
CONTAINERS="$HOME/Library/Containers/com.fly.gaming"

# Built in dependency order so the report reads the way removal happens.
TARGETS=()
LABELS=()

add_target() {
  [[ -e "$1" ]] || return 0
  TARGETS+=("$1")
  LABELS+=("$2")
}

add_target "/Applications/Wyn.app"        "the app"
add_target "$HOME/.local/bin/wyn"         "the wyn command"
add_target "$HOME/.local/bin/fly"         "the fly alias"
add_target "$SUPPORT"                     "Wine runtime and libraries"
# Both spellings exist on disk. The app writes under its bundle id, the CLI
# under its own name, and only the CLI ones were ever removed — leaving 18 MB
# of logs and a stale HTTP cache behind on every "complete" uninstall.
add_target "$HOME/Library/Logs/wyn"       "logs"
add_target "$HOME/Library/Logs/com.fly.gaming"        "logs (app bundle id)"
add_target "$HOME/Library/HTTPStorages/wyn"           "HTTP cache"
add_target "$HOME/Library/HTTPStorages/com.wyn.gaming" "HTTP cache (bundle id)"

if [[ "$KEEP_CACHE" -eq 0 ]]; then
  add_target "$HOME/Library/Caches/wyn"   "downloaded runtime cache"
  add_target "$HOME/Library/Caches/com.wyn.gaming" "app cache (bundle id)"
fi

if [[ "$KEEP_BOTTLES" -eq 0 ]]; then
  add_target "$CONTAINERS"                "BOTTLES — Windows environments and every game installed in them"
fi

if [[ "$CLEAN_BUILD" -eq 1 ]]; then
  add_target "$ROOT/.build"               "Swift build products"
  add_target "$ROOT/Tools/bin"            "native helpers"
  add_target "$ROOT/.scratch"             "compiled winecx — rebuilding this takes hours"
  # Xcode build output lives outside the checkout, so `git clean` never sees it
  # and a "fresh machine" still had it. Worse than wasted disk: a bundle built
  # by a bare `xcodebuild` (no -derivedDataPath) is missing the helpers
  # scripts/build.sh copies in, yet Spotlight indexes it as "Wyn" alongside the
  # real one — launch that by mistake and Steam's CEF shim is reported missing
  # on a perfectly good install.
  # /tmp/WynDerivedData is scripts/build.sh's, but ad-hoc builds over the years
  # have also left WynBottleBuild, WynDoctorBuild, WynMergeCheck and friends.
  # Three of the four found on this machine had no bundled helpers, so each was
  # a launchable Wyn.app that reports steamwebhelper_shim.exe missing — 1.8 GB
  # of bundles all called "Wyn". #35 only named WynDerivedData; glob instead.
  for td in /tmp/Wyn*; do
    [[ -d "$td" ]] || continue
    add_target "$td"                      "Xcode build products — unfinished Wyn.app bundles"
  done
  for dd in "$HOME/Library/Developer/Xcode/DerivedData"/Wyn-*; do
    [[ -d "$dd" ]] || continue
    add_target "$dd"                      "Xcode DerivedData — unfinished Wyn.app bundles"
  done
fi

# What `git clean` would take. `-ff` (not `-f`) on purpose: .scratch holds a
# nested winecx git clone, and single-f *skips* nested repositories — which
# would leave the Wine source behind and quietly make the "fresh" test false.
GIT_CLEAN_PATHS=()
if [[ "$FRESH_MACHINE" -eq 1 ]] && git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  while IFS= read -r line; do
    [[ -n "$line" ]] && GIT_CLEAN_PATHS+=("$line")
  done < <(git -C "$ROOT" clean -xdffn 2>/dev/null | sed 's/^Would remove //')
fi

CCACHE_DIR_PATH="${CCACHE_DIR:-$HOME/.ccache}"
CCACHE_HUMAN=""
if [[ "$DROP_CCACHE" -eq 1 && -d "$CCACHE_DIR_PATH" ]]; then
  CCACHE_HUMAN="$(du -sh "$CCACHE_DIR_PATH" 2>/dev/null | cut -f1)"
fi

# `swift test` writes one com.fly.gaming.tests.<UUID>.plist per run into
# ~/Library/Preferences and never cleans up. `defaults delete` only handles the
# three named domains, so these accumulate — 104 of them on the machine this was
# written on. They are Wyn's litter; remove them with everything else.
TEST_PREF_PLISTS=()
while IFS= read -r plist; do
  [[ -n "$plist" ]] && TEST_PREF_PLISTS+=("$plist")
done < <(find "$HOME/Library/Preferences" -maxdepth 1 -name 'com.fly.gaming.tests.*.plist' 2>/dev/null)

# Removing the Wine tree out from under a live wineserver leaves orphaned
# processes executing a runtime that no longer exists on disk, and the next
# install inherits them. Find them before touching anything.
RUNNING_GAME_CMDS=()
RUNNING_WINE_PIDS=()

# Wyn.app itself. The Wine scan below only considers Windows PEs, so the macOS
# app was invisible to it: the uninstaller stopped Steam and wineserver, then
# deleted /Applications/Wyn.app out from under a running app, which carried on
# executing from a bundle that no longer existed — with its window open and a
# stale Dock icon, which reads as "the uninstall did not remove the app".
# Match on the bundle path, not /Applications: a bundle built by a bare
# xcodebuild lives in DerivedData and is just as launchable (see PR #35).
RUNNING_APP_PIDS=()
while IFS= read -r apppid; do
  [[ -n "$apppid" ]] && RUNNING_APP_PIDS+=("$apppid")
done < <(pgrep -f '/Wyn\.app/Contents/MacOS/Wyn' 2>/dev/null)

while IFS= read -r wspid; do
  [[ -n "$wspid" ]] && RUNNING_WINE_PIDS+=("$wspid")
done < <(pgrep -x wineserver 2>/dev/null)

while read -r pspid pscmd; do
  [[ -n "${pscmd:-}" ]] || continue
  case "$pscmd" in
    *.exe*|*.EXE*) ;;
    *) continue ;;
  esac
  # Order matters, and not in the obvious way. Anything under steamapps is a
  # game and must be tested FIRST: Satisfactory's binary is FactoryGameSteam.exe,
  # which matches a naive *steam.exe* pattern and would have been classified as
  # the Steam client and killed — force-closing a running game, which Wyn must
  # never do. steamwebhelper next, because its command line carries
  # -steampath=…\steam.exe. Only then the client itself, matched on its real
  # path rather than a bare filename.
  case "$pscmd" in
    *steamapps*)      RUNNING_GAME_CMDS+=("$pscmd"); RUNNING_WINE_PIDS+=("$pspid") ;;
    *steamwebhelper*) RUNNING_WINE_PIDS+=("$pspid") ;;
    *\\[Ss]team\\[Ss]team.exe*) RUNNING_WINE_PIDS+=("$pspid") ;;
  esac
done < <(ps -ax -o pid=,command= 2>/dev/null)

# --remove-checkout deletes the directory this script is running from, so the
# checks are worth more than the feature. Refuse unless ROOT really is a Wyn
# checkout, and refuse to destroy work that exists only here.
CHECKOUT_SIZE=""
CHECKOUT_REFUSAL=""
if [[ "$REMOVE_CHECKOUT" -eq 1 ]]; then
  case "$ROOT" in
    "" | / | /Users | /Users/* )
      # /Users/<name> alone is a home directory; anything deeper is fine.
      if [[ "$ROOT" == "$HOME" || "$ROOT" == "/Users" || "$ROOT" == "/" ]]; then
        echo "error: --remove-checkout refuses to delete $ROOT" >&2
        exit 1
      fi
      ;;
  esac
  for marker in install.sh scripts/uninstall.sh .git; do
    if [[ ! -e "$ROOT/$marker" ]]; then
      echo "error: $ROOT does not look like a Wyn checkout (missing $marker)." >&2
      echo "Refusing to delete it." >&2
      exit 1
    fi
  done

  if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    # Collected, not raised, so --dry-run can report "this would refuse"
    # instead of erroring out. A dry run should never fail.
    dirty="$(git -C "$ROOT" status --porcelain=v1 --untracked-files=no 2>/dev/null)"
    if [[ -n "$dirty" ]]; then
      CHECKOUT_REFUSAL="uncommitted changes:"$'\n'"$dirty"$'\n\n'"Commit or discard them before --remove-checkout."
    fi
    unpushed="$(git -C "$ROOT" log --branches --not --remotes --oneline 2>/dev/null)"
    if [[ -z "$CHECKOUT_REFUSAL" && -n "$unpushed" ]]; then
      CHECKOUT_REFUSAL="commits that are not on any remote:"$'\n'"$unpushed"$'\n\n'"Push them before --remove-checkout — deleting loses them for good."
    fi
  fi
  CHECKOUT_SIZE="$(du -sh "$ROOT" 2>/dev/null | cut -f1)"
fi

# Preference domains. Deleting the plist alone is not enough: cfprefsd caches
# them in memory and writes them straight back, which is how a "clean" install
# ends up reading a previous one's FlyRuntimeSource.
PREF_DOMAINS=()
for domain in wyn fly com.wyn.gaming; do
  if defaults read "$domain" >/dev/null 2>&1; then
    PREF_DOMAINS+=("$domain")
  fi
done

# --fresh-machine and --drop-ccache still have work to do on a Mac where Wyn is
# already uninstalled — which is exactly the state you are in when you decide to
# simulate a clean machine. Only bail when there is genuinely nothing left.
if [[ ${#TARGETS[@]} -eq 0 && ${#PREF_DOMAINS[@]} -eq 0 \
      && ${#GIT_CLEAN_PATHS[@]} -eq 0 && "$DROP_CCACHE" -eq 0 \
      && ${#TEST_PREF_PLISTS[@]} -eq 0 && ${#RUNNING_WINE_PIDS[@]} -eq 0 \
      && ${#RUNNING_APP_PIDS[@]} -eq 0 && "$REMOVE_CHECKOUT" -eq 0 ]]; then
  echo "Nothing to remove — Wyn is not installed on this Mac."
  exit 0
fi

printf '%sWyn uninstall%s\n\n' "$C_HEAD" "$C_OFF"

TOTAL_KB=0
# `set -u` + bash 3.2 treats "${arr[@]}" on an empty array as unbound. The early
# exit used to make that unreachable; --fresh-machine on an already-uninstalled
# Mac reaches it, so every array iteration below is guarded by count.
for i in ${TARGETS[@]+"${!TARGETS[@]}"}; do
  path="${TARGETS[$i]}"
  label="${LABELS[$i]}"
  size_kb=$(du -sk "$path" 2>/dev/null | cut -f1)
  size_kb=${size_kb:-0}
  TOTAL_KB=$((TOTAL_KB + size_kb))
  human=$(du -sh "$path" 2>/dev/null | cut -f1)
  printf '  %8s  %s\n' "${human:-?}" "${path/#$HOME/~}"
  printf '            %s%s%s\n' "$C_DIM" "$label" "$C_OFF"
done

if [[ ${#PREF_DOMAINS[@]} -gt 0 ]]; then
  printf '  %8s  preferences: %s\n' "-" "${PREF_DOMAINS[*]}"
fi

if [[ ${#TEST_PREF_PLISTS[@]} -gt 0 ]]; then
  printf '  %8s  %d leftover com.fly.gaming.tests.*.plist (one per swift test run)\n' \
    "-" "${#TEST_PREF_PLISTS[@]}"
fi

if [[ ${#RUNNING_WINE_PIDS[@]} -gt 0 ]]; then
  printf '  %8s  %d Wine/Steam process(es) still running — stopped first\n' \
    "-" "${#RUNNING_WINE_PIDS[@]}"
fi

if [[ ${#RUNNING_APP_PIDS[@]} -gt 0 ]]; then
  printf '  %8s  Wyn.app is running — quit first\n' "-"
fi

TOTAL_HUMAN="$(awk -v kb="$TOTAL_KB" 'BEGIN { printf "%.1f", kb/1048576 }')"
printf '\n  %sTotal: about %s GB%s %s(logical size)%s\n' "$C_HEAD" \
  "$TOTAL_HUMAN" "$C_OFF" "$C_DIM" "$C_OFF"
printf '  %sA parked copy made with '"'"'cp -Rc'"'"' shares its blocks with the original,%s\n' \
  "$C_DIM" "$C_OFF"
printf '  %sso removing either one frees less than this, or nothing at all.%s\n' \
  "$C_DIM" "$C_OFF"
printf '  %sWhat actually came back is measured and reported at the end.%s\n' \
  "$C_DIM" "$C_OFF"

if [[ "$KEEP_BOTTLES" -eq 0 && -e "$CONTAINERS" ]]; then
  printf '\n  %sThis removes your bottles, and any game installed inside them.%s\n' "$C_WARN" "$C_OFF"
  printf '  %sKeep them with: --keep-bottles%s\n' "$C_DIM" "$C_OFF"
fi

if [[ ${#GIT_CLEAN_PATHS[@]} -gt 0 ]]; then
  printf '\n  %s%d untracked/ignored item(s) in the checkout will also go,%s\n' \
    "$C_WARN" "${#GIT_CLEAN_PATHS[@]}" "$C_OFF"
  printf '  %sleaving it identical to a fresh clone:%s\n' "$C_WARN" "$C_OFF"
  shown=0
  for gc in ${GIT_CLEAN_PATHS[@]+"${GIT_CLEAN_PATHS[@]}"}; do
    if (( shown < 8 )); then
      printf '    %s%s%s\n' "$C_DIM" "$gc" "$C_OFF"
      shown=$((shown + 1))
    fi
  done
  if (( ${#GIT_CLEAN_PATHS[@]} > shown )); then
    printf '    %s… and %d more%s\n' "$C_DIM" "$(( ${#GIT_CLEAN_PATHS[@]} - shown ))" "$C_OFF"
  fi
fi

if [[ "$DROP_CCACHE" -eq 1 ]]; then
  printf '\n  %sccache will be cleared%s' "$C_WARN" "$C_OFF"
  [[ -n "$CCACHE_HUMAN" ]] && printf ' %s(%s)%s' "$C_DIM" "$CCACHE_HUMAN" "$C_OFF"
  printf '\n  %sYour other projects share it and will rebuild cold once too.%s\n' "$C_DIM" "$C_OFF"
elif [[ "$FRESH_MACHINE" -eq 1 ]]; then
  printf '\n  %sccache is being KEPT — the next winecx build will not be cold.%s\n' "$C_WARN" "$C_OFF"
  printf '  %sFor a real cold-build measurement add: --drop-ccache%s\n' "$C_DIM" "$C_OFF"
fi

if [[ "$REMOVE_CHECKOUT" -eq 1 ]]; then
  printf '\n  %sTHE CHECKOUT ITSELF WILL BE DELETED%s' "$C_WARN" "$C_OFF"
  [[ -n "$CHECKOUT_SIZE" ]] && printf ' %s(%s)%s' "$C_DIM" "$CHECKOUT_SIZE" "$C_OFF"
  printf '\n    %s%s%s\n' "$C_DIM" "$ROOT" "$C_OFF"
  if [[ -n "$CHECKOUT_REFUSAL" ]]; then
    printf '  %s-> but this will REFUSE: %s%s\n' "$C_WARN" "${CHECKOUT_REFUSAL%%$'\n'*}" "$C_OFF"
  else
    printf '  %sEverything in it is on the remote; get it back with: git clone <url>%s\n' \
      "$C_DIM" "$C_OFF"
  fi
  printf '\n  %sKept: Homebrew packages (mingw-w64, ccache), ~/Downloads.%s\n' \
    "$C_DIM" "$C_OFF"
else
  printf '\n  %sKept: Homebrew packages (mingw-w64, ccache), ~/Downloads, this checkout.%s\n' \
    "$C_DIM" "$C_OFF"
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf '\n  Dry run — nothing was removed.\n'
  exit 0
fi

if [[ -n "$CHECKOUT_REFUSAL" ]]; then
  echo >&2
  echo "error: this checkout has $CHECKOUT_REFUSAL" >&2
  exit 1
fi

# A running game is the one thing worth stopping for: deleting the runtime
# under it loses unsaved progress, and Wyn never force-closes a game. Refuse
# even with --yes, because nobody passes --yes meaning "and kill my game".
if [[ ${#RUNNING_GAME_CMDS[@]} -gt 0 ]]; then
  echo >&2
  echo "error: a game is still running in a Wyn bottle." >&2
  for gamecmd in ${RUNNING_GAME_CMDS[@]+"${RUNNING_GAME_CMDS[@]}"}; do
    printf '  %s\n' "${gamecmd:0:100}" >&2
  done
  echo >&2
  echo "Quit it from its own window, then run this again." >&2
  exit 1
fi

if [[ "$ASSUME_YES" -eq 0 ]]; then
  # No terminal means nobody can answer. Refuse rather than purge unattended.
  if [[ ! -t 0 ]]; then
    echo >&2
    echo "error: refusing to uninstall without confirmation." >&2
    echo "Re-run with --yes, or --dry-run to see what would be removed." >&2
    exit 1
  fi
  printf '\n  Type %swyn%s to confirm: ' "$C_HEAD" "$C_OFF"
  read -r typed
  if [[ "$(echo "$typed" | tr '[:upper:]' '[:lower:]')" != "wyn" ]]; then
    echo "  Not removed."
    exit 0
  fi
fi

# Read before anything is stopped or removed, so the figure at the end covers
# the whole run.
FREE_BEFORE="$(volume_free_bytes)"

echo

# Stop first, remove second. The other order deletes the runtime out from under
# a live wineserver, which then keeps running against a tree that no longer
# exists — and the next install inherits that orphan. No game is running here:
# the check above refuses outright if one is.
# Quit the app before its bundle is deleted, for the same reason the Wine
# processes are stopped before the runtime goes. Deliberately NOT the
# refuse-and-exit treatment a running game gets: a running launcher is not
# unsaved progress, so quit it rather than making the user do it.
if [[ ${#RUNNING_APP_PIDS[@]} -gt 0 ]]; then
  # Ask nicely first so the app can close its own windows and save state.
  osascript -e 'quit app "Wyn"' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8; do
    alive=0
    for apid in ${RUNNING_APP_PIDS[@]+"${RUNNING_APP_PIDS[@]}"}; do
      kill -0 "$apid" 2>/dev/null && alive=1
    done
    (( alive == 0 )) && break
    sleep 1
  done
  for apid in ${RUNNING_APP_PIDS[@]+"${RUNNING_APP_PIDS[@]}"}; do
    kill -0 "$apid" 2>/dev/null && kill "$apid" 2>/dev/null || true
  done
  sleep 1
  for apid in ${RUNNING_APP_PIDS[@]+"${RUNNING_APP_PIDS[@]}"}; do
    kill -0 "$apid" 2>/dev/null && kill -9 "$apid" 2>/dev/null || true
  done
  echo "  quit     Wyn.app"
fi

if [[ ${#RUNNING_WINE_PIDS[@]} -gt 0 ]]; then
  kill ${RUNNING_WINE_PIDS[@]+"${RUNNING_WINE_PIDS[@]}"} 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    alive=0
    for wpid in ${RUNNING_WINE_PIDS[@]+"${RUNNING_WINE_PIDS[@]}"}; do
      kill -0 "$wpid" 2>/dev/null && alive=1
    done
    (( alive == 0 )) && break
    sleep 1
  done
  for wpid in ${RUNNING_WINE_PIDS[@]+"${RUNNING_WINE_PIDS[@]}"}; do
    kill -0 "$wpid" 2>/dev/null && kill -9 "$wpid" 2>/dev/null || true
  done
  echo "  stopped  ${#RUNNING_WINE_PIDS[@]} Wine/Steam process(es)"
fi

failed=0
for i in ${TARGETS[@]+"${!TARGETS[@]}"}; do
  path="${TARGETS[$i]}"
  if rm -rf "$path" 2>/dev/null; then
    echo "  removed  ${path/#$HOME/~}"
  else
    echo "  FAILED   ${path/#$HOME/~}" >&2
    failed=$((failed + 1))
  fi
done

for domain in ${PREF_DOMAINS[@]+"${PREF_DOMAINS[@]}"}; do
  defaults delete "$domain" >/dev/null 2>&1 && echo "  removed  preferences: $domain"
done

if [[ ${#TEST_PREF_PLISTS[@]} -gt 0 ]]; then
  removed_tests=0
  for plist in ${TEST_PREF_PLISTS[@]+"${TEST_PREF_PLISTS[@]}"}; do
    rm -f "$plist" 2>/dev/null && removed_tests=$((removed_tests + 1))
  done
  echo "  removed  $removed_tests leftover com.fly.gaming.tests.*.plist"
fi

# Without this the daemon rewrites the plists it still holds in memory, and the
# next install inherits settings from the one just removed.
if [[ ${#PREF_DOMAINS[@]} -gt 0 || ${#TEST_PREF_PLISTS[@]} -gt 0 ]]; then
  killall cfprefsd >/dev/null 2>&1 || true
  echo "  restarted cfprefsd (so the preferences stay gone)"
fi

if [[ ${#GIT_CLEAN_PATHS[@]} -gt 0 ]]; then
  if git -C "$ROOT" clean -xdff >/dev/null 2>&1; then
    echo "  removed  ${#GIT_CLEAN_PATHS[@]} untracked/ignored item(s) — checkout now matches a fresh clone"
  else
    echo "  FAILED   git clean in $ROOT" >&2
    failed=$((failed + 1))
  fi
fi

if [[ "$DROP_CCACHE" -eq 1 ]]; then
  if command -v ccache >/dev/null 2>&1 && ccache --clear >/dev/null 2>&1; then
    echo "  cleared  ccache${CCACHE_HUMAN:+ ($CCACHE_HUMAN)} — the next winecx build is genuinely cold"
  elif [[ -d "$CCACHE_DIR_PATH" ]] && rm -rf "$CCACHE_DIR_PATH" 2>/dev/null; then
    echo "  removed  ${CCACHE_DIR_PATH/#$HOME/~}"
  else
    echo "  note     no ccache found to clear"
  fi
fi

# What actually came back. The line above the confirmation is du's guess; this
# is the volume's own answer, and the two disagree exactly when a target was
# cloned. Reporting only the guess is how an uninstall can free nothing and
# still read like it freed 34 GB.
sleep 1
FREE_AFTER="$(volume_free_bytes)"
if [[ -n "${FREE_BEFORE:-}" && -n "${FREE_AFTER:-}" ]]; then
  RECLAIMED=$((FREE_AFTER - FREE_BEFORE))
  (( RECLAIMED < 0 )) && RECLAIMED=0
  echo
  printf '  %sReclaimed: %s GB%s %s(estimated %s GB)%s\n' \
    "$C_HEAD" "$(human_gb "$RECLAIMED")" "$C_OFF" "$C_DIM" "$TOTAL_HUMAN" "$C_OFF"

  ESTIMATE_BYTES=$(( TOTAL_KB * 1024 ))
  SHORTFALL=$(( ESTIMATE_BYTES - RECLAIMED ))
  if shortfall_is_significant "$ESTIMATE_BYTES" "$RECLAIMED"; then
    printf '  %s%s GB of that is still on this Mac, shared with a copy of its own:%s\n' \
      "$C_WARN" "$(human_gb "$SHORTFALL")" "$C_OFF"
    printf '  %sremoving one side of an APFS clone frees nothing. Parked bottles%s\n' \
      "$C_WARN" "$C_OFF"
    printf '  %sare the usual reason. Find them with:%s\n' "$C_WARN" "$C_OFF"
    printf "  %s  find ~ -maxdepth 3 -name 'Application Support-com.fly.gaming'%s\n" \
      "$C_DIM" "$C_OFF"
  fi

  if [[ "$REMOVE_CHECKOUT" -eq 1 ]]; then
    printf '  %sThe checkout is removed after this line, so it is not counted here.%s\n' \
      "$C_DIM" "$C_OFF"
  fi
fi

echo
if (( failed > 0 )); then
  echo "  $failed item(s) could not be removed — something may still be running." >&2
  echo "  Quit Wyn and Steam, then run this again." >&2
  exit 1
fi

# Deleting a bundle does not unregister it. LaunchServices keeps the record, so
# Spotlight, Launchpad and the Dock go on offering a "Wyn" that is not there —
# and launching one gives "Wyn is damaged and can't be opened", which reads as a
# broken install rather than a stale entry. Six were registered on this machine,
# five of them gone or unfinished. Sweep whatever no longer exists.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  unregistered=0
  while IFS= read -r bundle; do
    [[ -n "$bundle" ]] || continue
    [[ -d "$bundle" ]] && continue
    "$LSREGISTER" -u "$bundle" 2>/dev/null && unregistered=$((unregistered + 1))
  done < <(
    "$LSREGISTER" -dump 2>/dev/null \
      | sed -n 's|^[[:space:]]*path:[[:space:]]*\(.*/Wyn\.app\) (0x.*|\1|p' \
      | sort -u
  )
  if (( unregistered > 0 )); then
    echo "  removed  $unregistered stale Wyn.app record(s) from LaunchServices"
  fi
fi

printf '  %sWyn is off this Mac.%s\n' "$C_HEAD" "$C_OFF"
echo "  Reinstall with: ./install.sh"
if [[ "$KEEP_BOTTLES" -eq 1 ]]; then
  echo "  Your bottles were kept at ${CONTAINERS/#$HOME/~}"
fi
if [[ "$CLEAN_BUILD" -eq 0 && -d "$ROOT/.scratch" ]]; then
  echo "  The compiled winecx tree was kept, so D3DMetal will not need rebuilding."
fi

# Be honest about what a fresh-machine simulation still cannot reproduce, so a
# green run here is not mistaken for "a new Mac would work".
if [[ "$FRESH_MACHINE" -eq 1 ]]; then
  gaps=()
  # Capture once, then match. `brew list | grep -q` would exit grep early, give
  # brew a SIGPIPE, and `pipefail` turns that 141 into a silent "not found" —
  # the same defect fixed in doctor.sh (PR #29). Do not reintroduce it.
  brew_formulae=""
  if command -v brew >/dev/null 2>&1; then
    brew_formulae="$(brew list --formula 2>/dev/null)"
  fi
  for formula in mingw-w64 ccache; do
    case $'\n'"$brew_formulae"$'\n' in
      *$'\n'"$formula"$'\n'*)
        gaps+=("Homebrew still has $formula — a new Mac has neither, so install.sh --install-missing-tools stays untested")
        ;;
    esac
  done
  if [[ "$DROP_CCACHE" -eq 0 && -d "$CCACHE_DIR_PATH" ]]; then
    gaps+=("ccache is still warm — the winecx compile will be far faster than on a new Mac (--drop-ccache)")
  fi
  if compgen -G "$HOME/Downloads/Game_Porting_Toolkit*.dmg" >/dev/null 2>&1; then
    gaps+=("the GPTK disk image is still in ~/Downloads — a new Mac downloads it first")
  fi
  gaps+=("Xcode, the Swift toolchain and Rosetta are still installed")

  echo
  printf '  %sStill unlike a new Mac:%s\n' "$C_HEAD" "$C_OFF"
  for gap in ${gaps[@]+"${gaps[@]}"}; do
    printf '    %s- %s%s\n' "$C_DIM" "$gap" "$C_OFF"
  done
fi

# Last act, and it has to be done from outside the tree. bash reads a script
# incrementally, so a script that deletes its own file mid-run can end up
# executing garbage — and the cwd would vanish underneath it too. Hand the job
# to a helper in the temp dir and exec it, so nothing left in this process
# depends on ROOT still existing.
if [[ "$REMOVE_CHECKOUT" -eq 1 ]]; then
  helper="$(mktemp -t wyn-remove-checkout)" || exit 1
  cat > "$helper" <<'HELPER'
#!/usr/bin/env bash
set -uo pipefail
target="$1"
self="$2"
rm -rf "$target"
if [[ -e "$target" ]]; then
  echo "  FAILED   could not remove $target" >&2
  rm -f "$self"
  exit 1
fi
echo
echo "  removed  $target"
echo "  Nothing named wyn is left on this Mac."
rm -f "$self"
HELPER
  chmod +x "$helper"
  cd /
  exec "$helper" "$ROOT" "$helper"
fi
