#!/usr/bin/env bash
# This file is part of Wyn.
#
# Wyn is free software: you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later
# version.
#
# Reports whether this Mac can Developer ID-sign Wyn. Exit 0 if a
# Developer ID Application identity exists, 1 otherwise.
# See Documentation/user/apple-developer.md.
set -euo pipefail

if [[ -n "${WYN_SIGN_IDENTITY:-}" ]]; then
  if security find-identity -v -p codesigning | grep -F "$WYN_SIGN_IDENTITY" >/dev/null; then
    echo "WYN_SIGN_IDENTITY is present: $WYN_SIGN_IDENTITY"
    exit 0
  fi
  echo "WYN_SIGN_IDENTITY is set but not in the keychain: $WYN_SIGN_IDENTITY" >&2
  exit 1
fi

ids="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2 }' | sort -u)"
if [[ -z "$ids" ]]; then
  echo "No Developer ID Application certificate in the keychain."
  echo "Enroll: https://developer.apple.com/programs/"
  echo "Then:   ./scripts/package-dmg.sh          # ad-hoc, not for friends"
  echo "Later:  ./scripts/package-dmg.sh --notarize"
  exit 1
fi

echo "Developer ID Application identities:"
echo "$ids" | sed 's/^/  /'
first="$(echo "$ids" | head -1)"
echo "Package: WYN_SIGN_IDENTITY=\"$first\" ./scripts/package-dmg.sh --notarize"
exit 0
