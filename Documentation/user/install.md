# Install from source

Walked on an Apple Silicon Mac (macOS 14+, Xcode 16 / Swift 6) as a new user.
Wyn is **source only**. It does not ship Wine binaries, Apple GPTK, Steam, or games.

## 1. Platform

Apple Silicon, macOS 14+, **Xcode 16+ (Swift 6)**, Rosetta 2. Several gigabytes
free (Wine extract is ~1 GB; plan **~8 GB** if Steam + RV There Yet? are the
first-game test). Confirm:

```bash
./scripts/check-environment.sh
```

The check fails without `xcodebuild`, even if you only want the CLI.

## 2. Build Wyn

```bash
git clone https://github.com/JellyBean47/wyn.git
cd wyn
./scripts/check-environment.sh
./scripts/build.sh
```

`build.sh` produces:

- CLI: `./.build/release/wyn`
- App: `/tmp/WynDerivedData/Build/Products/Release/Wyn.app`

There is also an undocumented `./install.sh` (same three scripts, then copies
the CLI to `~/.local/bin/wyn` and a `fly` symlink).

## 3. FOSS Wine runtime

```bash
./scripts/setup.sh
```

Downloads frankea `Libraries.tar.gz` **v3.1.1** (see
[DEPENDENCIES.md](../../DEPENDENCIES.md)), verifies SHA-256, refuses Apple GPTK
payloads, and unpacks into
`~/Library/Application Support/com.fly.gaming/Libraries/`.

This is **Wine only**. It does not create a Steam bottle. Cache file:
`~/Library/Caches/wyn/Libraries-v3.1.1.tar.gz`.

To use a tarball you already have:

```bash
./.build/release/wyn runtime install --from /path/to/Libraries.tar.gz
```

That path still scans the archive for D3DMetal files.

One-shot CLI (Wine + Steam bottle, optional installer download):

```bash
./.build/release/wyn install --skip-steam-download
```

## 4. Open the app

```bash
open /tmp/WynDerivedData/Build/Products/Release/Wyn.app
# or
./.build/release/wyn --help
```

GPTK/D3DMetal is optional. The first-run sheet should clear once Wine and a
Steam bottle exist. Default graphics are DXMT and DXVK.

## 5. Steam + first game (RV There Yet?)

Wyn never downloads a Steam title. Steam does.

```bash
./.build/release/wyn steam install     # downloads and runs SteamSetup.exe
./.build/release/wyn steam launch      # log in, check Remember me
```

On FOSS Wine the client uses frankea / DXVK (no D3DMetal). In Steam, install
**RV There Yet?** (app **3949040**, ~3.2 GB). Then either click the tile in
Wyn.app or:

```bash
./.build/release/wyn play rv-there-yet
```

`wyn play` looks for `ride.exe` / `ride-win64-shipping.exe` after Steam has
written `appmanifest_3949040.acf`. The profile lists `vcrun2019`; Wyn does
**not** run winetricks automatically.

## 6. Optional D3DMetal

1. Download Game Porting Toolkit from Apple (Apple ID required).
2. Read the included Software License Agreement.
3. `wyn gptk install --from /path/to/redist`
   The folder must contain `lib/external` or `external` with
   `D3DMetal.framework` and `libd3dshared.dylib`.

Wyn will not download GPTK. Setup does not wire GPTK automatically.

For Wine that can *load* D3DMetal (ntdll `CX_APPLEGPTK_*` hooks):

```bash
wyn runtime install --gptk-aware
```

That is a different hash-pinned tarball (still without Apple blobs). Default
setup stays on frankea Wine (DXMT/DXVK).

## 7. Other stores

- **Epic / GOG:** install [Heroic](https://heroicgameslauncher.com), then use
  those tiles. Wyn does not `brew install heroic` unless
  `WYN_ALLOW_BREW_HEROIC=1`.
- **Battle.net / EA:** click Install in Wyn (official vendor download).

Wyn does **not** install or launch Xbox Game Pass, the Xbox app, UTM, or a
Windows VM.

## 8. On disk

- Wine: `~/Library/Application Support/com.fly.gaming/Libraries/`
- Bottles: `~/Library/Containers/com.fly.gaming/Bottles/`
- Logs: `~/Library/Logs/com.fly.gaming/`

The bundle id is `com.wyn.gaming`; on-disk folders stay `com.fly.gaming`.
