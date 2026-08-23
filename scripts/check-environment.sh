#!/usr/bin/env bash
# Fail unless this Mac can build Wyn from source.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() { echo "error: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

echo "==> Wyn environment check"

[[ "$(uname -s)" == "Darwin" ]] || fail "macOS required"

arch="$(uname -m)"
if [[ "$arch" != "arm64" ]]; then
  echo "warning: uname -m is $arch (Apple Silicon arm64 is the supported target)" >&2
fi

os_major="$(sw_vers -productVersion | cut -d. -f1)"
if [[ "${os_major}" -lt 14 ]]; then
  fail "macOS 14 or later required (found $(sw_vers -productVersion))"
fi
ok "macOS $(sw_vers -productVersion) ($arch)"

if ! xcode-select -p >/dev/null 2>&1; then
  fail "Xcode Command Line Tools missing. Run: xcode-select --install"
fi
ok "xcode-select: $(xcode-select -p)"

command -v swift >/dev/null || fail "swift not on PATH"
swift_ver="$(swift --version 2>/dev/null | awk '/Swift version/{for (i = 1; i <= NF; i++) if ($i == "version") { print $(i + 1); exit }}')"
swift_major="${swift_ver%%.*}"
if [[ -z "$swift_major" || "$swift_major" -lt 6 ]]; then
  fail "Swift 6 or later required (found ${swift_ver:-unknown}). Install Xcode 16+"
fi
ok "swift $(swift --version 2>/dev/null | head -1)"

command -v xcodebuild >/dev/null || fail "xcodebuild not on PATH"
ok "xcodebuild present"

if [[ ! -f /Library/Apple/usr/share/rosetta/rosetta ]]; then
  echo "warning: Rosetta 2 does not look installed. Wine is x86_64:" >&2
  echo "  softwareupdate --install-rosetta" >&2
else
  ok "Rosetta 2 present"
fi

avail_kb="$(df -k "$HOME" | awk 'NR==2 {print $4}')"
avail_gb=$((avail_kb / 1024 / 1024))
if [[ "$avail_gb" -lt 3 ]]; then
  fail "Need ~3 GiB free for Wine extract (home volume has ~${avail_gb} GiB)"
fi
ok "disk free ~${avail_gb} GiB on home volume"

if [[ -d /opt/homebrew/bin ]] || command -v brew >/dev/null 2>&1; then
  ok "Homebrew visible (optional; used only if you install Heroic)"
else
  echo "note: Homebrew not found. Install Heroic from https://heroicgameslauncher.com if you want Epic/GOG."
fi

echo
echo "Environment looks usable. Next: ./scripts/build.sh && ./scripts/setup.sh"
