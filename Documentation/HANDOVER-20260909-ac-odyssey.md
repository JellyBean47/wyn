# Handover — Assassin's Creed Odyssey (9 Sep 2026, ~21:38 SAST)

**Next agent: start here.** Goal is play `ac-odyssey` (Steam 812140) on this
Mac with **D3DMetal**, not DXVK. Status stays `launched` until a loaded-world
measurement on the game-host tree. Do not mark verified. No PR was needed for
the earlier website work.

## State at 21:38 — Connect-on-GPTK worked; Ubisoft rate-limited

`wyn play ac-odyssey --d3dmetal` at **21:35** did the product path:

- Fresh GPTK wineserver **15840** (old 1986 was reset via Wyn `killBottleAndWait`, not a shell `wineserver -k`)
- Steam `-silent` **Logged On** `[U:1:1820256332]` at **21:35:34** (JWT remember-me)
- `upc.exe` attached on that same wineserver (no `--frankea-steam`, no DXVK)
- Auth signal: `Launch Wine tree: game (GPTK-aware Libraries)` / `Graphics layer: D3DMetal (GPTK)`
- DXVK log `ACOdyssey_d3d11.log` still mtime **19:46** (not rewritten)

**Connect painted a window on GPTK.** User screenshot 21:36: Ubisoft
"Access is temporarily restricted" (unusual activity / bot / IP
197.245.178.221 / developer tools). That is a **Ubisoft account gate**, not
a missing Connect process and not the DXVK freeze.

User: wait **~30 minutes** (retry ~22:08 SAST), then play again. Do not
hammer Connect. Do not `--frankea-steam`. Do not `wineserver -k`. Leave
Steam Logged On on 15840 if it is still up.

Code already landed: `ConnectLauncher` attaches `upc.exe` to a live
game-host wineserver (StartView in the new log tail, no FLY4 required).
`launchGameDirectD3DMetal` starts Connect after Steam is Logged On.

## State at 22:12 — Ubisoft still rate-limited (second Connect window)

22:10 retry: Steam was Logged Off (`Session Replaced` 21:46). Restarted
`steam.exe -silent` on **same** wineserver 15840 (no `wineserver -k`).
Fresh Logged On **22:10:35**. `wyn play ac-odyssey --d3dmetal` attached
Connect again; user got the **same** “Access is temporarily restricted”
window. Play + `upc.exe` stopped. Steam left Logged On.

Do not launch Connect/Odyssey again until the user says the wait is over.
30 minutes was not enough. Do not hammer. Do not `--frankea-steam`.


Prior chat: [Ready or Not setup issues](ab60c79a-e9b3-4773-bdfd-cc7f91962a48)
(this thread). Parked recipe: [Website game verification](8fd5c2b8-5181-46ea-8879-5f9de117b20a).

## What the user said (do not drop this)

**Connect has to be running for an Odyssey launch.** The game auths with
**both Steam and Ubisoft Connect** before it will come up. Saved Connect
login is not enough if `upc.exe` is not in the bottle. Tonight we launched
D3DMetal without Connect; `ACOdyssey.exe` sat idle (0% CPU, ~6 MB, no
window) for minutes. That is a failed launch, not a slow one.

`ConnectLauncher` currently **refuses GPTK** (`connectOnGPTK`).
`wyn play --d3dmetal` **skips** opening Connect (“saved login required”).
Those two facts are the product bug the next session has to resolve. The
user’s requirement wins over the skip.

## The two-tree conflict

| Need | Tree | Why |
|---|---|---|
| Connect CEF paints | frankea `Libraries.steam` | FLY4 + `--in-process-gpu` + SwiftShader. Documented in `Documentation/ubisoft-connect.md`. `ConnectLauncher` comment: never GPTK. |
| Odyssey 3D | GPTK `Libraries/` | `CX_GRAPHICS_BACKEND=d3dmetal`, `libd3dshared`, `d3d11,dxgi=b`. |
| Same wineserver | one prefix | Steam + Connect + game must share one `WINEPREFIX`. You cannot keep frankea Connect and move only the game to GPTK. |

`--frankea-steam` keeps Connect+Steam on frankea and **falls back to
DXVK-macOS 1.10.3**. That is how we got in-game earlier tonight, and how
the Mac froze.

`--d3dmetal` / default play uses GPTK and **does not start Connect**.

## Tonight’s evidence

### Freeze was DXVK, not “no FPS cap”

Frankea play (`wyn play ac-odyssey --frankea-steam`) printed:

- `WRONG TRANSLATION LAYER`
- `Auth path: frankea + DXVK-macOS`
- `Graphics: DXVK-macOS 1.10.3 on frankea (not upstream 2.x — needs geometryShader)`

Game log (mtime **19:46**):

`…/Bottles/9FC8A16F-19F1-468E-B7FB-2F82000E6357/drive_c/fly/logs/ACOdyssey_d3d11.log`

- `DXVK: v1.10.3-20230507-async (macOS)`
- `geometryShader: 0` (AnvilNext needs GS; pipelines fail)
- `DxvkGraphicsPipeline: Failed to compile pipeline` (`gs : GS_…`)
- Present `VK_PRESENT_MODE_IMMEDIATE_KHR` at 1920×1080 then 1600×900
- Ends in `VK_ERROR_DEVICE_LOST` — that is the freeze

`ACOdyssey.ini` had `MaxFPS=60` / `IsFpsLimitEnabled=1`.
`AdapterVendorID=4318` is NVIDIA `0x10DE` (DXVK fake), not D3DMetal’s AMD
Compatibility Mode (`0x1002`).

### How it was smooth last time (parked / git)

Parked profile in `/Volumes/Untitled/parked-wyn/park-wyn-20260902-0106.tar`
and current `ac-odyssey.json`:

- `translationLayer: d3dmetal`, `dxvk: false`
- `CX_GRAPHICS_BACKEND=d3dmetal`
- AppDefaults `acodyssey.exe`: `d3d11,dxgi,d3d12,d3d10=b`
- M4 16GB: **1080p low–med, ~70% scale**
- Connect CEF knobs as in the profile notes (`dwrite=builtin`; **do not**
  set `libEGL/libglesv2=d`)

That was winecx/GPTK D3DMetal, **not** frankea DXVK.

### D3DMetal play without Connect (21:00)

`./.build/debug/wyn play ac-odyssey --d3dmetal`

- GPTK wineserver, Steam Logged On, `CX_GRAPHICS_BACKEND=d3dmetal`
- Wyn: “not opening Connect on frankea… Saved Connect login is required.”
- `ACOdyssey.exe` pid 3197: 0% CPU, ~1.4–6 MB RSS, no window, no `upc.exe`
- Wine log `2026-09-09T19:00:58Z.log` never grew past the env dump
- Documents/`ACOdyssey.ini` not updated (still 19:55 from the DXVK session)
- User saw Wine Steam **store** (Valheim) and thought Steam crashed. Steam
  did not crash. The game never created a window.

### Restart attempt (21:10–21:21)

1. Killed stuck `ACOdyssey.exe` only (not `wineserver -k`).
2. `wyn steam quit` — Steam **ignored `-shutdown`** three times.
3. Stopped `steam.exe` + leftover `steamwebhelper` so the prefix could drain.
   GPTK `wineserver` **pid 1986 never exited** (orphaned, still up at 21:23).
4. `wyn steam launch` (visible GPTK) — `steam.exe` up, **no CEF / no window**,
   `wyn` spun ~100% CPU, stdout buffered. Killed (rc 143).
5. User: menu-bar Steam, no Dock icon. Menu bar is **native**
   `Steam.AppBundle/…/ipcserver` (pid 1215). `-silent` never puts Steam in
   the Dock. User is fine with `-silent` first.
6. GPTK `steam.exe -silent` started (pid 12628). **Never Logged On.**
   `connection_log.txt` still ends at **21:10:49 LogOff**. No
   `steamwebhelper`, 0% CPU. Wedged on wineserver 1986.

## State at handover (21:23 SAST)

```
1215  native Steam ipcserver   (menu-bar icon — not Wine)
1986  GPTK wineserver          (up since ~19:56, poisoned)
12628 steam.exe -silent        (GPTK, Logged Off, no CEF)
      upc.exe                  ABSENT
      ACOdyssey.exe            ABSENT
```

Bottle:
`~/Library/Containers/com.fly.gaming/Bottles/9FC8A16F-19F1-468E-B7FB-2F82000E6357`

Steam: Logged On `[U:1:1820256332]` until 21:10:49, then user-initiated
logoff. Remember-me should still be in the bottle once a **healthy**
client starts.

`upc.exe` is installed:

`…/drive_c/Program Files (x86)/Ubisoft/Ubisoft Game Launcher/upc.exe`

Present helpers: `Tools/bin/fly_stretch_epi_bridge.fast.dylib` +
`present_force_inject.dylib`. Connect CEF flags (do **not** use
`--disable-gpu`): `--no-sandbox --in-process-gpu --disable-gpu-compositing
--use-gl=angle --use-angle=swiftshader-webgl`. `PRESENT_FORCE_OPAQUE=1`.

## What to do next

1. **Get a live wineserver.** Pid 1986 has no healthy clients. Do **not**
   `wineserver -k` from the shell unless the user explicitly asks — Wyn’s
   own migrate path (`Wine.killBottleAndWait`) is the product hook. Prefer
   Steam → Exit on a client that can paint, then wait for 1986 to die.
2. **Start Steam Logged On** on the tree you will play on. `-silent` is OK
   if `connection_log` gets a **new** `[Logged On]` after the start. Do not
   trust a process list alone.
3. **Start `upc.exe` on that same wineserver before `ACOdyssey.exe`.**
   Wait until Connect is actually up (StartView + FLY4 frame on frankea;
   on GPTK the UI may be transparent — process + launcher log still
   required). User: game fails without Connect auth.
4. **Then** `wyn play ac-odyssey --d3dmetal` (or default play, **not**
   `--frankea-steam`). Confirm:
   - Wyn says `Launch Wine tree: game (GPTK-aware Libraries)`
   - `Graphics layer: D3DMetal (GPTK)`
   - **no** `WRONG TRANSLATION LAYER` / `DXVK-macOS`
   - `ACOdyssey_d3d11.log` is **not** rewritten (that file is DXVK)
   - Game window exists and CPU/RSS look like a real session
5. In-game: 1080p low–med, ~70% scale, keep the 60 fps cap.

If you must use frankea so Connect paints, say so to the user: that path
is DXVK and already DEVICE_LOST once tonight. Do not treat it as the
smooth recipe.

## Commands / paths

```
cd /Users/ebenoelofse/Desktop/wyn
./.build/debug/wyn steam quit          # never wineserver -k
./.build/debug/wyn steam launch        # GPTK visible (CEF may fail)
./.build/debug/wyn steam launch --frankea-steam   # Connect-capable UI; DXVK play
./.build/debug/wyn play ac-odyssey --d3dmetal
./.build/debug/wyn play ac-odyssey --frankea-steam   # DXVK — do not use for the real run
```

Logs:

- Wyn: `~/Library/Logs/com.fly.gaming/`
- Steam: `…/Steam/logs/connection_log.txt`
- DXVK (bad path): `…/drive_c/fly/logs/ACOdyssey_d3d11.log`
- Connect: `…/Ubisoft Game Launcher/logs/launcher_log.txt`
- Ini: `…/users/ebenoelofse/Documents/Assassin's Creed Odyssey/ACOdyssey.ini`

Exe: `/Volumes/SSD1TB/SteamLibrary/steamapps/common/Assassins Creed Odyssey/ACOdyssey.exe`

## Code pointers

- Skip Connect on D3DMetal: `SteamLauncher.launchGame` ~1034–1039
- Connect refused on GPTK: `ConnectLauncher.launch` ~75–77
- Frankea Connect then DXVK play: `prepareUbisoftConnectThenFrankeaSteam`
- Profile: `WynKit/Sources/WynKit/Resources/Profiles/ac-odyssey.json`
- Queue: `Documentation/verify-next.md`

## Do not

- `--frankea-steam` for the “smooth / D3DMetal” run
- `wineserver -k` unless the user asks
- Re-add `libEGL/libglesv2=d` (Connect NOTREACHED storm, 9 Aug)
- Mark `verified` without a loaded-world measurement
- Trust a Steam menu-bar icon or a sleeping `ACOdyssey.exe` as “the game is up”
