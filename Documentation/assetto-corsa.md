# Assetto Corsa handover (6 Sep 2026)

Status: **launched** (not verified). Monza grid loaded (~22:33). AI did not
drive. Not the full game.

Play starts `acs.exe` (64-bit sim). ~22:33 spawned original Monza with eight
Lotus Elise. The AI sat still because TYPE=3 start lights stuck at
`TTS: 1.#INF00`. Session files are now **practice** (TYPE=1, pits) so they can
move. The Kunos menu (`AssettoCorsa.exe`, 32-bit .NET) still dies before
Drive → Race. Do not switch the bottle to 32-bit — that cannot run `acs.exe`.

Do not mark the profile `verified`. Do not claim Content Manager / CSP / Pure.

Prior chat: [Assetto Corsa Wyn](7206e445-90fc-4011-bc86-9fc394794375).

---

## What “works” vs what the user asked for

| Surface | Result | Means |
|---|---|---|
| `acs.exe` (64-bit sim, D3D11) | Magione ~19:53. Monza 8 Lotuses ~22:33 | AI parked: start lights `TTS: 1.#INF00`. Next Play is practice so they drive. Wrench UI is setups, not a picker. |
| `AssettoCorsa.exe` (32-bit .NET 4 WPF + CEF3 Kunos UI) | Dies before Drive → Race | Already ran as wow64 (`PROCESSOR_ARCHITECTURE=x86`). NRE in `Startup.Main` 22:04. A 32-bit prefix cannot run `acs.exe`. |
| Steam tile / Wyn library | Game is listed and owned | Extra SSD library + symlink install had to be taught to Wyn first. |
| Session files | `TRACK=monza`, `CARS=8`, **practice TYPE=1** | Magione backup is `race.ini.wynbak`. `ks_monza` is not on this disk. |

The user is right: a Magione solo practice is not “Assetto Corsa working.”

---

## Machine (do not guess these)

- App: `/Applications/Wyn.app` (`com.fly.gaming`). CLI: `~/.local/bin/wyn`.
- Steam bottle: `~/Library/Containers/com.fly.gaming/Bottles/9FC8A16F-19F1-468E-B7FB-2F82000E6357`
- Wine: GPTK-aware 11.15 under `~/Library/Application Support/com.fly.gaming/Libraries/Wine`
- Game: original Kunos **Assetto Corsa**, Steam **244210**, not Competizione / EVO.
- Install: `/Volumes/SSD1TB/SteamLibrary/steamapps/common/assettocorsa`
- Size on disk ~27.5 GB (`appmanifest` `SizeOnDisk`). 180 car folders,
  **86 with sim files**, 94 Steam DLC stubs (`ui/` only). 21 tracks
  (35 layouts); several track folders are DLC stubs too.
- Profile id: `assetto-corsa`. Bundled JSON wins over
  `~/Library/Application Support/com.fly.gaming/Profiles/` for the same id.
- Source of truth: `WynKit/Sources/WynKit/Resources/Profiles/assetto-corsa.json`
- JSON-only app updates: copy into
  `/Applications/Wyn.app/Contents/Resources/WynKit_WynKit.bundle/Contents/Resources/assetto-corsa.json`
  then `codesign`. Swift changes need `xcodebuild` (see playbook).
- Logs: `~/Library/Logs/com.fly.gaming/`
- AC logs in the bottle: `drive_c/users/crossover/Documents/Assetto Corsa/logs/`
- Session files the sim loads: `assettocorsa/cfg/race.ini` and
  `assettocorsa/cfg/entry_list.ini`. Same pair is also written under
  `Documents/Assetto Corsa/cfg` in the bottle (that copy was the one touched at
  22:04). Magione is kept as `race.ini.wynbak`.

Wine’s Windows user is **`crossover`**. That is the bottle username (winecx /
Whisky heritage), not CrossOver.app. Dumps at `C:\users\crossover\...` are
inside the Wyn prefix. There is also `drive_c/users/ebenoelofse`. Direct
D3DMetal play writes as `crossover`. Do not “fix” this by pointing at
CrossOver.

**Do not `wineserver -k`.** Quit Steam from Steam’s own menu if the client
must go down.

**Do not switch to DXVK** because ProtonDB says so (Linux stack). D3DMetal is
the first layer. Do not native-first `d3d11`/`dxgi` on D3DMetal.

After 6 Sep ~22:00 the Mac kernel panicked:
`busy timeout[1], (60s): 'IOMediaBSDClient'` (watchdogd, Darwin 25.5.0,
`25F80`). That is the disk stack, not the Kunos zip dump. The library lives on
`/Volumes/SSD1TB` (`disk7s1`, APFS, ~82% full). Do not hammer that volume
immediately after a panic.

---

## Timeline (measured)

1. **Steam error 5:0000065432 / tile missing.** Wine Steam did not own the SSD
   library. Extra library `Z:\Volumes\SSD1TB\SteamLibrary` plus C: copy of
   `appmanifest_244210.acf` and a directory symlink
   `steamapps/common/assettocorsa` → SSD. `FileManager` enumerators do not
   follow directory symlinks, so Wyn hid the tile. **Shipped:**
   `SteamLauncher.resolvedInstallDirectory`, symlink-aware exe find,
   `steamappsRoots` including `/Volumes/*/SteamLibrary/steamapps`. Tests:
   `SteamSymlinkInstallTests`, `SteamLibraryRootsTests`.

2. **Instant quit after Play.** `acs.exe` brought up D3DMetal (AMD Compatibility
   Mode, 1920×1080 windowed) then crashed in Wine’s `d3dx11_43` stub
   (`__wine_stub_D3DX11CreateShaderResourceViewFromFileW`). Steam Jun2010
   CommonRedist already had the native DLL in `system32`; Wine ignored it.
   **Knob:** `WINEDLLOVERRIDES` …
   `d3d11,dxgi,d3d12,d3d10,atidxx64,nvapi64,nvngx=b;d3dx11_43,d3dcompiler_43=n`
   Do not add `d3dx11_43` to profile `winetricks` (corpus probe would fail).

3. **Profile `WINEDLLOVERRIDES` wiped at launch.**
   `launchGameOnGPTKWithD3DMetal` merged GPTK overrides with
   `{ _, new in new }`. **Shipped:** `combiningDllOverrides` +
   `Wine.applyD3DMetalGameOverrides(..., extraNative:)`. Tests in
   `SteamSafeOverridesTests`, `assettoCorsaUsesNativeD3DX11`.

4. **~19:53 — sim session.** `acs.exe` with `-windowed` and native d3dx11
   reached Magione in the Lotus. That is the only loaded-track proof.

5. **Kunos UI attempted so the user could pick car / track / AI.**
   `AssettoCorsa.exe` is PE32 i386 .NET 4.0 (WPF + CEF3 49). `acs.exe` is
   PE32+ x64. They are not interchangeable.

   - 19:09 Steam first-run: process lived ~2s, exit code 1. Steam’s .NET 4.7.2
     installer wrote registry `Install=1` but **did not install `clr.dll`**.
     Runtime is Wine Mono 11.2.0. Hollow NDP keys are a trap.
   - 20:05 Wyn Play: `MONO_PATH` missing → `Could not load file or assembly
     'CEF3'` (DLL is in `launcher/support/`, not next to the exe).
   - 20:12 With absolute `MONO_PATH=Z:\Volumes\SSD1TB\...\launcher\support`
     and support on `PATH`, UI reached `Initializing Steam: True` and
     `Create main window`, then `XamlParseException` in
     `ControllerSetupSlimDX` (`Main` IL **`0x00778`**):
     `NumberFormatInfo` is read-only on Wine Mono
     (`InvalidOperationException: Instance is read-only`).
   - Bottle patch: nop `NumberFormatInfo.VerifyWritable` in
     `drive_c/windows/mono/mono-2.0/lib/mono/4.5/mscorlib.dll` (first IL byte
     `0x2A` = ret). Backup: `mscorlib.dll.wynbak`. Wine-mono reinstall undoes
     this. Code: `WineMono.allowMutatingReadOnlyNumberFormat` (in CLI WynKit;
     **Wyn.app Play was JSON-copied, not a full `xcodebuild`**, so the GUI
     may not call this helper).
   - 22:04 After reboot: `NullReferenceException` in `Startup.Main` at
     **`0x004be`** — earlier than 20:12, before Steam/culture/PID logs.
     `MONO_PATH=launcher\support` (relative). No support dir on `PATH`.
     `WINEUSERLOCALE=en-ZA`. `GetIPCountry` is not in the exe; do not treat
     a guessed SteamUtils decompile as fact. Research prompt:
     `Documentation/assetto-corsa-kunos-research-prompt.md`.

6. **Play pointed back at `acs.exe`** so the user is not stuck on a dead
   launcher. `-windowed` restored (that is the 19:53 baseline).

7. **Monza + 7 AI session files.** Track chosen: original `monza`. Player car
   `lotus_elise_sc`. 7 AI → `CARS=8`.

8. **~22:33 — grid loaded.** Eight Lotuses on Monza. AI did not drive.
   `log.txt`: `Starting light should show. TTS: 1.#INF00` (infinity) for the
   TYPE=3 standing start, then the player quit (`RETIRING PLAYER FOR QUITTING`).
   Sim also wanted `[CAR_N] DRIVER_NAME` in `race.ini` (not only entry_list).
   **Session rewritten to practice (TYPE=1, SPAWN_SET=PIT)** so AI leave the
   pits. Do not point Play at `AssettoCorsa.exe`. Do not make a 32-bit prefix.

9. **AI aggression 100.** 22:33 log had `AI AGGRESSION: 0.000000` because
   `launcher.ini` `[SAVED] AI_AGGRESSION=0`. Official special events put 100
   on each AI car. Session + launcher slider now 100. Collisions already on;
   `assists.ini` DAMAGE=0 so they keep coming.

---

## Code and profile that landed

Keep these in sync: bundled JSON, `/Applications/Wyn.app/…/assetto-corsa.json`
(copy + codesign for JSON-only), CLI `swift build -c release` →
`~/.local/bin/wyn`. Full app Swift needs:

`xcodebuild -project Wyn.xcodeproj -scheme Wyn -configuration Release -derivedDataPath /tmp/WynDerivedData`

then helpers from the old app, codesign, ditto to `/Applications/Wyn.app`.

| Piece | Where |
|---|---|
| Profile | `assetto-corsa.json` — `acs.exe` first, `assettoCorsa: { track: monza, car: lotus_elise_sc, aiCount: 7 }`, `d3dmetal`, `avxEnabled: false`, `msync`, `win10`, MetalFX/HUD off, native `d3dx11_43,d3dcompiler_43=n`, `MONO_PATH=launcher\support`, `launchArgs: -windowed`, `status: launched` |
| Catalog | `game-catalog.json` slug `assetto-corsa`, Steam 244210 |
| Session writer | `WynKit/Sources/WynKit/Steam/AssettoCorsaSession.swift` — writes `race.ini` + `entry_list.ini` at Play when launching `acs.exe` |
| Sidecar CEF path | `WynKit/Sources/WynKit/Steam/KunosLauncher.swift` |
| Mono NumberFormat nop | `WineMono.allowMutatingReadOnlyNumberFormat` |
| DLL merge | `SteamLauncher.combiningDllOverrides` |
| Symlinks / extra libraries | `SteamLauncher` + tests named above |
| Tests | `assettoCorsaUsesNativeD3DX11`, `assettoCorsaLaunchesTheSimFirst`, `AssettoCorsaSessionTests`, `WineMonoNumberFormatTests`, `KunosLauncherTests` |

Current `exePatterns` order: **`acs.exe`, then `assettocorsa.exe`.**

---

## What is left (this is the job)

### 1. Confirm AI drive in practice (this session)

Play `acs.exe` again. Monza, eight Lotuses, pits, 20-minute practice. The AI
should leave and circulate. That is the remaining sim proof.

Standing-start races are blocked on `TTS: 1.#INF00` until that timer is
understood. Do not treat parked grid cars as “AI unimplemented.”

The Kunos Drive → Race menu is a separate 32-bit .NET crash. Wine already
ran it as 32-bit wow64. Last evidence: 22:04 NRE in `Startup.Main` at
`0x004be`. A 32-bit-only bottle cannot run 64-bit `acs.exe`.

You still pick from the **installed** cars without that menu. 94 of the
180 folders are Steam DLC shop windows (`dlc_ui_car.json`, no meshes).
`acs.exe` already loads whatever `race.ini` names, if those files exist:

```
wyn ac list-cars
wyn ac list-tracks
wyn ac set --car "elise" --track spa --ai 11
wyn play assetto-corsa
# or one shot:
wyn play assetto-corsa --ac-car elise --ac-track spa --ac-ai 11
```

Wyn.app Play then uses the written `race.ini`. A GUI picker needs a
full `xcodebuild`, not a JSON copy.

### 2. Kunos launcher (only if they insist on Drive → Race)

Still broken. Last failure 22:04 NRE in `Main`. Previous failure was Wine Mono
WPF + CEF49 + 32-bit wow64. Do not install Content Manager / CSP / Pure until
a vanilla launcher → `acs.exe` path is confirmed — and do not prefer CM just
because the Kunos UI is painful.

Research prompt for a fresh agent (copy the block after the line):
`Documentation/assetto-corsa-kunos-research-prompt.md`.

If retrying the UI: confirm `mscorlib` still patched (`0x2A` at VerifyWritable
IL), absolute `MONO_PATH`/`WINEPATH` to `launcher/support`, rebuild **Wyn.app**
so `KunosLauncher.prepare` runs, Steam Logged On, no leftover `AssettoCorsa.exe`.
After an `IOMediaBSDClient` panic, treat the SSD as fragile.

### 3. Wyn.app vs CLI

`KunosLauncher.swift` / `WineMono` NumberFormat helper are in the WynKit tree
and the CLI. The GUI you signed on 6 Sep evening was mostly **JSON copies**,
not a full Release `xcodebuild`. Next person who needs those helpers from Play
must rebuild the app and re-bundle helpers (`steamwebhelper_shim.exe`, etc.).

### 4. After a real race (not Magione solo)

One knob at a time from the 19:53 baseline: drop `-windowed`, then try
`avxEnabled: true`. Do not change the layer. A different track or AI count
is a JSON change, not a layer change.

### 5. Housekeeping

- Hollow .NET 4.7.2 registry vs missing `clr.dll` — do not assume MS CLR is
  present.
- `winetricks` on this profile is still a declaration (`vcrun2019` /
  `vcrun2022`). Wyn does not run winetricks.
- Do not add unrecognised winetricks verbs without a `WindowsRuntimes` probe.
- Catalog test count was 116 when this was written; do not invent a new number.

---

## Binaries on disk (do not reshuffle casually)

| File | Role |
|---|---|
| `acs.exe` | 22.8 MB, 64-bit sim. **Play this.** |
| `AssettoCorsa.exe` | 5.3 MB, 32-bit Kunos UI. Not working here. |
| `acs_x86.exe` | 32-bit sim. Skip. |
| `acShowroom.exe` / `acServer.exe` | Skip. |
| `launcher/support/CEF3.dll`, `libcef.dll`, paks | Kunos UI only. |

---

## Next session, first moves

1. Play `acs.exe` into the practice files. Look for AI leaving the pits.
2. Do not start from the Kunos exe. Do not rebuild the bottle as 32-bit.
3. Drive → Race is the 22:04 NRE, not a missing 32-bit Wine.
4. Leave Steam Logged On. Do not `wineserver -k`.
