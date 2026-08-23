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
- App: `/Applications/Wyn.app` (copied from the Xcode build). Spotlight and
  Launchpad find **Wyn**. A local compile is ad-hoc signed and usually has no
  quarantine, so Gatekeeper does not block it.

`./install.sh` runs check + build + setup + Wine Mono, then copies the CLI to
`~/.local/bin/wyn` (and a `fly` symlink).

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

## 4. Wine Mono (do this in Terminal)

Wine's first bottle run pops a **Wine Mono** installer. That GUI hangs
(stuck at 0% CPU). Skip it. After Wine is on disk, download the official
MSI from WineHQ into the Wine tree so `wineboot` never needs the dialog:

```bash
./scripts/install-wine-mono.sh
```

That curls `wine-mono-10.4.1-x86.msi` (~82 MB) into
`~/Library/Application Support/com.fly.gaming/Libraries/Wine/share/wine/mono/`.
Do this **before** `wyn steam install` / `wyn steam launch`.

If the dialog already appeared, close it and install into the bottle:

```bash
./scripts/install-wine-mono.sh --into-bottle
```

Do not copy Mono from an old Wyn install. A git-clone first run should
only use WineHQ.

Wine Gecko (HTML) is the same class of dialog. If that one hangs, the
same idea applies: put the official MSI under `share/wine/gecko/` from
https://dl.winehq.org/wine/wine-gecko/ instead of clicking Install.

## 5. Open the app

```bash
open /Applications/Wyn.app
# or
./.build/release/wyn --help
```

GPTK/D3DMetal is optional. The first-run sheet should clear once Wine and a
Steam bottle exist. Default graphics are DXMT and DXVK.

## 6. Steam + first game (RV There Yet?)

Wyn never downloads a Steam title. Steam does.

Run `./scripts/install-wine-mono.sh` first (section 4) so first-boot
does not open the hung Wine Mono window.

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

## 7. Optional D3DMetal

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

## 8. Other stores

- **Epic / GOG:** install [Heroic](https://heroicgameslauncher.com), then use
  those tiles. Wyn does not `brew install heroic` unless
  `WYN_ALLOW_BREW_HEROIC=1`.
- **Battle.net / EA:** click Install in Wyn (official vendor download).

Wyn does **not** install or launch Xbox Game Pass, the Xbox app, UTM, or a
Windows VM.

## 9. On disk

- Wine: `~/Library/Application Support/com.fly.gaming/Libraries/`
- Bottles: `~/Library/Containers/com.fly.gaming/Bottles/`
- Logs: `~/Library/Logs/com.fly.gaming/`

The bundle id is `com.wyn.gaming`; on-disk folders stay `com.fly.gaming`.
