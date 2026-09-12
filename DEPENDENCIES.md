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
- **Corresponding source (LGPL):** WineHQ + published Wine source dumps; DXVK-macOS; DXMT v0.80 (MIT)

Wyn does **not** rehost this tarball on its own GitHub Releases.

## Optional D3DMetal game-host (not downloaded)

`wyn runtime install --gptk-aware` **does not fetch Wine**. The game-host is
self-built FOSS winecx. Wyn will not redistribute proprietary Wine.app
binaries. See [Documentation/user/game-host.md](Documentation/user/game-host.md).

- **Source:** https://github.com/dappermint/winecx (`wine1115`)
- **Pins:** `WINECX_COMMIT` / `NIXPKGS_REV` in `scripts/runtime-pins.env`
- **What that repo actually is** (checked 12 Sep 2026 — it is *not* a mirror of
  CodeWeavers' published source, and this file used to imply that it was). It is
  a third-party forward-port, and its own commit messages say so:

  ```
  synthetic base: wine 11.0
  wine 11.15
  crossover 26.3 on wine 11.0
  merge wine 11.15 into crossover 26.3
  apply the winecx-gptk patch set
  + 13 fix-up commits for the 11.15 port
  ```

  So: CrossOver **26.3**'s Wine tree merged forward onto upstream Wine 11.15.
  `VERSION` says `Wine version 11.15`; CodeWeavers' 26.2.0 dump says
  `Wine version 11.0`. The history is synthetic — 18 commits, all one day —
  so git history cannot be used to audit it. Only a tree diff can.

  **Licensing.** Upstream Wine is LGPL-2.1-or-later and CodeWeavers publishes
  CrossOver's Wine source under LGPL-2.1 (that publication *is* their compliance
  channel: https://www.codeweavers.com/crossover/source). A forward-port of LGPL
  onto LGPL is LGPL-2.1, and the repo ships `COPYING.LIB`. No proprietary or
  "not for redistribution" notices are in it beyond the usual Wine SDK headers.

  **Verified locally** against `crossover-sources-26.2.0.tar.gz`: the
  `CX_APPLEGPTK_LIBD3DSHARED_PATH` hook is in `dlls/ntdll/unix/loader.c` in both
  and the `init_non_native_support` block is byte-identical; and every
  `CX_*` / `CROSSOVER*` identifier in `dlls/ntdll`, `dlls/winemac.drv` and
  `server` — 13 of them — appears in both trees, with **none unique to the
  mirror**. The CrossOver code in it is CodeWeavers' published LGPL code.

  **Not verified, and the one check left:** that the `crossover 26.3 on wine
  11.0` commit's full tree matches CodeWeavers' published **26.3** dump. The
  mirror is based on 26.3 and only 26.1.0 / 26.2.0 are on this machine. Fetch
  the official 26.3 source tarball and diff it against that commit to close it.

  Exposure is bounded either way: Wyn never redistributes this build.
  `build-foss-game-host.sh` compiles it on the user's own machine, so Wyn is not
  a distributor of it and LGPL-2.1's source-offer obligation does not attach.
- **Build:** `./scripts/build-foss-game-host.sh` (mingw-w64 gcc, not llvm-mingw)
- **Install:** `wyn runtime install --gptk-aware --directory <wine-root>`
  or `./scripts/install-foss-game-host.sh --directory …`
- **Identity:** `ntdll.so` contains `CX_APPLEGPTK_LIBD3DSHARED_PATH` (winecx
  GPTK hook); `wine64` is not wineloader; `Wine/bin` is an ordinary `bin/`.
  `wyn gptk install` copies `lib/external` (availability; default ~/Downloads).
  `wyn renderer set d3dmetal` makes unix `d3d11.so` a symlink to
  `lib/external/libd3dshared.dylib`. Refuses proprietary Wine.app / wineloader
  layouts and Whisky 11 without the ntdll hook.
- **GPTK 3.0:** user Apple DMG via `wyn gptk install` (default `~/Downloads/Game_Porting_Toolkit_3.0.dmg`) onto that winecx tree.

The former EricSpencer `wine-v26.1.0-foss-phase1l` WhiskyWine tarball is **not**
the game-host. Do not install it as `Libraries/` for D3DMetal.

- **Name:** EricSpencer WhiskyWine (historical; not used)
- **URL:** https://github.com/EricSpencer00/Whisky/releases/download/wine-v26.1.0-foss-phase1l/Libraries.tar.gz
- **SHA-256:** `645917a4135c2ce83047186b6a352bf0d03ff785468e0c276db800ae044ab634`

## Wine Mono (WineHQ, first-run)

winecx `appwiz.cpl` only skips the hung GUI installer when the **matching**
MSI is already in `Libraries/Wine/share/wine/mono/`. `./scripts/setup.sh`
unpacks frankea Wine; `./scripts/install-foss-game-host.sh` then replaces
`Libraries/`, so a 10.4.1 copy there is the wrong file for winecx. Cache
both MSIs under `~/Library/Caches/wyn/` (WineHQ only — not a parked Wyn
tree). `wyn steam install` runs `msiexec /qn` before SteamSetup.

- **Name:** Wine Mono Runtime (winecx / D3DMetal game-host)
- **Version:** `11.2.0` (`WINE_MONO_VERSION` — winecx `addons.c` `MONO_VERSION` at `WINECX_COMMIT`)
- **URL:** https://dl.winehq.org/wine/wine-mono/11.2.0/wine-mono-11.2.0-x86.msi
- **SHA-256:** `b4525679e7da30d4658ceb85739cbc55c771791054abbb4b3152fe96ded0b897`
- **License:** Wine Mono / MIT-style (Wine Project)

- **Name:** Wine Mono Runtime (frankea Wine 11.0 / `./scripts/setup.sh`)
- **Version:** `10.4.1` (`WINE_MONO_FRANKEA_VERSION`)
- **URL:** https://dl.winehq.org/wine/wine-mono/10.4.1/wine-mono-10.4.1-x86.msi
- **SHA-256:** `071f4b2887e1c97a11d791ff3d65be9429eed6dec4c2708888bfd546ba358e23`
- **Size:** 85504000 bytes
- **License:** Wine Mono / MIT-style (Wine Project)

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
- Install: `wyn gptk install` (default `~/Downloads/Game_Porting_Toolkit_3.0.dmg`)
