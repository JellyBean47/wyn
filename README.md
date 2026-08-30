# Wyn

Wyn is a macOS Wine wrapper for running Windows games. It is a modified
version of [Whisky](https://github.com/Whisky-App/Whisky), licensed under
**GPL-3.0-or-later**. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

This repository is **source only**. It does not contain Wine binaries, Apple
Game Porting Toolkit / D3DMetal, store clients, or game files.

## What you need

- Apple Silicon Mac, macOS 14 or later
- Xcode 16 or later (Swift 6). Xcode 15 / Swift 5.10 cannot build this tree
- Rosetta 2 (`softwareupdate --install-rosetta`)
- Several gigabytes free (Wine runtime is ~300–400 MB compressed)
- Optional: [Homebrew](https://brew.sh) if you want Heroic via cask
- Optional: [Apple Game Porting Toolkit](https://developer.apple.com/download/all/?q=game%20porting%20toolkit) only if you want D3DMetal

## Clone, build, run

```bash
git clone https://github.com/JellyBean47/wyn.git
cd wyn
./scripts/check-environment.sh
./scripts/build.sh
./scripts/setup.sh
```

`setup.sh` downloads the **hash-pinned** frankea WhiskyWine tarball (Wine 11 +
DXVK-macOS + DXMT 0.80 + MoltenVK). It **refuses** archives that contain Apple
GPTK files. It is not the D3DMetal game-host (self-built FOSS winecx; see Documentation/user/game-host.md). It does not install Steam games or GPTK.

Then:

```bash
open /Applications/Wyn.app
# or
./.build/release/wyn --help
```

CLI-only (no app):

```bash
swift build -c release
./.build/release/wyn install --skip-steam-download
```

## Optional pieces (you obtain these)

**Heroic (Epic / GOG):** install from
[heroicgameslauncher.com](https://heroicgameslauncher.com) or
`brew install --cask heroic`, then use the Epic / GOG tiles. Wyn will not
run `brew` unless you set `WYN_ALLOW_BREW_HEROIC=1`.

**Steam + first game:** see [Documentation/user/install.md](Documentation/user/install.md).
Short version: `./scripts/install-wine-mono.sh` (WineHQ MSI; the Wine Mono
GUI hangs), then `wyn steam install`, `wyn steam launch`, install the title
in Steam (RV There Yet? is app 3949040), then click the tile or
`wyn play rv-there-yet`. Wyn never downloads the game.

**Battle.net / EA:** Wyn can download those vendors’ official Windows
installers when you click Install. Epic and GOG in Wine are not the product
path (use Heroic).

**D3DMetal:** the game-host is **self-built FOSS winecx**, not Whisky 11 with
GPTK bolted on. Wyn never downloads winecx or GPTK for `--gptk-aware`. See
[Documentation/user/game-host.md](Documentation/user/game-host.md).

```bash
./scripts/build-foss-game-host.sh
wyn runtime install --gptk-aware --directory /path/to/wine-root
wyn gptk install --from /path/to/GPTK/redist
```

Read Apple’s Game Porting Toolkit license first. Default graphics are DXMT and
DXVK (`./scripts/setup.sh` frankea), not D3DMetal.

## Legal

- [DEPENDENCIES.md](DEPENDENCIES.md) — versions, URLs, hashes
- [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)
- [Documentation/user/install.md](Documentation/user/install.md)

Wyn is a Wine wrapper. It does **not** include Xbox Game Pass, the Xbox
app, a Windows guest (UTM / QEMU / Parallels), or a `wyn gamepass`
command.

Wyn is not affiliated with Apple, Valve, Microsoft, or Whisky-App.
Trademarks of other Wine products are theirs; see [NOTICE](NOTICE).

## Layout

```
WynKit/          core library (GPL-3.0-or-later, from WhiskyKit)
WynApp/          SwiftUI app
Sources/WynCmd/  `wyn` CLI
scripts/         check-environment, build, setup
patches/wine/    Wine patch notes (LGPL source form)
Documentation/   user docs and license texts
Tools/           first-party helper sources (binaries are built locally)
```
