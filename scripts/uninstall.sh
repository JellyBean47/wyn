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
#   - The source checkout. --clean-build handles build artifacts, opt-in;
#     --fresh-machine additionally makes it match a fresh clone.
#
# Reports before it removes, and asks you to type the word.
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

KEEP_BOTTLES=0
KEEP_CACHE=0
CLEAN_BUILD=0
FRESH_MACHINE=0
DROP_CCACHE=0
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
  --drop-ccache    Also clear ccache. Without this a "cold" winecx rebuild is
                   not cold: ccache serves most of the compile, so it finishes
                   in minutes instead of hours and the timing means nothing.
                   ccache is shared with your other projects, so they rebuild
                   cold once too.
  --dry-run        Show what would be removed and exit. Removes nothing.
  -y, --yes        Do not ask for confirmation. Required when not on a terminal.
  -h, --help       This message.

Never removed: Homebrew packages (mingw-w64, ccache), anything in ~/Downloads,
or your source checkout itself. --fresh-machine reports what still differs
from a genuinely new Mac.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-bottles) KEEP_BOTTLES=1; shift ;;
    --keep-cache)   KEEP_CACHE=1; shift ;;
    --clean-build)  CLEAN_BUILD=1; shift ;;
    --fresh-machine) FRESH_MACHINE=1; CLEAN_BUILD=1; shift ;;
    --drop-ccache)  DROP_CCACHE=1; shift ;;
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
add_target "$HOME/Library/Logs/wyn"       "logs"

if [[ "$KEEP_CACHE" -eq 0 ]]; then
  add_target "$HOME/Library/Caches/wyn"   "downloaded runtime cache"
fi

if [[ "$KEEP_BOTTLES" -eq 0 ]]; then
  add_target "$CONTAINERS"                "BOTTLES — Windows environments and every game installed in them"
fi

if [[ "$CLEAN_BUILD" -eq 1 ]]; then
  add_target "$ROOT/.build"               "Swift build products"
  add_target "$ROOT/Tools/bin"            "native helpers"
  add_target "$ROOT/.scratch"             "compiled winecx — rebuilding this takes hours"
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
      && ${#GIT_CLEAN_PATHS[@]} -eq 0 && "$DROP_CCACHE" -eq 0 ]]; then
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

printf '\n  %sTotal: about %s GB%s\n' "$C_HEAD" \
  "$(awk -v kb="$TOTAL_KB" 'BEGIN { printf "%.1f", kb/1048576 }')" "$C_OFF"

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

printf '\n  %sKept: Homebrew packages (mingw-w64, ccache), ~/Downloads, this checkout.%s\n' \
  "$C_DIM" "$C_OFF"

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf '\n  Dry run — nothing was removed.\n'
  exit 0
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

echo
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

# Without this the daemon rewrites the plists it still holds in memory, and the
# next install inherits settings from the one just removed.
if [[ ${#PREF_DOMAINS[@]} -gt 0 ]]; then
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

echo
if (( failed > 0 )); then
  echo "  $failed item(s) could not be removed — something may still be running." >&2
  echo "  Quit Wyn and Steam, then run this again." >&2
  exit 1
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
