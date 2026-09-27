#!/usr/bin/env bash
# This file is part of Wyn.
#
# Wyn is free software: you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later
# version.
#
# Build Wyn.dmg.
#
#   ./scripts/package-dmg.sh                         # app only; Wine downloads on first launch
#   ./scripts/package-dmg.sh --with-runtime DIR      # 1.1+: the app carries its runtime + GPTK
#   ./scripts/package-dmg.sh ... --notarize          # requires Developer ID + notary profile
#
# --with-runtime takes the output of scripts/stage-runtime.sh. It goes into
# Wyn.app/Contents/SharedSupport/Runtime, is signed by sign-runtime.sh (Wine
# entitlements on the executables, Apple's GPTK left exactly as Apple signed
# it), and its licences go into Legal/. See Documentation/user/packaging.md
# for what a public release additionally owes (the corresponding source).
#
# Optional:
#   WYN_SIGN_IDENTITY   codesign identity (default: ad-hoc "-", or Developer ID if found)
#   WYN_NOTARY_PROFILE  notarytool keychain profile (default: wyn)
#   WYN_APP             existing Wyn.app to pack (skips the build)
#   WYN_DMG_FORMAT      hdiutil format (default UDZO; ULMO with a runtime)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

NOTARIZE=0
RUNTIME=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --notarize) NOTARIZE=1; shift ;;
    --with-runtime)
      [[ -n "${2:-}" ]] || { echo "error: --with-runtime needs a directory" >&2; exit 1; }
      RUNTIME="$(cd "$2" && pwd)"; shift 2 ;;
    -h|--help)
      sed -n '2,26p' "$0"
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -n "$RUNTIME" ]]; then
  for need in Libraries/Wine/bin/wine64 GPTK/License.rtf GPTK/redist licenses RUNTIME-MANIFEST.txt; do
    [[ -e "$RUNTIME/$need" ]] || { echo "error: $RUNTIME/$need missing: run scripts/stage-runtime.sh" >&2; exit 1; }
  done
fi

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
  # Not installed: packaging must never replace the Wyn.app someone is using,
  # and from 1.1 the app it packs carries a runtime that /Applications should
  # only get from a real install.
  WYN_NO_INSTALL=1 "$ROOT/scripts/build.sh"
  SRC_APP="/tmp/WynDerivedData/Build/Products/Release/Wyn.app"
  # Prove it is the build that just ran rather than trusting the path: the CLI
  # build.sh bundled into the app must be byte-identical to the one it compiled.
  bundled_cli="$SRC_APP/Contents/Resources/wyn"
  built_cli="$ROOT/.build/release/wyn"
  if [[ ! -f "$bundled_cli" || ! -f "$built_cli" ]] || ! cmp -s "$bundled_cli" "$built_cli"; then
    echo "error: $SRC_APP is not the Wyn.app build.sh just produced" >&2
    echo "       (bundled CLI does not match $built_cli)" >&2
    exit 1
  fi
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

# The build product stays registered with LaunchServices otherwise, and shows
# up as a second Wyn in Spotlight (see build.sh).
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Support/lsregister"
[[ -z "${WYN_APP:-}" && -x "$LSREGISTER" ]] && "$LSREGISTER" -u "$SRC_APP" 2>/dev/null || true

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

APP_RUNTIME="$STAGE/Wyn.app/Contents/SharedSupport/Runtime"
if [[ -n "$RUNTIME" ]]; then
  echo "==> embedding runtime from $RUNTIME"
  ditto "$RUNTIME" "$APP_RUNTIME"
  # Apple's notices must accompany every copy of GPTK (SLA §2A), and the
  # runtime's LGPL/MIT/zlib notices every copy of those binaries. The copies
  # inside the app are sealed by its signature; these are for the reader.
  mkdir -p "$STAGE/Legal/runtime"
  ditto "$RUNTIME/licenses" "$STAGE/Legal/runtime/licenses"
  cp "$RUNTIME/RUNTIME-MANIFEST.txt" "$STAGE/Legal/runtime/"
  cp "$RUNTIME/GPTK/License.rtf" "$STAGE/Legal/runtime/Apple GPTK License.rtf"
  cp "$RUNTIME/GPTK/Acknowledgements.rtf" "$STAGE/Legal/runtime/Apple GPTK Acknowledgements.rtf"
  "$ROOT/scripts/sign-runtime.sh" "$APP_RUNTIME" "$IDENTITY"
fi

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
#
# The runtime is skipped: sign-runtime.sh already signed it, re-signing here
# would strip the Wine executables' entitlements, and GPTK/ is Apple's code
# under Apple's signature, which this loop must never replace.
echo "==> codesign nested Mach-O ($IDENTITY)"
nested=0
while IFS= read -r candidate; do
  [[ "$candidate" == "$STAGE/Wyn.app/Contents/MacOS/"* ]] && continue
  [[ "$candidate" == "$APP_RUNTIME/"* ]] && continue
  file -b "$candidate" | grep -q "Mach-O" || continue
  codesign --force --sign "$IDENTITY" --options runtime "${TIMESTAMP[@]}" "$candidate"
  nested=$((nested + 1))
done < <(find "$STAGE/Wyn.app/Contents" -type f)
echo "    $nested nested Mach-O signed"

echo "==> codesign Wyn.app ($IDENTITY)"
codesign --force --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" \
  --options runtime "${TIMESTAMP[@]}" "$STAGE/Wyn.app"
codesign --verify --deep --strict "$STAGE/Wyn.app"
if [[ -n "$RUNTIME" ]]; then
  for code in D3DMetal.framework libd3dshared.dylib; do
    codesign --verify --strict -R="anchor apple" "$APP_RUNTIME/GPTK/redist/lib/external/$code" \
      || { echo "error: $code inside Wyn.app lost Apple's signature" >&2; exit 1; }
  done
fi

DMG="$OUT_DIR/Wyn.dmg"
rm -f "$DMG"
# A runtime makes the image ~1 GB before compression; LZMA (macOS 10.15+, and
# Wyn needs 14) is what keeps the download tolerable on a slow line.
FORMAT="${WYN_DMG_FORMAT:-$([[ -n "$RUNTIME" ]] && echo ULMO || echo UDZO)}"
echo "==> hdiutil $DMG ($FORMAT)"
hdiutil create -volname Wyn -srcfolder "$STAGE" -ov -format "$FORMAT" "$DMG" >/dev/null
echo "    $(du -h "$DMG" | cut -f1)"

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
  echo "Do not publish this. Do not put it on wyn-dev.com."
  echo "When Developer ID is in the keychain: ./scripts/package-dmg.sh --notarize"
else
  echo "Developer ID signed but NOT notarized: $DMG"
  echo "Gatekeeper will still refuse this on another Mac. Do not publish it."
  echo "To notarize and staple: ./scripts/package-dmg.sh --notarize"
fi
