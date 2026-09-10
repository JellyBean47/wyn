# Wyn

Windows games on Mac. Open source. [Compatibility catalog](https://wyn-dev.com).

Wyn is a macOS Wine wrapper for running Windows games. Per-game profiles pick
the translation layer (DXMT / D3DMetal / DXVK), not a star rating. The site
tells you which profiles were **verified** on a real Mac and which are still
**guessed**. Wyn is GPL-3.0-or-later and free.

This repository is **source only**. It does not contain Wine binaries, Apple
Game Porting Toolkit / D3DMetal, store clients, or game files. It is a modified
version of [Whisky](https://github.com/Whisky-App/Whisky). See [LICENSE](LICENSE)
and [NOTICE](NOTICE).

**Install today** still needs Xcode (below). A signed, notarized `Wyn.dmg` (drag
to Applications) is the next packaging step — see
[Documentation/user/apple-developer.md](Documentation/user/apple-developer.md)
and [Documentation/user/packaging.md](Documentation/user/packaging.md). Do not
treat an ad-hoc build as 1.0.

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
./install.sh
```

That is the whole install. It checks your Mac can build Wyn, builds the CLI and
`Wyn.app`, downloads the hash-pinned Wine runtime, adds Wine Mono, and puts
`wyn` on your path at `~/.local/bin/wyn`.

Prefer to run the steps yourself:

```bash
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

## Uninstalling

```bash
./scripts/uninstall.sh
```

Removes the app, the `wyn` command, the Wine runtime, caches, logs, preferences
and bottles. It lists every path with its size and asks you to type `wyn` before
touching anything; `--dry-run` shows the same list and removes nothing.

Homebrew packages (`mingw-w64`, `ccache`), `~/Downloads` and your checkout are
never touched. `--keep-bottles` preserves your Windows environments and the
games in them; `--clean-build` also clears this checkout's build artifacts.

## Something not working?

```bash
./scripts/doctor.sh
```

Checks what you have against what you should have — build tools, Wine runtime,
D3DMetal, renderer wiring, bottles, Steam — and prints the exact command to fix
anything that is wrong. It needs nothing but bash, so it works before Wyn is
built, and it only reports: it never installs or rewires anything.

## Optional pieces (you obtain these)

**Heroic (Epic / GOG):** install from
[heroicgameslauncher.com](https://heroicgameslauncher.com) or
`brew install --cask heroic`, then use the Epic / GOG tiles. Wyn will not
run `brew` unless you set `WYN_ALLOW_BREW_HEROIC=1`.

**Steam + first game:** see [Documentation/user/install.md](Documentation/user/install.md).
Short version: `./scripts/install-wine-mono.sh` (WineHQ MSI into the live
Wine tree), then `wyn steam install` (`msiexec /qn` then SteamSetup; do
not use the hung Wine Mono GUI), `wyn steam launch`, install the title
in Steam (RV There Yet? is app 3949040), then click the tile or
`wyn play rv-there-yet`. Wyn never downloads the game.

**Battle.net / EA:** Wyn can download those vendors’ official Windows
installers when you click Install. Epic and GOG in Wine are not the product
path (use Heroic).

**D3DMetal:** the game-host is **self-built FOSS winecx**, not Whisky 11 with
GPTK bolted on. Wyn never downloads winecx or GPTK for `--gptk-aware`. See
[Documentation/user/game-host.md](Documentation/user/game-host.md).

Read Apple's licence first, then one command does all of it:

```bash
./install.sh --with-d3dmetal --accept-gptk-licence
```

This compiles Wine from source, so expect it to take a while. Both flags are
required: Wyn will not assume you have accepted Apple's terms. Put
`Game_Porting_Toolkit_3.0.dmg` in `~/Downloads` first, or Wyn will ask you to
browse for it.

The game-host build needs `ccache` and `mingw-w64`. Wyn checks for them before
installing anything and tells you the `brew` command if they are missing. Add
`--install-missing-tools` to let Wyn run `brew install` for you — Wyn never runs
`brew` unless you ask, and never installs Homebrew itself.

The same thing by hand:

```bash
./scripts/build-foss-game-host.sh
wyn runtime install --gptk-aware --directory /path/to/wine-root
wyn gptk install
# default: ~/Downloads/Game_Porting_Toolkit_3.0.dmg
# elsewhere: wyn gptk install --pick   (browse in Finder)
wyn renderer set d3dmetal   # opt-in; install does not select D3DMetal
```

Read Apple’s Game Porting Toolkit license first. Default graphics are **DXMT**
(D3D11 → Metal). D3DMetal is an opt-in upgrade for D3D12-only titles, not a
replacement.

## Choosing the graphics layer

DXMT and D3DMetal are installed side by side and **do not replace each other**.
The layer is chosen per launch by `WINEDLLOVERRIDES`, so one game can run on
D3DMetal while another runs on DXMT — including at the same time, in the same
Wine session.

- **Per game:** pick the profile. `wyn play solarpunk` runs on D3DMetal;
  `wyn play solarpunk-dxmt` runs the same game on DXMT.
- **Per bottle:** in the app, right-click a bottle → **Graphics**. That is the
  bottle's *default*, used by games whose profile does not pin a layer — a
  profile that names one still wins for that game.

**Check the adapter, never the profile.** The only reliable answer is the
`Chosen D3D11 Adapter` line in the game's own log
(`wyn profiles performance <profile>` reads it for you):

| layer | adapter | VendorId |
|---|---|---|
| D3DMetal | `AMD Compatibility Mode` | `0x1002` |
| DXMT | `Apple M4` (your GPU) | `0x106b` |
| DXVK | `NVIDIA GeForce 6800` | `0x10de` |

A D3DMetal log *also* contains `Apple M4` and `106b`, from adapter enumeration
falling through to wined3d. Grep for the vendor id alone and you will call a
D3DMetal run DXMT — read the `Chosen D3D11 Adapter` line and nothing else.

## Legal

- [DEPENDENCIES.md](DEPENDENCIES.md) — versions, URLs, hashes
- [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)
- [Documentation/user/install.md](Documentation/user/install.md)
- [Documentation/user/apple-developer.md](Documentation/user/apple-developer.md)
- [Documentation/verify-next.md](Documentation/verify-next.md)

Wyn is a Wine wrapper. It does **not** include Xbox Game Pass, the Xbox
app, a Windows guest (UTM / QEMU / Parallels), or a `wyn gamepass`
command.

Wyn is not affiliated with Apple, Valve, Microsoft, or Whisky-App.
Trademarks of other Wine products are theirs; see [NOTICE](NOTICE).

## Compatibility catalog

[wyn-dev.com](https://wyn-dev.com) is the public catalog and JSON API. Verified
means measured; guessed is not evidence. Local preview:

```bash
cd website
node server.mjs
```

Open [http://127.0.0.1:3000](http://127.0.0.1:3000). See [website/README.md](website/README.md).
To update production: `cd website && npm run deploy`.

## Layout

```
WynKit/          core library (GPL-3.0-or-later, from WhiskyKit)
WynApp/          SwiftUI app
Sources/WynCmd/  `wyn` CLI
website/         wyn-dev.com (catalog, JSON API, profile submit)
scripts/         check-environment, build, setup, package-dmg
patches/wine/    Wine patch notes (LGPL source form)
Documentation/   user docs, packaging, verify-next, share
Tools/           first-party helper sources (binaries are built locally)
```
