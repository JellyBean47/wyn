#!/usr/bin/env bash
# Build CLI, macOS app, and local present-helper dylibs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> swift build -c release"
swift build -c release

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
echo "==> installing Wyn.app → /Applications"
rm -rf /Applications/Wyn.app
ditto "$BUILT_APP" /Applications/Wyn.app

echo "==> native helpers (Tools/bin, not committed)"
"$ROOT/scripts/build-helpers.sh"

echo
echo "CLI:  $ROOT/.build/release/wyn"
echo "App:  /Applications/Wyn.app"
echo "Next: ./scripts/setup.sh"
