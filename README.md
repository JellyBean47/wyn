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
git clone <repository-url>
cd wyn
./scripts/check-environment.sh
./scripts/build.sh
./scripts/setup.sh
```

`setup.sh` downloads the **hash-pinned** frankea WhiskyWine tarball (Wine 11 +
DXVK-macOS + DXMT 0.80 + MoltenVK). It **refuses** archives that contain Apple
GPTK files. It does not install Steam games or GPTK.

Then:

```bash
open /tmp/WynDerivedData/Build/Products/Release/Wyn.app
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

**Steam:** `wyn steam install` downloads Valve’s official `SteamSetup.exe`.

**Battle.net / EA:** Wyn can download those vendors’ official Windows
installers when you click Install. Epic and GOG in Wine are not the product
path (use Heroic).

**D3DMetal:** Wyn never downloads GPTK. After you have Apple’s redist on disk:

```bash
wyn gptk install --from /path/to/GPTK/redist
```

Read Apple’s Game Porting Toolkit license first. Default graphics are DXMT and
DXVK, not D3DMetal.

## Legal

- [DEPENDENCIES.md](DEPENDENCIES.md) — versions, URLs, hashes
- [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)
- [Documentation/user/install.md](Documentation/user/install.md)

Wyn is a Wine wrapper. It does **not** include Xbox Game Pass, the Xbox
app, a Windows guest (UTM / QEMU / Parallels), or a `wyn gamepass`
command.

Wyn is not affiliated with CodeWeavers, Apple, Valve, Microsoft, or
Whisky-App. CrossOver.app must not be copied into this project.

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
