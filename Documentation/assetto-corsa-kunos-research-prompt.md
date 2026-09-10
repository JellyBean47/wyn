# Research prompt: Kunos UI (`AssettoCorsa.exe`) on Wyn

Copy everything below the line into a new agent chat. Canonical machine
write-up: `Documentation/assetto-corsa.md`. Prior chats:
[Assetto Corsa Wyn](7206e445-90fc-4011-bc86-9fc394794375),
[session files + picker](f95ad806-27fd-404c-ae6d-2e7fac1c8cea).

An incoming analysis (7 Sep) mixed real env facts with an **invented
decompile**. Keep the env facts. Do not treat `SteamUtils.GetIPCountry` at
IL `0x004be` as measured — that string is **not** in `AssettoCorsa.exe`.

---

You are researching how to get **vanilla Assetto Corsa's real menu** working
inside Wyn (Wine + D3DMetal on macOS), so the player can Drive → Race and pick
cars/tracks the way the Windows game does.

This is not a request to make Content Manager / CSP / Pure the default. It is
not a request to switch the bottle to 32-bit. It is not a request to switch
from D3DMetal to DXVK. Do not `wineserver -k`. Do not mark the profile
`verified`.

## What “full game” means here

On Windows, Steam starts **`AssettoCorsa.exe`**. That process is the Kunos
shell (Drive, Race, car/track/AI, options). When the player confirms a session
it **writes `cfg/race.ini` + `cfg/entry_list.ini`** and **starts `acs.exe` as
a child**. Both processes are supposed to exist: 32-bit .NET UI parent,
64-bit D3D11 sim child.

Wyn already runs **`acs.exe` alone** (Magione ~19:53, Monza grid ~22:33, AI
in practice later). The missing piece is the parent. Wine wow64 **already
ran** that parent as 32-bit (`PROCESSOR_ARCHITECTURE=x86`,
`PROCESSOR_ARCHITEW6432=AMD64`). At 20:12 it got as far as **Create main
window**. We have **not** proved it can `CreateProcess` 64-bit `acs.exe`.
We **have** proved the parent can start under wow64.

Do not “fix” this by pointing Play at `acs.exe` and calling it done. Do not
rebuild the prefix as 32-bit: that cannot run PE32+ `acs.exe`.

## Two binaries (same folder, not interchangeable)

Install: `/Volumes/SSD1TB/SteamLibrary/steamapps/common/assettocorsa`
Steam app **244210**, original Kunos AC, not Competizione / EVO.

| File | `file(1)` | Role |
|---|---|---|
| `acs.exe` | PE32+ x86-64 GUI | Sim. **This already works** under D3DMetal. |
| `AssettoCorsa.exe` | PE32 i386 **Mono/.NET assembly** | Kunos WPF + CEF3 49 UI. **This is the research target.** |
| `acs_x86.exe` | PE32 i386 | 32-bit sim fallback. Skip. |

CEF / .NET sidecars live in `launcher/support/`, not next to the exe:
`CEF3.dll`, `AC.CEF3.dll`, `libcef.dll`, `SlimDX.dll`, `Steamworks.NET.dll`,
`CSteamworks.dll`, `steam_api.dll`, paks, `libEGL.dll`, `libGLESv2.dll`.

## Machine (do not guess)

- Wyn: `/Applications/Wyn.app` (`com.fly.gaming`). CLI: `~/.local/bin/wyn`.
- Bottle **name** is `Steam` (not the UUID). Path:
  `~/Library/Containers/com.fly.gaming/Bottles/9FC8A16F-19F1-468E-B7FB-2F82000E6357`
  (`wyn list` may show `~/Library/Containers/Wyn/Bottles/…` — same bottle).
- There is **no** `wyn exec`. The command is
  `wyn run Steam /path/to/AssettoCorsa.exe`.
- Wine: GPTK-aware 11.15 under `~/Library/Application Support/com.fly.gaming/Libraries/Wine`
- Layer for `acs.exe`: **D3DMetal**. Native `d3dx11_43,d3dcompiler_43=n`.
- Windows user in the prefix is **`crossover`**.
- Profile: `assetto-corsa.json`. `exePatterns` must stay **`acs.exe` first**.
- Runtime: **Wine Mono 11.2.0**, not MS `clr.dll`. Hollow NDP `Install=1`.
- UI logs: bottle `Documents/Assetto Corsa/logs/launcher.log`
  (`launcher.log.prev` is the 20:12 window+Xaml crash).
- `KunosLauncher.prepare` is called only from
  `SteamLauncher.launchGameOnGPTKWithD3DMetal`, **not** from `wyn run`.
  It sets **Windows** `MONO_PATH` via `Wine.windowsPath` and **POSIX**
  `WINEPATH`. It nops mscorlib only when the exe name is `assettocorsa.exe`.
- Wyn.app Play on 6 Sep evening was mostly **JSON copies**, not xcodebuild.

## `KunosLauncher.prepare` path semantics (do not swap these)

```
MONO_PATH  = Wine.windowsPath(support)   // e.g. Z:\Volumes\SSD1TB\...\launcher\support
WINEPATH   = support.path (POSIX)        // /Volumes/SSD1TB/.../launcher/support
```

Mono resolves **managed** assemblies via `MONO_PATH` (Windows path).
Wine's PE loader resolves **unmanaged** P/Invoke (`CSteamworks.dll`,
`libcef.dll`) via `WINEPATH` **and** the Windows `PATH`. Do not set
`MONO_PATH` to a POSIX path. Do not set `WINEPATH=Z:/Volumes/...`.

`xxd … mscorlib.dll | grep 2a` is not a patch check. `0x2A` is everywhere.
Use `WineMono.verifyWritableILOffset` / the 25-byte body starting `ret`.

## Measured failure chain (Kunos UI only)

Each step unblocked the next. Do not re-solve a solved step.

1. **~19:09** Steam first-run: ~2s, exit 1. Hollow .NET 4.7.2, no `clr.dll`.
2. **~20:05** `Could not load file or assembly 'CEF3'` (lives in
   `launcher/support`).
3. **~20:12** **Got a window.** Log: `Initializing Steam: True`,
   Steam ID `76561199780522060`, CEF already passed `--disable-gpu`,
   `--disable-gpu-compositing`, `--no-sandbox`,
   `remote-debugging-port=30150`, then `Create main window`, then
   `XamlParseException` in `ControllerSetupSlimDX` because Wine Mono
   `NumberFormatInfo` is read-only. Crash site: `Startup.Main` **IL
   `0x00778`** → `MainWindow..ctor(bool softwaremode)`.
   Env that got this far (`launcher.log.prev`):
   - `MONO_PATH=Z:\Volumes\SSD1TB\SteamLibrary\steamapps\common\assettocorsa\launcher\support`
   - Windows `PATH` **prefixed** with POSIX
     `/Volumes/SSD1TB/.../launcher/support`
   - `WINEUSERLOCALE=C`
   - `Current Culture: en-US / en-US`
   - Steam overlay env present (`SteamEnv=1`, `SteamAppId=244210`)
   - Launched from the Cursor agent wineserver leak, not Wyn.app Play
4. Bottle patch: nop `NumberFormatInfo.VerifyWritable` in
   `mscorlib.dll` (first IL `0x2A`). Backup `mscorlib.dll.wynbak`.
5. **~22:04** (current wall) `NullReferenceException` in
   `AC.Launcher.Startup.Main` at IL **`0x004be`**. Died **after**
   `Skipped MoveUGC` / `IGNOREDPI` and **before** `PID:`, version,
   culture, and `Initializing Steam`. Different site than 20:12.
   Env:
   - `MONO_PATH=launcher\support` (**relative**, profile JSON)
   - **no** support dir on `PATH`; **no** `WINEPATH`
   - `WINEUSERLOCALE=en-ZA`
   - Wyn Play-shaped env, not the 20:12 Cursor leak

UTF-16 strings **in** `AssettoCorsa.exe`: `Initializing Steam:`,
`Steam cannot be initialized. Closing.`, `Steam has failed to initialize.`,
`Could not retrieve Steam ID`, `IGNOREDPI`, `MoveUGC`, `Create main window`.
**Not** in the binary: `GetIPCountry`.

There was a macOS `IOMediaBSDClient` panic ~22:00. Library on
`/Volumes/SSD1TB`. Treat that volume as fragile.

## Incoming analysis — keep vs discard

**Keep**
- Dual-process Windows model; wow64 parent should be able to spawn PE32+ child.
- 22:04 lacked absolute search paths; `KunosLauncher.prepare` did not run.
- Do not install MS .NET 4.x into this wow64 bottle (hollow NDP keys).
- mscorlib `VerifyWritable` ret-nop is the 20:12 Xaml fix; confirm it is
  still there before blaming culture again.
- CEF3 49 is a later problem. 20:12 already started CEF with disable-gpu
  **from Kunos itself** — do not invent a second flag set until there is a
  window again.
- `MainWindow..ctor(bool softwaremode)` is real. `/soft` is unverified;
  confirm from IL before relying on it.

**Discard / unverified**
- Decompiled C# mapping `0x004be` → `SteamAPI.Init` false →
  `SteamUtils.GetIPCountry()`. That is not from this exe. 20:12 logged
  `Initializing Steam: True` **after** the 22:04 crash offset, so `0x004be`
  is *before* that log line, not GetIPCountry-after-failed-Init.
- Table that puts POSIX in `MONO_PATH` and `Z:\` in `WINEPATH` (swapped).
- `wyn exec --bottle <uuid>`.
- `cd "$HOME/WynKit"` (repo is `~/Desktop/wyn`).
- `xxd | grep 2a` as mscorlib verification.

## What is already working (do not regress)

- `acs.exe` + D3DMetal + native d3dx11, `-windowed`, `avxEnabled: false`.
- `wyn ac set` / `--ac-car` for installed cars (86/180; rest are DLC stubs).
- Practice sessions so AI leave the pits. `TYPE=3` `TTS: 1.#INF00` is a
  **separate** sim bug.

## Constraints (hard)

- Same bottle. Same wineserver if Steam is Logged On. No `wineserver -k`.
- Do not make a 32-bit prefix. Do not launch `acs_x86.exe` as the answer.
- Do not switch `acs.exe` to DXVK. Do not native-first `d3d11`/`dxgi`.
- Do not install Content Manager / CSP / Pure as the default path.
- Do not flip `exePatterns` to `AssettoCorsa.exe` first until the UI stays
  up **and** starts `acs.exe`.
- Do not claim success from a process that exits with no window.

## Research questions (in order)

1. **What is null at `Startup.Main` IL `0x004be`?** Decompile for real
   (ilspycmd / ILSpy / `dnfile`). It sits after the IGNOREDPI log and
   before PID / culture / Steam init logs. Likely: arg parse, parent PID,
   missing sidecar, culture, relative `MONO_PATH`.
2. **Can we reproduce 20:12 search paths and get past `0x004be`?** Absolute
   `Z:\…\launcher\support` on `MONO_PATH`, support dir on Windows `PATH`
   and/or POSIX `WINEPATH`, cwd = install root, Steam Logged On. mscorlib
   is already patched, so the old `0x00778` Xaml crash should not return.
   Expected new log: `Initializing Steam: True` then `Create main window`
   then either a usable UI or a **new** crash site.
3. **Steam API** only after those log lines exist. 20:12 already proved
   Steam init can return true in this bottle when paths are right.
4. **CEF3 window stays up** (20:12 created it for ~4s then Xaml-died).
5. **32-bit parent `CreateProcess` 64-bit `acs.exe`** — only after a window
   that can Drive → Race.
6. Locale `en-ZA` vs `C` / `en-US` as a **single** isolated knob if (2)
   still NREs at `0x004be`.

## How to work without wrecking the session

- Prefer `launcher.log` / `.prev` / decompile. SSD already panicked once.
- If you launch `AssettoCorsa.exe`, written hypothesis, Play stays on
  `acs.exe`. Bottle name `Steam`.
- Confirm mscorlib VerifyWritable body starts `0x2A` with the known 25-byte
  pattern, not `grep 2a`.
- Rebuild Wyn.app if you need `prepare` from Play. `wyn run` does not call
  it unless you add that.

## Done looks like

**Minimum:** real decompile of `0x004be` **or** a log that passes it
(`PID:`, `Initializing Steam:`, `Create main window`) with the mscorlib
patch in place.

**Goal:** UI stays up; Drive → Race; parent starts PE32+ `acs.exe` on
D3DMetal.

## First hour

1. Decompile `Main` around `0x004be` and `0x00778`. Write real C#.
2. One experiment: 20:12 paths (absolute Windows `MONO_PATH` + support on
   `PATH`/`WINEPATH`), Steam Logged On, do not leak Cursor env. Compare
   new `launcher.log` to `.prev`.
3. If still `0x004be`, the SteamAPI/GetIPCountry story is already falsified;
   look at whatever is between IGNOREDPI and PID in the decompile.
