# D3DMetal game-host (CrossOver-hosted Wine)

The D3DMetal game-host is **Sikarugir CrossOver-hosted Wine**, not Whisky 11
with GPTK bolted on. Restoring a parked CX-hosted `Libraries/Wine` and running
Steam UI there is the path that actually ran Satisfactory.

Wyn does **not** vendor Wine or GPTK binaries and does **not** download
CrossOver. Unofficial “CX engine” tarballs are not an install source.

## What lives where

| Tree | Role |
| --- | --- |
| `Libraries/` (game-host) | Sikarugir CrossOver-hosted Wine. Steam UI for GPTK 3.0 + games. |
| `Libraries.steam` (frankea) | `./scripts/setup.sh` WhiskyWine v3.1.1 — DXMT / window rollback only. |
| Apple GPTK 3.0 | User DMG/redist via `wyn gptk install --from` onto the CX tree (`D3DMetal.framework` + `libd3dshared`). Not Wine. |

Steam on the game-host wineserver. Isolation AppDefaults for `steam.exe` and
`steamwebhelper.exe` are **`=b`** (builtin), not `n,b`.

## Obtain CrossOver-hosted Wine

1. **CrossOver** from CodeWeavers (trial or purchase):
   https://www.codeweavers.com/crossover
2. Or a **Sikarugir** wrapper whose engine is that CrossOver-hosted Wine.
   Sikarugir itself: https://github.com/Sikarugir-App/Sikarugir
   (`brew install --cask Sikarugir-App/sikarugir/sikarugir`).

Do not copy `CrossOver.app` into this git tree.

## Copy or link into Wyn

```bash
# After ./scripts/setup.sh (frankea rollback) and a built CLI:
./scripts/install-cx-game-host.sh --directory /Applications/CrossOver.app
# or a Sikarugir wrapper .app
./scripts/install-cx-game-host.sh --directory /Applications/YourWrapper.app --link

# same thing via CLI:
wyn runtime install --gptk-aware --directory /Applications/CrossOver.app
wyn runtime install --gptk-aware --check
```

Destination:

`~/Library/Application Support/com.fly.gaming/Libraries/`

`--link` keeps CrossOver.app as the bytes. A copy (`ditto`) survives deleting
the app. Non-CX `Libraries/` is parked as `Libraries.pre-gptk-aware.bak` and
exposed as `Libraries.steam`.

`--gptk-aware` **does not download** Wine. There is no hash-pinned GPTK-aware
tarball for the game-host.

## Identity (sanity-check)

`wyn runtime install --gptk-aware --check` and
`./scripts/install-cx-game-host.sh --check` refuse Whisky-as-game-host.

| Probe | CrossOver-hosted (accept) | Whisky (refuse) |
| --- | --- | --- |
| `Wine/bin` | `CrossOver-Hosted Application` (symlink or that folder copied to `bin/`) | ordinary `bin/` |
| `wine64` | `wineloader` | a `wine64` binary |
| `lib64/apple_gptk` | present | absent |
| `wineserver` | CX-class, parked **~593760 / 4 Jun** | Whisky **~856608 / 25 Apr** |

Steam tiles and `wyn steam launch` already use the game-host when this identity
plus ntdll `CX_APPLEGPTK_*` hooks are present. Otherwise they stay on frankea.

## GPTK 3.0 (Apple, not Wine)

```bash
wyn gptk install --from /path/to/GPTK/redist-or-dmg
wyn gptk status
```

Apple download (Wyn never fetches it):
https://developer.apple.com/download/all/?q=game%20porting%20toolkit

Read Apple’s SLA. Overlay goes onto the CX tree (`lib/external`).
