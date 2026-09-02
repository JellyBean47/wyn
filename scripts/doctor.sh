#!/usr/bin/env bash
# Wyn doctor: check what is installed against what should be, and say how to
# fix whatever is missing.
#
# Deliberately dependency-free — plain bash, no Wyn CLI required. The whole
# point is to work on a machine where nothing has been built yet, which is
# exactly when someone asks "why can't I play?". Checks that need the CLI are
# skipped with a reason, never fatal.
#
# Reports only. Never installs, never rewires. Safe to run at any time, and
# safe to paste the output into an issue.
#
# Exit 0 = nothing broken. Exit 1 = at least one FAIL.
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

SUPPORT="$HOME/Library/Application Support/com.fly.gaming"
BOTTLES="$HOME/Library/Containers/com.fly.gaming/Bottles"
LIBS="$SUPPORT/Libraries"
WINE_LIB="$LIBS/Wine/lib"
CLI="$ROOT/.build/release/wyn"
GPTK_DMG="Game_Porting_Toolkit_3.0.dmg"

FAILURES=0
WARNINGS=0
FIXES=()

if [[ -t 1 ]]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_FAIL=$'\033[31m'
  C_HEAD=$'\033[1m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_OK=""; C_WARN=""; C_FAIL=""; C_HEAD=""; C_DIM=""; C_OFF=""
fi

section() { printf '\n%s%s%s\n' "$C_HEAD" "$1" "$C_OFF"; }

ok()   { printf '  %sok%s    %s\n' "$C_OK" "$C_OFF" "$1"; }
info() { printf '  %s-%s     %s\n' "$C_DIM" "$C_OFF" "$1"; }

# warn: something is off but you can still play.
warn() {
  printf '  %swarn%s  %s\n' "$C_WARN" "$C_OFF" "$1"
  [[ -n "${2:-}" ]] && printf '        %sfix: %s%s\n' "$C_DIM" "$2" "$C_OFF"
  WARNINGS=$((WARNINGS + 1))
}

# fail: this stops you from playing.
fail() {
  printf '  %sFAIL%s  %s\n' "$C_FAIL" "$C_OFF" "$1"
  [[ -n "${2:-}" ]] && printf '        %sfix: %s%s\n' "$C_DIM" "$2" "$C_OFF"
  FAILURES=$((FAILURES + 1))
  [[ -n "${2:-}" ]] && FIXES+=("$2")
  return 0
}

printf '%sWyn doctor%s  %s\n' "$C_HEAD" "$C_OFF" "$(date '+%Y-%m-%d %H:%M')"
printf '%srepo: %s%s\n' "$C_DIM" "$ROOT" "$C_OFF"

# Is this machine set up for D3DMetal, or only DXMT? D3DMetal needs more, but
# demanding those tools from a DXMT-only user would be noise, so the extra
# checks only become failures once there is evidence D3DMetal is wanted.
WANTS_D3DMETAL=0
[[ -e "$WINE_LIB/external/libd3dshared.dylib" ]] && WANTS_D3DMETAL=1
[[ -e "$WINE_LIB/external/D3DMetal.framework" ]] && WANTS_D3DMETAL=1
[[ -L "$WINE_LIB/wine/x86_64-unix/d3d11.so" ]] && \
  [[ "$(readlink "$WINE_LIB/wine/x86_64-unix/d3d11.so" 2>/dev/null)" == *libd3dshared* ]] && WANTS_D3DMETAL=1

section "1. Build prerequisites"

if [[ "$(uname -s)" != "Darwin" ]]; then
  fail "not macOS ($(uname -s))" "Wyn is macOS only"
else
  os_major="$(sw_vers -productVersion | cut -d. -f1)"
  if (( os_major < 14 )); then
    fail "macOS $(sw_vers -productVersion) — need 14 or later" "update macOS"
  else
    ok "macOS $(sw_vers -productVersion) ($(uname -m))"
  fi
fi

if [[ "$(uname -m)" != "arm64" ]]; then
  warn "architecture is $(uname -m); Apple Silicon is the supported target"
fi

if ! xcode-select -p >/dev/null 2>&1; then
  fail "Xcode Command Line Tools missing" "xcode-select --install"
else
  ok "xcode-select: $(xcode-select -p)"
fi

if ! command -v swift >/dev/null; then
  fail "swift not on PATH" "install Xcode 16 or later"
else
  swift_ver="$(swift --version 2>/dev/null | sed -n 's/.*Swift version \([0-9]*\).*/\1/p' | head -1)"
  if [[ -n "$swift_ver" ]] && (( swift_ver < 6 )); then
    fail "Swift $swift_ver — Wyn needs Swift 6" "install Xcode 16 or later"
  else
    ok "swift $(swift --version 2>/dev/null | head -1)"
  fi
fi

command -v xcodebuild >/dev/null \
  && ok "xcodebuild present" \
  || fail "xcodebuild not on PATH" "install Xcode (not just the command line tools)"

command -v x86_64-w64-mingw32-gcc >/dev/null \
  && ok "mingw-w64 (x86_64) — Steam CEF shim" \
  || fail "x86_64-w64-mingw32-gcc missing — Steam's window stays black without the CEF shim" "brew install mingw-w64"

if [[ -e /Library/Apple/usr/share/rosetta/rosetta ]]; then
  ok "Rosetta 2 present"
else
  fail "Rosetta 2 missing — the Wine unix half is x86_64" "softwareupdate --install-rosetta"
fi

avail_gb="$(df -g "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')"
if [[ -n "$avail_gb" ]] && (( avail_gb < 3 )); then
  fail "only ${avail_gb} GiB free on the home volume — Wine needs ~3 GiB to extract" "free up disk space"
else
  ok "disk free ~${avail_gb:-?} GiB on home volume"
fi

# D3DMetal-only build tools. Advisory unless this machine already has D3DMetal.
d3d_tools_note="needed only for ./install.sh --with-d3dmetal"
for tool in ccache i686-w64-mingw32-gcc; do
  pkg="ccache"; [[ "$tool" == i686-* ]] && pkg="mingw-w64"
  if command -v "$tool" >/dev/null; then
    ok "$tool"
  elif (( WANTS_D3DMETAL )); then
    fail "$tool missing, but this Mac is set up for D3DMetal" "brew install $pkg"
  else
    info "$tool not installed ($d3d_tools_note) — brew install $pkg"
  fi
done

if command -v brew >/dev/null; then
  ok "Homebrew present"
else
  info "Homebrew not installed — needed only to install the tools above (https://brew.sh)"
fi

section "2. Wyn build"

if [[ -x "$CLI" ]]; then
  ok "CLI built: .build/release/wyn"
else
  fail "CLI not built" "./install.sh"
fi

[[ -d /Applications/Wyn.app ]] \
  && ok "Wyn.app installed" \
  || warn "/Applications/Wyn.app missing (the CLI still works without it)" "./scripts/build.sh"

if [[ -x "$HOME/.local/bin/wyn" ]]; then
  if command -v wyn >/dev/null; then
    ok "wyn on PATH"
  else
    warn "~/.local/bin/wyn exists but is not on PATH — 'wyn' will say command not found" \
         "add to ~/.zshrc:  export PATH=\"\$HOME/.local/bin:\$PATH\""
  fi
else
  info "~/.local/bin/wyn not installed — run ./install.sh, or call ./.build/release/wyn directly"
fi

section "3. Wine runtime"

if [[ ! -d "$LIBS/Wine" ]]; then
  fail "no Wine runtime installed — nothing can launch" "./install.sh"
else
  ok "Wine runtime present"

  wine_ver="none"
  for plist in WynWineVersion FlyWineVersion WhiskyWineVersion; do
    if [[ -f "$LIBS/$plist.plist" ]]; then
      wine_ver="$(defaults read "$LIBS/$plist" 2>/dev/null | tr -d '\n' | sed 's/  */ /g')"
      [[ -n "$wine_ver" ]] && break
    fi
  done
  info "version record: ${wine_ver:-unreadable}"
fi

if [[ -f "$LIBS/Wine/bin/wine64" ]]; then
  ok "wine64 present"
elif [[ -d "$LIBS/Wine" ]]; then
  fail "Wine tree exists but has no bin/wine64 — the install is incomplete" "./scripts/setup.sh"
fi

# Which Wine is this? The ntdll hook is the only reliable tell, and it decides
# whether D3DMetal can load at all.
NTDLL="$WINE_LIB/wine/x86_64-unix/ntdll.so"
IS_GAMEHOST=0
if [[ -f "$NTDLL" ]]; then
  # grep the binary directly. Piping `strings` into `grep -q` looks equivalent but
  # is not: grep -q exits on the first match, strings dies of SIGPIPE, and under
  # `set -o pipefail` the pipeline returns 141 -- so a real game-host reports as
  # frankea and section 4 FAILs on a working install.
  if grep -qa CX_APPLEGPTK_LIBD3DSHARED_PATH "$NTDLL" 2>/dev/null; then
    IS_GAMEHOST=1
    ok "Wine is the FOSS winecx game-host (D3DMetal can load)"
  else
    info "Wine is the frankea runtime (DXMT/DXVK). D3DMetal needs the winecx game-host."
  fi
fi

[[ -d "$SUPPORT/Libraries.steam" || -d "$SUPPORT/Libraries.pre-gptk-aware.bak" ]] \
  && info "frankea rollback tree present (Libraries.steam)"

section "4. D3DMetal / Apple GPTK"

if (( IS_GAMEHOST == 0 && WANTS_D3DMETAL == 0 )); then
  info "not set up for D3DMetal — DXMT is the default and needs nothing here"
  info "to add it: ./install.sh --with-d3dmetal --accept-gptk-licence"
fi

if [[ -f "$WINE_LIB/external/libd3dshared.dylib" && -d "$WINE_LIB/external/D3DMetal.framework" ]]; then
  d3dm_ver="$(defaults read "$WINE_LIB/external/D3DMetal.framework/Resources/Info" CFBundleShortVersionString 2>/dev/null || echo "?")"
  if [[ "${d3dm_ver%%.*}" =~ ^[0-9]+$ ]] && (( ${d3dm_ver%%.*} < 3 )); then
    fail "D3DMetal $d3dm_ver installed — Wyn needs 3.x" "get GPTK 3.0 from Apple, then: wyn gptk install"
  else
    ok "D3DMetal $d3dm_ver installed"
  fi

  if (( IS_GAMEHOST == 0 )); then
    fail "D3DMetal is installed but this Wine cannot load it (no ntdll GPTK hook)" \
         "./install.sh --with-d3dmetal --accept-gptk-licence"
  fi

  if [[ -f "$WINE_LIB/wine/x86_64-windows/nvngx.dll" && -f "$WINE_LIB/wine/x86_64-unix/nvngx.so" ]]; then
    ok "MetalFX/nvngx wired"
  else
    warn "MetalFX (nvngx) not wired — re-running the GPTK install overlays it" "wyn gptk install"
  fi
elif (( WANTS_D3DMETAL )); then
  # Dangling pointer: the unix modules are symlinked to a payload that is not
  # there. Wine fails to load d3d11 at all, so the game dies at startup with
  # nothing useful in the log — worth naming exactly.
  fail "the renderer points at D3DMetal but the payload is missing — games will fail to start" \
       "wyn gptk install   (or fall back: wyn renderer set dxmt)"
elif (( IS_GAMEHOST )); then
  warn "game-host Wine is installed but GPTK/D3DMetal is not" "wyn gptk install"
fi

if [[ -f "$HOME/Downloads/$GPTK_DMG" ]]; then
  info "GPTK source available: ~/Downloads/$GPTK_DMG"
elif (( IS_GAMEHOST )) && [[ ! -f "$WINE_LIB/external/libd3dshared.dylib" ]]; then
  info "no $GPTK_DMG in ~/Downloads — get it from Apple, or: wyn gptk install --pick"
fi

section "5. Renderer wiring"

UNIX_DIR="$WINE_LIB/wine/x86_64-unix"
if [[ ! -d "$UNIX_DIR" ]]; then
  info "no Wine unix modules yet — install the runtime first"
else
  wired_d3dmetal=0; wired_native=0; missing_mods=""; dangling_mods=""
  for mod in d3d11 d3d10 dxgi d3d12; do
    target="$UNIX_DIR/$mod.so"
    if [[ -L "$target" && ! -e "$target" ]]; then
      # Symlink present, target gone. Distinct from absent: the file "exists"
      # to ls but Wine cannot load it, and setup.sh would not fix it.
      dangling_mods="$dangling_mods $mod.so"
    elif [[ ! -e "$target" ]]; then
      missing_mods="$missing_mods $mod.so"
    elif [[ "$(readlink "$target" 2>/dev/null)" == *libd3dshared* ]]; then
      wired_d3dmetal=$((wired_d3dmetal + 1))
    else
      wired_native=$((wired_native + 1))
    fi
  done

  if [[ -n "$dangling_mods" ]]; then
    fail "broken renderer links (point at a file that is gone):$dangling_mods" \
         "wyn renderer set dxmt   (or reinstall D3DMetal: wyn gptk install)"
  elif [[ -n "$missing_mods" ]]; then
    fail "missing Wine D3D modules:$missing_mods" "./scripts/setup.sh"
  elif (( wired_d3dmetal > 0 && wired_native > 0 )); then
    fail "renderer is half D3DMetal, half Wine-native — games will behave unpredictably" \
         "wyn renderer set d3dmetal   (or: wyn renderer set dxmt)"
  elif (( wired_d3dmetal == 4 )); then
    ok "renderer wired: D3DMetal"
  else
    ok "renderer wired: DXMT / Wine native (the default)"
  fi
fi

section "6. Bottles and Steam"

if [[ ! -d "$BOTTLES" ]]; then
  info "no bottles yet — created on first use (wyn steam install)"
else
  bottle_count="$(find "$BOTTLES" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$bottle_count" == "0" ]]; then
    info "no bottles yet — created on first use (wyn steam install)"
  else
    ok "$bottle_count bottle(s)"
  fi

  steam_exe="$(find "$BOTTLES" -maxdepth 6 -name steam.exe -path '*Steam*' 2>/dev/null | head -1)"
  if [[ -n "$steam_exe" ]]; then
    ok "Steam installed in a bottle"
    bottle_root="${steam_exe%%/drive_c/*}"
    if [[ -n "$(find "$bottle_root" -maxdepth 8 -type d -name 'cef.win*' 2>/dev/null)" ]]; then
      if [[ -n "$(find "$bottle_root" -maxdepth 9 -name '.fly-cef-shim' 2>/dev/null)" ]]; then
        ok "Steam CEF shim applied (login window paints)"
      else
        warn "Steam CEF is not shimmed — the login window is likely to be black" "wyn steam launch"
      fi
    fi
  else
    info "Steam not installed yet — wyn steam install"
  fi
fi

section "Summary"

if (( FAILURES == 0 && WARNINGS == 0 )); then
  printf '  %sEverything checks out.%s\n' "$C_OK" "$C_OFF"
elif (( FAILURES == 0 )); then
  printf '  %s%d warning(s), nothing blocking.%s\n' "$C_WARN" "$WARNINGS" "$C_OFF"
else
  printf '  %s%d problem(s)%s and %d warning(s).\n' "$C_FAIL" "$FAILURES" "$C_OFF" "$WARNINGS"
  printf '\n  Run these, in order:\n'
  # De-duplicated, first-seen order: the checks run outermost-first, so the
  # earliest fix is usually the one that makes the later ones unnecessary.
  printed=""
  for fix in "${FIXES[@]}"; do
    case "$printed" in
      *"[$fix]"*) continue ;;
    esac
    printed="$printed[$fix]"
    printf '    %s\n' "$fix"
  done
fi

if [[ -x "$CLI" ]]; then
  printf '\n  %sMore detail: wyn gptk status | wyn renderer status | wyn doctor%s\n' "$C_DIM" "$C_OFF"
else
  printf '\n  %sBuild the CLI for deeper checks: ./install.sh%s\n' "$C_DIM" "$C_OFF"
fi

(( FAILURES == 0 ))
