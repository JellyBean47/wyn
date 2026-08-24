# Dependencies and pinned downloads

Pinned hashes are SHA-256 of the **entire** `Libraries.tar.gz`. Setup refuses
the archive if the hash mismatches or if the tarball listing contains Apple
GPTK markers (`D3DMetal.framework`, `libd3dshared.dylib`,
`libmetalirconverter.dylib`).

Update this file and [`scripts/runtime-pins.env`](scripts/runtime-pins.env)
together.

## Build-time (SPM)

Resolved in `Package.resolved`:

- `swift-argument-parser` **1.8.2** (`6a52f3251125d74daf04fcbd5e6f08a75d074382`) — Apache-2.0
- `SemanticVersion` **0.5.3** (`330bab3e41aad91fb3b1b0f779d1325738e54b93`) — Apache-2.0
- `SwiftyTextTable` **0.9.0** (`c6df6cf533d120716bff38f8ff9885e1ce2a4ac3`) — MIT

## Default Wine runtime (FOSS path)

Used by `./scripts/setup.sh` and `wyn runtime install` (community WhiskyWine).

- **Name:** frankea WhiskyWine Libraries
- **Version tag:** `v3.1.1` (plist: Wine 11.0, DXVK 1.10.3, DXMT 0.80)
- **URL:** https://github.com/frankea/Whisky/releases/download/v3.1.1/Libraries.tar.gz
- **SHA-256:** `01f3a1b43b98065fe20c529c1023b61dd79a6d2ad93bba6040865f646481ccf3`
- **Version plist:** https://frankea.github.io/Whisky/WhiskyWineVersion.plist
- **Corresponding source (LGPL):** WineHQ + CodeWeavers FOSS dumps; DXVK-macOS; DXMT v0.80 (MIT)

Wyn does **not** rehost this tarball on its own GitHub Releases.

## Optional D3DMetal game-host (not downloaded)

`wyn runtime install --gptk-aware` **does not fetch Wine**. The game-host is
Sikarugir CrossOver-hosted Wine the user already has (CrossOver.app or a
Sikarugir wrapper). Wyn will not redistribute CrossOver binaries or unofficial
CX tarballs. See [Documentation/user/game-host.md](Documentation/user/game-host.md).

- **Obtain:** https://www.codeweavers.com/crossover (trial or purchase) and/or
  https://github.com/Sikarugir-App/Sikarugir
- **Install:** `wyn runtime install --gptk-aware --directory /Applications/CrossOver.app`
  or `./scripts/install-cx-game-host.sh --directory …`
- **Identity:** `Wine/bin` → CrossOver-Hosted Application; `wine64` → wineloader;
  `lib64/apple_gptk` present; wineserver CX-class (~593760 / 4 Jun), not Whisky
  (~856608 / 25 Apr). The check **refuses Whisky-as-game-host**.
- **GPTK 3.0:** user Apple DMG via `wyn gptk install --from` onto that CX tree.

The former EricSpencer `wine-v26.1.0-foss-phase1l` WhiskyWine tarball is **not**
the game-host. Do not install it as `Libraries/` for D3DMetal.

- **Name:** EricSpencer WhiskyWine (historical; not used)
- **URL:** https://github.com/EricSpencer00/Whisky/releases/download/wine-v26.1.0-foss-phase1l/Libraries.tar.gz
- **SHA-256:** `645917a4135c2ce83047186b6a352bf0d03ff785468e0c276db800ae044ab634`

## Wine Mono (WineHQ, first-run)

Wine 11.0's GUI `install_mono` dialog hangs. `./scripts/install-wine-mono.sh`
downloads the official MSI into the installed Wine tree so wineboot never
needs that window.

- **Name:** Wine Mono Runtime
- **Version:** `10.4.1` (`WINE_MONO_VERSION` in `scripts/runtime-pins.env`)
- **URL:** https://dl.winehq.org/wine/wine-mono/10.4.1/wine-mono-10.4.1-x86.msi
- **Size:** 85504000 bytes
- **License:** Wine Mono / MIT-style (Wine Project)
- **Not copied from a parked Wyn install.** Git-clone first run uses WineHQ only.

## Official store installer URLs (user action only)

Wyn may download these into `~/Library/Application Support/com.fly.gaming/Installers/`
when the user runs the matching install command or clicks Install. They are
**not** committed.

- Steam: https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe
- Battle.net: https://downloader.battle.net/download/getInstaller?os=win&installer=Battle.net-Setup.exe
- EA App: https://origin-a.akamaihd.net/EA-Desktop-Client-Download/installer-releases/EAappInstaller.exe
- Epic MSI / GOG Galaxy: still in code for parked Wine storefronts; product path for Epic/GOG is **Heroic**, not these installers

## Heroic

- Site: https://heroicgameslauncher.com
- Homebrew cask: `brew install --cask heroic` (only if the user sets `WYN_ALLOW_BREW_HEROIC=1` or installs themselves)

## Apple GPTK

- **Wyn never downloads this.**
- https://developer.apple.com/download/all/?q=game%20porting%20toolkit
- Install: `wyn gptk install --from /path/to/redist`
