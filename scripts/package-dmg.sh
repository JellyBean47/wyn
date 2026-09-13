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

# GPL-3 §4: the license travels with the binary. The .app is what a person
# keeps — the image gets thrown away — so the notices go in both, and the
# copies land before signing so they are sealed by the signature.
LEGAL_DOCS=(LICENSE NOTICE COPYRIGHT THIRD_PARTY_LICENSES.md)
mkdir -p "$STAGE/Legal"
for doc in "${LEGAL_DOCS[@]}"; do
  ditto "$ROOT/$doc" "$STAGE/Legal/$doc"
  ditto "$ROOT/$doc" "$STAGE/Wyn.app/Contents/Resources/$doc"
done
ditto "$ROOT/Documentation/licenses" "$STAGE/Legal/licenses"
ditto "$ROOT/Documentation/licenses" "$STAGE/Wyn.app/Contents/Resources/licenses"

ENTITLEMENTS="$ROOT/WynApp/Wyn.entitlements"
if [[ "$IDENTITY" == "-" ]]; then
  TIMESTAMP=(--timestamp=none)
else
  TIMESTAMP=(--timestamp)
fi

# Signing the bundle does not re-sign the Mach-O helpers in Contents/Resources.
# They arrive ad-hoc signed from build.sh, and notarization rejects ad-hoc
# nested code even when the outer bundle carries a Developer ID — so sign
# inside-out. Entitlements are deliberately not passed here: they belong to the
# executable, not to libraries loaded into other processes.
echo "==> codesign nested Mach-O ($IDENTITY)"
nested=0
while IFS= read -r candidate; do
  [[ "$candidate" == "$STAGE/Wyn.app/Contents/MacOS/"* ]] && continue
  file -b "$candidate" | grep -q "Mach-O" || continue
  codesign --force --sign "$IDENTITY" --options runtime "${TIMESTAMP[@]}" "$candidate"
  nested=$((nested + 1))
done < <(find "$STAGE/Wyn.app/Contents" -type f)
echo "    $nested nested Mach-O signed"

echo "==> codesign Wyn.app ($IDENTITY)"
codesign --force --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" \
  --options runtime "${TIMESTAMP[@]}" "$STAGE/Wyn.app"
codesign --verify --deep --strict "$STAGE/Wyn.app"

DMG="$OUT_DIR/Wyn.dmg"
rm -f "$DMG"
echo "==> hdiutil $DMG"
hdiutil create -volname Wyn -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

# Gatekeeper checks the stapled ticket, so an unsigned image would still pass.
# Sign it anyway: it is what Apple's reference flow does, and it means the
# container carries the same identity as the app inside it rather than being
# anonymous.
if [[ "$IDENTITY" != "-" ]]; then
  echo "==> codesign $DMG ($IDENTITY)"
  codesign --force --sign "$IDENTITY" --timestamp "$DMG"
  codesign --verify --strict "$DMG"
fi

if (( NOTARIZE )); then
  PROFILE="${WYN_NOTARY_PROFILE:-wyn}"
  echo "==> notarytool (profile $PROFILE)"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  echo "Notarized: $DMG"
elif [[ "$IDENTITY" == "-" ]]; then
  echo "Ad-hoc image, this Mac only: $DMG"
  echo "Do not publish this as Wyn 1.0. Do not put it on wyn-dev.com."
  echo "When Developer ID is in the keychain: ./scripts/package-dmg.sh --notarize"
else
  echo "Developer ID signed but NOT notarized: $DMG"
  echo "Gatekeeper will still refuse this on another Mac. Do not publish it."
  echo "To notarize and staple: ./scripts/package-dmg.sh --notarize"
fi
