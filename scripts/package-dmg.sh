#!/usr/bin/env bash
# This file is part of Wyn.
#
# Wyn is free software: you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later
# version.
#
# Build a Wyn.dmg that contains Wyn.app only. Wine is downloaded on first
# launch. GPTK is never in the image.
#
#   ./scripts/package-dmg.sh              # ad-hoc sign (this Mac only)
#   ./scripts/package-dmg.sh --notarize   # requires Developer ID + notary profile
#
# Optional:
#   WYN_SIGN_IDENTITY   codesign identity (default: ad-hoc "-", or Developer ID if found)
#   WYN_NOTARY_PROFILE  notarytool keychain profile (default: wyn)
#   WYN_APP             existing Wyn.app to pack (skips xcodebuild)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

NOTARIZE=0
for arg in "$@"; do
  case "$arg" in
    --notarize) NOTARIZE=1 ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      echo "unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

IDENTITY="-"
if [[ -n "${WYN_SIGN_IDENTITY:-}" ]]; then
  IDENTITY="$WYN_SIGN_IDENTITY"
else
  found="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }' || true)"
  if [[ -n "$found" ]]; then
    IDENTITY="$found"
  fi
fi

if (( NOTARIZE )) && [[ "$IDENTITY" == "-" ]]; then
  echo "error: --notarize needs a Developer ID Application certificate." >&2
  echo "See Documentation/user/apple-developer.md" >&2
  "$ROOT/scripts/check-signing-identity.sh" || true
  exit 1
fi

if [[ -n "${WYN_APP:-}" ]]; then
  SRC_APP="$WYN_APP"
else
  echo "==> building Wyn.app"
  "$ROOT/scripts/build.sh"
  SRC_APP="/tmp/WynDerivedData/Build/Products/Release/Wyn.app"
fi

if [[ ! -d "$SRC_APP" ]]; then
  echo "error: Wyn.app not at $SRC_APP" >&2
  exit 1
fi

STAGE="$ROOT/.scratch/dmg-stage"
OUT_DIR="$ROOT/.scratch"
mkdir -p "$OUT_DIR"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$SRC_APP" "$STAGE/Wyn.app"
ln -s /Applications "$STAGE/Applications"

ENTITLEMENTS="$ROOT/WynApp/Wyn.entitlements"
echo "==> codesign ($IDENTITY)"
if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --sign - --entitlements "$ENTITLEMENTS" \
    --options runtime --timestamp=none "$STAGE/Wyn.app"
else
  codesign --force --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" \
    --options runtime --timestamp "$STAGE/Wyn.app"
fi
codesign --verify --deep --strict "$STAGE/Wyn.app"

DMG="$OUT_DIR/Wyn.dmg"
rm -f "$DMG"
echo "==> hdiutil $DMG"
hdiutil create -volname Wyn -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

if (( NOTARIZE )); then
  PROFILE="${WYN_NOTARY_PROFILE:-wyn}"
  echo "==> notarytool (profile $PROFILE)"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  echo "Notarized: $DMG"
else
  echo "Ad-hoc or unsigned-for-distribution image: $DMG"
  echo "Do not publish this as Wyn 1.0. Do not put it on wyn-dev.com."
  echo "When Developer ID is in the keychain: ./scripts/package-dmg.sh --notarize"
fi
