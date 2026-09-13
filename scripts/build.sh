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
# Build CLI, macOS app, and local present-helper dylibs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> swift build -c release"
swift build -c release

# Helpers first: they are copied into Wyn.app below, so building them after the
# app shipped an app that could only find them by reaching back into this
# checkout — which an installed app must not rely on.
echo "==> native helpers (Tools/bin, not committed)"
"$ROOT/scripts/build-helpers.sh"
# Separate script: this one needs no mingw-w64, and a Vulkan title should not
# be gated on a Windows cross-compiler being installed.
"$ROOT/scripts/build-mvkshim.sh"

echo "==> xcodebuild Wyn.app (ad-hoc sign)"
xcodebuild -project Wyn.xcodeproj -scheme Wyn -configuration Release \
  -derivedDataPath /tmp/WynDerivedData \
  build CODE_SIGN_IDENTITY="-" \
  | tail -20

BUILT_APP="/tmp/WynDerivedData/Build/Products/Release/Wyn.app"
if [[ ! -d "$BUILT_APP" ]]; then
  echo "error: Wyn.app missing at $BUILT_APP" >&2
  exit 1
fi

# Wyn.app has to carry its own helpers. Without steamwebhelper_shim.exe inside
# the bundle, Steam's login window paints black for anyone whose checkout has
# moved, been deleted, or simply is not readable by the app.
echo "==> bundling native helpers into Wyn.app"
HELPERS=(
  steamwebhelper_shim.exe
  fly_stretch_epi_bridge.dylib
  fly_stretch_epi_bridge.fast.dylib
  present_force_inject.dylib
  winemac_rtld_global.dylib
  fly_mvkshim.dylib
)
copied=0
for helper in "${HELPERS[@]}"; do
  src="$ROOT/Tools/bin/$helper"
  if [[ -f "$src" ]]; then
    ditto "$src" "$BUILT_APP/Contents/Resources/$helper"
    copied=$((copied + 1))
  else
    echo "warning: $helper not built; Wyn.app will not carry it" >&2
  fi
done
echo "    $copied/${#HELPERS[@]} helpers bundled"

# The CLI rides inside the app too. Someone who installed from the disk image
# has no checkout and no ~/.local/bin, so without this `wyn` simply does not
# exist for them — and with it, "Install Command Line Tool" in the app is a
# copy out of Resources rather than a build. SPM links WynKit statically and
# Swift's runtime ships with macOS, so the single binary relocates cleanly;
# that is already how it reaches ~/.local/bin below.
if [[ -f "$ROOT/.build/release/wyn" ]]; then
  ditto "$ROOT/.build/release/wyn" "$BUILT_APP/Contents/Resources/wyn"
  copied=$((copied + 1))
  echo "    wyn CLI bundled"
else
  echo "warning: .build/release/wyn missing; Wyn.app will not carry the CLI" >&2
fi

# Adding files invalidates the signature xcodebuild just applied, and an app
# with a broken signature will not launch under the hardened runtime.
if (( copied > 0 )); then
  echo "==> re-signing Wyn.app (ad-hoc, after adding resources)"
  codesign --force --sign - --entitlements WynApp/Wyn.entitlements \
    --options runtime --timestamp=none "$BUILT_APP"
  codesign --verify --deep --strict "$BUILT_APP" \
    || { echo "error: Wyn.app signature is not valid after bundling" >&2; exit 1; }
fi

echo "==> installing Wyn.app → /Applications"
rm -rf /Applications/Wyn.app
ditto "$BUILT_APP" /Applications/Wyn.app

# xcodebuild ends a Release build with RegisterWithLaunchServices on the build
# product, so /tmp/WynDerivedData/.../Wyn.app becomes a real app as far as
# Spotlight, Launchpad and every "choose an application" list are concerned.
# After install there are then two Wyns with the same icon and name, the wrong
# one is a build artifact, and picking it runs an app that will vanish on the
# next `rm -rf /tmp`. Xcode's own Debug builds under ~/Library/Developer add
# more of the same.
#
# So: unregister and delete the copies that are not the installed app. The
# object files stay, so the next build is still incremental — only the bundle
# is relinked.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  echo "==> unregistering build-product Wyn.app copies (Spotlight duplicates)"
  while IFS= read -r stray; do
    [[ "$stray" == "/Applications/Wyn.app" ]] && continue
    "$LSREGISTER" -u "$stray" 2>/dev/null || true
    # Only ever remove a build product, never something a person installed.
    case "$stray" in
      /private/tmp/WynDerivedData/*|/tmp/WynDerivedData/*|"$HOME"/Library/Developer/Xcode/DerivedData/*)
        rm -rf "$stray"
        echo "    removed $stray"
        ;;
      *)
        # Not a build product, so not ours to delete — it may be a parked copy
        # or a second install someone made on purpose. The registration is the
        # only thing removed, and the path may not even exist any more (a stale
        # registration for a deleted app also shows up in app pickers).
        echo "    unregistered, not deleted: $stray"
        ;;
    esac
  done < <("$LSREGISTER" -dump 2>/dev/null | grep -oE '/[^ ]*/Wyn\.app' | sort -u)
  # Re-assert the installed one, since unregistering siblings can drop it too.
  "$LSREGISTER" -f "/Applications/Wyn.app" 2>/dev/null || true
fi

# Keep the `wyn` on PATH in step with the build.
#
# install.sh used to be the only thing that placed it, and install.sh runs once.
# Every rebuild after that left the copy on PATH older than the code — and
# anything pointing at that path went on running the old binary with no sign
# that it was doing so. An MCP client is the worst case: it fails with
# "unknown subcommand" or, more confusingly, works but with yesterday's tools.
# Whatever produces the binary is what should install it.
BIN_DIR="$HOME/.local/bin"
echo "==> installing wyn → $BIN_DIR"
mkdir -p "$BIN_DIR"
# Remove first: overwriting a binary that is currently running fails with
# "Text file busy", and an MCP server started by a client is exactly that.
# Unlinking leaves the running process alone and the next start picks this up.
rm -f "$BIN_DIR/wyn"
cp "$ROOT/.build/release/wyn" "$BIN_DIR/wyn"
chmod +x "$BIN_DIR/wyn"
ln -sfn "$BIN_DIR/wyn" "$BIN_DIR/fly"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo "    note: $BIN_DIR is not on your PATH, so 'wyn' will not be found." >&2
    echo "          add to ~/.zshrc:  export PATH=\"\$HOME/.local/bin:\$PATH\"" >&2
    ;;
esac

echo
echo "CLI:  $BIN_DIR/wyn  (also $ROOT/.build/release/wyn)"
echo "App:  /Applications/Wyn.app"
echo "Next: ./scripts/setup.sh"
