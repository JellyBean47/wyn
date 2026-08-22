#!/usr/bin/env bash
# Wyn installer: build CLI, then hash-pinned FOSS Wine (no GPTK).
set -euo pipefail

cd "$(dirname "$0")"

./scripts/check-environment.sh
./scripts/build.sh
./scripts/setup.sh

BIN_DIR="${HOME}/.local/bin"
mkdir -p "$BIN_DIR"
cp ".build/release/wyn" "$BIN_DIR/wyn"
chmod +x "$BIN_DIR/wyn"
ln -sfn "$BIN_DIR/wyn" "$BIN_DIR/fly"

echo
echo "Installed $BIN_DIR/wyn (also linked as fly)"
if [[ ":${PATH}:" != *":${BIN_DIR}:"* ]]; then
  echo "Add to ~/.zshrc:  export PATH=\"${BIN_DIR}:\$PATH\""
fi
echo "Steam (optional):  wyn steam install"
echo "Heroic:            https://heroicgameslauncher.com"
echo "GPTK (optional):   wyn gptk install --from <apple-redist>"
