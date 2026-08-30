# D3DMetal game-host (FOSS winecx)

The D3DMetal game-host is **self-built FOSS winecx** (Wine 11.15 + in-tree
ntdll `CX_APPLEGPTK_LIBD3DSHARED_PATH` hook), not CrossOver.app / wineloader
and not Whisky 11 with GPTK bolted on.

Wyn does **not** vendor Wine or GPTK binaries and does **not** download Wine
for `--gptk-aware`. CrossOver.app is refused. Unofficial “CX engine” tarballs
are not an install source.

## What lives where

| Tree | Role |
| --- | --- |
| `Libraries/` (game-host) | FOSS winecx. Steam UI for GPTK 3.0 + games. |
| `Libraries.steam` (frankea) | `./scripts/setup.sh` WhiskyWine v3.1.1 — DXMT / window rollback only. |
| Apple GPTK 3.0 | User DMG/redist via `wyn gptk install --from` onto the winecx tree (`D3DMetal.framework` + `libd3dshared`). Not Wine. |

Steam on the game-host wineserver. Isolation AppDefaults for `steam.exe` and
`steamwebhelper.exe` are **`=b`** (builtin), not `n,b`.
`translationLayer=d3dmetal` does **not** silently fall back to frankea DXVK.

## Build FOSS winecx

Pins live in `scripts/runtime-pins.env` (`WINECX_COMMIT`, `NIXPKGS_REV`).
PE modules must be built with **mingw-w64 gcc** (llvm-mingw `kernelbase`
stalls Steam CM login). Unix half is **x86_64** (Rosetta). Needs Nix
`extra-platforms = x86_64-darwin` for freetype/gnutls/gstreamer/ffmpeg —
Apple Silicon Homebrew is arm64.

```bash
./scripts/build-foss-game-host.sh
```

Source tree: https://github.com/dappermint/winecx (`wine1115`). Harness:
https://github.com/frankea/winecx-gptk. Do not copy CrossOver.app into git.

## Copy or link into Wyn

```bash
# After ./scripts/setup.sh (frankea rollback) and a built CLI:
./scripts/install-cx-game-host.sh --directory /path/to/wine-root
# same thing via CLI:
wyn runtime install --gptk-aware --directory /path/to/wine-root
wyn runtime install --gptk-aware --check
```

Destination:

`~/Library/Application Support/com.fly.gaming/Libraries/`

`--link` keeps the build tree as the bytes. Non-host `Libraries/` is parked as
`Libraries.pre-gptk-aware.bak` and exposed as `Libraries.steam`.

`--gptk-aware` **does not download** Wine. There is no hash-pinned GPTK-aware
tarball Wyn fetches.

## Identity (sanity-check)

`wyn runtime install --gptk-aware --check` and
`./scripts/install-cx-game-host.sh --check` refuse CrossOver.app / wineloader
and Whisky 11 without the ntdll hook.

| Probe | FOSS winecx (accept) | Refuse |
| --- | --- | --- |
| `ntdll.so` | contains `CX_APPLEGPTK_LIBD3DSHARED_PATH` | missing |
| `wine64` | ordinary `wine64` | `wineloader` |
| `Wine/bin` | ordinary `bin/` | `CrossOver-Hosted Application` |
| Whisky 11 | n/a | `WhiskyWineVersion.plist` / wineserver ~856608 and no ntdll hook |
| After GPTK overlay | `d3d11.so` / `dxgi.so` / `d3d12.so` → `lib/external/libd3dshared.dylib` beside `D3DMetal.framework` | copied (non-symlink) unix modules |

Steam tiles and `wyn steam launch` use the game-host when this identity is
present. Otherwise they stay on frankea. D3DMetal **play** errors if the host
or Logged-On Steam is missing.

## Satisfactory (D3DMetal)

Play-menu pointer: Steam Input off (`UseSteamControllerConfig=0` for 526870).
The FOSS host must ship `winebus.so` with `@loader_path/../..` so libinotify
loads (`scripts/build-foss-game-host.sh`). Do not pin `FG.InputMode`. Do not
`xinput*=d`. Never `wineserver -k`. CLI: `./.build/debug/wyn play satisfactory`.

## GPTK 3.0 (Apple, not Wine)

```bash
wyn gptk install --from /path/to/GPTK/redist-or-dmg
wyn gptk status
```

Apple download (Wyn never fetches it):
https://developer.apple.com/download/all/?q=game%20porting%20toolkit

Read Apple’s SLA. Overlay goes onto the winecx tree (`lib/external`).
Unix D3D modules must be **symlinks** to `libd3dshared` (`cp -L` breaks
`dlopen` of D3DMetal).
