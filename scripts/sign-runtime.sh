#!/usr/bin/env bash
# This file is part of Wyn.
#
# Wyn is free software: you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later
# version.
#
# Sign a staged runtime (stage-runtime.sh output, or the copy inside Wyn.app)
# for notarization.
#
#   ./scripts/sign-runtime.sh <runtime-dir> [identity]   # identity default "-" (ad-hoc)
#
# Every Mach-O under Libraries/ gets the hardened runtime and a secure
# timestamp. Libraries are signed first, executables last, and only the
# executables carry WynApp/WineRuntime.entitlements. GPTK/ is Apple's and is
# never re-signed: Apple's licence forbids modifying it, and its own signature
# must still verify afterwards or this script fails.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="${1:?usage: sign-runtime.sh <runtime-dir> [identity]}"
IDENTITY="${2:--}"
ENTITLEMENTS="$ROOT/WynApp/WineRuntime.entitlements"

fail() { echo "error: $*" >&2; exit 1; }
[[ -d "$RUNTIME/Libraries/Wine" ]] || fail "$RUNTIME/Libraries/Wine missing"

if [[ "$IDENTITY" == "-" ]]; then
  TIMESTAMP=(--timestamp=none)
else
  TIMESTAMP=(--timestamp)
fi

is_macho() {
  case "$(head -c 4 "$1" | xxd -p)" in
    cffaedfe|cefaedfe|feedfacf|feedface|cafebabe|bebafeca) return 0 ;;
    *) return 1 ;;
  esac
}

libs=()
exes=()
while IFS= read -r f; do
  is_macho "$f" || continue
  if file -b "$f" | grep -q "executable"; then
    exes+=("$f")
  else
    libs+=("$f")
  fi
done < <(find "$RUNTIME/Libraries" -type f)

echo "==> signing ${#libs[@]} runtime libraries ($IDENTITY)"
for f in "${libs[@]}"; do
  codesign --force --sign "$IDENTITY" --options runtime "${TIMESTAMP[@]}" "$f"
done

echo "==> signing ${#exes[@]} runtime executables with Wine entitlements"
for f in "${exes[@]}"; do
  codesign --force --sign "$IDENTITY" --options runtime "${TIMESTAMP[@]}" \
    --entitlements "$ENTITLEMENTS" "$f"
done

for f in "${libs[@]}" "${exes[@]}"; do
  codesign --verify --strict "$f" || fail "signature does not verify: $f"
done

if [[ -d "$RUNTIME/GPTK" ]]; then
  ext="$RUNTIME/GPTK/redist/lib/external"
  for code in "$ext/D3DMetal.framework" "$ext/libd3dshared.dylib"; do
    codesign --verify --strict -R="anchor apple" "$code" \
      || fail "$code lost Apple's signature"
  done
  echo "    Apple's GPTK left as Apple signed it"
fi
echo "Signed: $RUNTIME"
