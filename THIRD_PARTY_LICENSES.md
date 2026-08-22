# Third-party licenses

This file lists significant third-party software Wyn uses or may download.
**This repository ships only Wyn source plus copies of license texts.** Runtime
binaries (Wine, DXVK, DXMT, MoltenVK) are obtained at install time. Apple
GPTK/D3DMetal is never downloaded or redistributed by Wyn.

Full license texts live under [`Documentation/licenses/`](Documentation/licenses/).

## Included in this source tree (Swift packages)

| Component | Version | License | Source |
| --- | --- | --- | --- |
| Whisky (original WynKit) | upstream `fd5480a` lineage | GPL-3.0-or-later | https://github.com/Whisky-App/Whisky |
| swift-argument-parser | 1.8.2 | Apache-2.0 | https://github.com/apple/swift-argument-parser |
| SemanticVersion | 0.5.3 | Apache-2.0 | https://github.com/SwiftPackageIndex/SemanticVersion |
| SwiftyTextTable | 0.9.0 | MIT | https://github.com/scottrhoyt/SwiftyTextTable |

Apache-2.0 requires preserving the license text and NOTICE attribution
(see [NOTICE](NOTICE)). License text: [`Documentation/licenses/Apache-2.0.txt`](Documentation/licenses/Apache-2.0.txt).

## Fetched at install time (not in git)

| Component | Typical version | License | Publisher / URL | Wyn may auto-download? |
| --- | --- | --- | --- | --- |
| Wine (community WhiskyWine) | 11.0 in frankea `v3.1.1` | LGPL-2.1-or-later | https://github.com/frankea/Whisky/releases | Yes, hash-pinned |
| Wine (GPTK-aware, CX FOSS) | `wine-v26.1.0-foss-phase1l` | LGPL-2.1-or-later | https://github.com/EricSpencer00/Whisky/releases | Only with `--gptk-aware` |
| CrossOver FOSS Wine **source** | 26.x | LGPL-2.1-or-later (and other OSS) | https://www.codeweavers.com/crossover/source | No |
| DXVK / DXVK-macOS | 1.10.3-async (frankea) | zlib | https://github.com/doitsujin/dxvk · https://github.com/Gcenx/DXVK-macOS | Inside Wine tarball |
| DXMT | 0.80 (last MIT release) | MIT (v0.80); later is LGPL-2.1+ | https://github.com/3Shain/dxmt | Inside frankea tarball |
| MoltenVK | 1.4.x | Apache-2.0 | https://github.com/KhronosGroup/MoltenVK | Inside Wine tarball |
| vkd3d | Wine tree | LGPL-2.1-or-later | WineHQ | Inside Wine tarball |
| Heroic Games Launcher | 2.22.x | GPL-3.0 | https://github.com/Heroic-Games-Launcher/HeroicGamesLauncher | No (user or opt-in brew) |

Wine companion libraries inside `Libraries.tar.gz` (GnuTLS, FreeType, wine-mono,
FAudio, zlib/libpng, etc.) keep their upstream licenses. The **binary
distributor** of that tarball is the GitHub release publisher named above, not
this repository, unless Wyn GitHub Releases start hosting the tarball (they
must not, without a corresponding-source offer).

## User-obtained only (never in git, never auto-fetched by Wyn)

| Component | License / terms | How to obtain |
| --- | --- | --- |
| Apple Game Porting Toolkit, D3DMetal, libd3dshared, metalirconverter | Apple GPTK Software License Agreement (evaluation / non-commercial redistribution; no reverse engineering) | https://developer.apple.com/download/all/?q=game%20porting%20toolkit |
| CrossOver.app | CodeWeavers EULA | Do not copy into Wyn |
| Sikarugir engines | Mixed / unclear | Not part of Wyn setup |
| Steam, Battle.net, EA App, Epic, GOG, Ubisoft clients | Vendor ToS | Official vendor URLs on explicit user action |
| Microsoft `d3dcompiler_47`, corefonts | Microsoft redistributable / core fonts EULAs | winetricks or user; do not commit |
| macOS SDK, Xcode, Rosetta 2 | Apple | User installs |

## Wine patches in this tree

Source-form notes under [`patches/wine/`](patches/wine/) describe intended
LGPL-2.1+ changes to Wine. Do not commit patched `win32u.so` / `winemac.so`
binaries.
