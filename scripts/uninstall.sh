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
#   - The source checkout. --clean-build handles build artifacts, opt-in.
#
# Reports before it removes, and asks you to type the word.
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

KEEP_BOTTLES=0
KEEP_CACHE=0
CLEAN_BUILD=0
ASSUME_YES=0
DRY_RUN=0

usage() {
  cat <<EOF
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
  --dry-run        Show what would be removed and exit. Removes nothing.
  -y, --yes        Do not ask for confirmation. Required when not on a terminal.
  -h, --help       This message.

Never removed: Homebrew packages (mingw-w64, ccache), anything in ~/Downloads,
or your source checkout.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-bottles) KEEP_BOTTLES=1; shift ;;
    --keep-cache)   KEEP_CACHE=1; shift ;;
    --clean-build)  CLEAN_BUILD=1; shift ;;
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

# Preference domains. Deleting the plist alone is not enough: cfprefsd caches
# them in memory and writes them straight back, which is how a "clean" install
# ends up reading a previous one's FlyRuntimeSource.
PREF_DOMAINS=()
for domain in wyn fly com.wyn.gaming; do
  if defaults read "$domain" >/dev/null 2>&1; then
    PREF_DOMAINS+=("$domain")
  fi
done

if [[ ${#TARGETS[@]} -eq 0 && ${#PREF_DOMAINS[@]} -eq 0 ]]; then
  echo "Nothing to remove — Wyn is not installed on this Mac."
  exit 0
fi

printf '%sWyn uninstall%s\n\n' "$C_HEAD" "$C_OFF"

TOTAL_KB=0
for i in "${!TARGETS[@]}"; do
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
for i in "${!TARGETS[@]}"; do
  path="${TARGETS[$i]}"
  if rm -rf "$path" 2>/dev/null; then
    echo "  removed  ${path/#$HOME/~}"
  else
    echo "  FAILED   ${path/#$HOME/~}" >&2
    failed=$((failed + 1))
  fi
done

for domain in "${PREF_DOMAINS[@]}"; do
  defaults delete "$domain" >/dev/null 2>&1 && echo "  removed  preferences: $domain"
done

# Without this the daemon rewrites the plists it still holds in memory, and the
# next install inherits settings from the one just removed.
if [[ ${#PREF_DOMAINS[@]} -gt 0 ]]; then
  killall cfprefsd >/dev/null 2>&1 || true
  echo "  restarted cfprefsd (so the preferences stay gone)"
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
