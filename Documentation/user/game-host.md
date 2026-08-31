# D3DMetal game-host (FOSS winecx)

The D3DMetal game-host is **self-built FOSS winecx** (Wine 11.15 + in-tree
ntdll `CX_APPLEGPTK_LIBD3DSHARED_PATH` hook — that symbol name is winecx’s).
Whisky 11 with GPTK bolted on is not accepted.

Wyn does **not** vendor Wine or GPTK binaries and does **not** download Wine
for `--gptk-aware`. Proprietary Wine.app bundles and wineloader layouts are
refused.

## What lives where

| Tree | Role |
| --- | --- |
| `Libraries/` (game-host) | FOSS winecx. Steam UI for GPTK 3.0 + games. |
| `Libraries.steam` (frankea) | `./scripts/setup.sh` WhiskyWine v3.1.1 — DXMT / window rollback only. |
| Apple GPTK 3.0 | User DMG in `~/Downloads` via `wyn gptk install` onto the winecx tree (`D3DMetal.framework` + `libd3dshared`). Not Wine. |

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
https://github.com/frankea/winecx-gptk.

## Copy or link into Wyn

```bash
# After ./scripts/setup.sh (frankea rollback) and a built CLI:
./scripts/install-foss-game-host.sh --directory /path/to/wine-root
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

Replacing `Libraries/` drops frankea's `share/wine/mono`. The install
script (and `wyn runtime install --gptk-aware`) stages
`wine-mono-11.2.0-x86.msi` from WineHQ into the live winecx datadir
(`~/Library/Caches/wyn/` is the cache). `wyn steam install` then
`msiexec /qn` before SteamSetup so wineboot does not show the hung GUI.

## Identity (sanity-check)

`wyn runtime install --gptk-aware --check` and
`./scripts/install-foss-game-host.sh --check` refuse proprietary Wine.app /
wineloader layouts and Whisky 11 without the ntdll hook.

| Probe | FOSS winecx (accept) | Refuse |
| --- | --- | --- |
| `ntdll.so` | contains `CX_APPLEGPTK_LIBD3DSHARED_PATH` | missing |
| `wine64` | ordinary `wine64` | `wineloader` |
| `Wine/bin` | ordinary `bin/` | hosted-application layout |
| Whisky 11 | n/a | `WhiskyWineVersion.plist` / wineserver ~856608 and no ntdll hook |
| After `wyn gptk install` | `D3DMetal.framework` + `libd3dshared` under `lib/external` (selectable, not selected) | missing external payload |
| After `wyn renderer set d3dmetal` | `d3d11.so` / `dxgi.so` / `d3d12.so` → `lib/external/libd3dshared.dylib` | copied (non-symlink) unix modules |

Steam tiles and `wyn steam launch` use the game-host when this identity is
present. Otherwise they stay on frankea. D3DMetal **play** errors if the host
or Logged-On Steam is missing.

## Satisfactory (D3DMetal)

Play-menu pointer: Steam Input off (`UseSteamControllerConfig=0` for 526870).
The FOSS host must ship `winebus.so` with `@loader_path/../..` so libinotify
loads (`scripts/build-foss-game-host.sh`). Do not pin `FG.InputMode`. Do not
`xinput*=d`. Never `wineserver -k`. CLI: `./.build/debug/wyn play satisfactory`.

`wyn play` / the Wyn tile wait **120s** after the last D3DMetal session
(overlay: “Waiting for the GPU to settle”). Immediate relaunch was RHIThread
`EXCEPTION_ILLEGAL_INSTRUCTION` (7s and 31s gaps failed; ~103s was fine).
This is Metal/D3DMetal teardown, not a thermal cool-down. Steam’s own Play
button does not wait. Leave Steam Logged On.

Unreal **CrashReportClient** left after a crash is not a live session. After
the game EXE is gone, Play continues even if that dialog is still up (GPU
settle still applies if you quit less than 120s ago). Close it without
sending if you want; never `wineserver -k`.

Shipped D3DMetal env is crash-avoidance, not taste: `D3DM_ENABLE_METALFX=0`,
`D3DM_ENABLE_ASYNC_COMMIT=0`, `MTL_HUD_ENABLED=0`, `D3DM_SHOW_HUD_STATS=0`,
`metalHud: false`. MetalFX on is ~0.1–2 fps then `RHIThread`
`EXCEPTION_ILLEGAL_INSTRUCTION` in `D3DMCommandQueue::ExecuteCommandLists`.
MetalFX off alone also SIGILL'd — set all three together. `avxEnabled` stays
true until that trio is shown not to hold.

## GPTK 3.0 (Apple, not Wine)

```bash
wyn gptk install
# default: ~/Downloads/Game_Porting_Toolkit_3.0.dmg
wyn gptk status
wyn renderer set d3dmetal   # opt-in; GPTK install does not select D3DMetal
```

Apple download (Wyn never fetches it):
https://developer.apple.com/download/all/?q=game%20porting%20toolkit

Read Apple’s SLA. Overlay goes onto the winecx tree (`lib/external`) as
**availability**. Unix D3D modules stay on DXMT until
`wyn renderer set d3dmetal`. Those entries must be **symlinks** to
`libd3dshared` (`cp -L` breaks `dlopen` of D3DMetal).

DXMT is **D3D11 → Metal**. D3D12-only titles still need this D3DMetal opt-in.
D3DMetal is not deprecated.
