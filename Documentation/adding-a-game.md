# Adding a game to Wyn

A playbook, ordered by what has actually worked on this machine.

Solarpunk took four launches to get right. Nothing we learned in those four
launches was unknowable up front — we just started from an optimistic profile
and bisected downwards every time it crashed. This document inverts that. Start
from the profile least likely to crash, confirm the game reaches a loaded map,
*then* relax settings one at a time. First attempt succeeds, and every later
change has a known-good baseline to be compared against.

Everything here is a measurement or a rule the code enforces. Where a claim came
from one game, it says so.

---

## 0. The one rule

**The first launch is a diagnostic, not a play session.**

You are not trying to get good frames. You are trying to answer one question:
*does this game reach a loaded map at all under Wine?* Every setting in the
first profile is chosen to make that answer as likely as possible, at any cost
to performance or fidelity. Once you have a "yes" and a log to prove it, you
have a baseline, and improving from a baseline is cheap. Guessing your way to
one is not.

The three Solarpunk failures were all the same mistake in different clothes:
each launch changed a setting that *might* be the problem, from a starting point
we had never seen work.

---

## 1. Read the disk before you write anything

`inspect_game_files` before you form an opinion. What the install directory
shows beats what anyone remembers about the game, including a model with the
whole internet in its weights.

This is not a style preference. 72 shipped profiles once carried
`D3DM_ENABLE_METALFX=1`, written confidently from knowledge, and MetalFX is the
one setting we had measured crashing the one game anybody had actually played.
Confident recall produced 72 broken profiles; a directory listing would have
produced none.

Read off disk:

| What | Where | Why it decides something |
|---|---|---|
| Engine | `Engine/Binaries`, `*/Binaries/Win64`, `UnrealGame` | UE gets `unrealProject` and a real log file |
| The game executable | `*/Binaries/Win64/*-Shipping.exe` | goes in `exePatterns` |
| Shipped graphics DLLs | install root and `Binaries/Win64` | `vulkan-1.dll` and no `d3d12.dll` ⇒ Vulkan-native |
| Prereq shim | a suspiciously small `<Game>.exe` next to a large `<Game>-Win64-Shipping.exe` | it is a launcher, not the game — see §7 |

The biggest binary in the folder is often `CrashReportClient.exe`. Do not point
`exePatterns` at it. `save_profile` checks patterns against real files, so a
wrong guess here is caught, but a *plausible* wrong guess (the crash reporter
does exist) is not.

---

## 2. Choose the layer from what the game ships

This is the one decision you cannot brute-force later, because it silently
changes how Wyn launches the game (§7). Get it from the file listing:

| The game ships | Layer | Notes |
|---|---|---|
| `vulkan-1.dll`, no `d3d12.dll` | `dxvk` with `dxvk: false` | The MoltenVK path. D3DMetal cannot translate Vulkan at all. |
| D3D12 | `d3dmetal` | DXVK does not do D3D12. Not a preference — it is the only option. |
| D3D11 | `d3dmetal` first | Then `dxvk` with `dxvk: true` if D3DMetal fails. |
| Nothing conclusive | `d3dmetal` | 81 of 119 shipped profiles use it. |

**D3DMetal is the default, not the fallback.** The shipped corpus is 81
d3dmetal / 36 dxvk / 2 dxmt, and on the one D3D11 game we bisected properly
(Solarpunk) DXVK was strictly worse: D3DMetal rendered 998 frames while DXVK
could not create a swapchain at all (`D3D11Util.cpp:249 CreateSwapChainResult
failed with error E_FAIL`). Switching layers on a crash feels like progress and
usually is not — it replaces a failure you understand with one you don't.

---

## 3. The safe first profile

Write this, launch it, and only then start improving. Every value is a
maximum-compatibility choice with a reason.

```json
{
  "id": "<slug>",
  "name": "<Name>",
  "publisher": "<Publisher>",
  "steamAppId": 0,
  "exePatterns": ["<game>-win64-shipping.exe", "<game>.exe"],
  "bottle": {
    "windowsVersion": "win10",
    "translationLayer": "d3dmetal",
    "dxvk": false,
    "dxvkAsync": false,
    "enhancedSync": "msync",
    "avxEnabled": false,
    "metalHud": false
  },
  "environment": {
    "WINEDLLOVERRIDES": "d3d11,dxgi,d3d12,d3d10,atidxx64,nvapi64,nvngx=b",
    "MTL_HUD_ENABLED": "0",
    "D3DM_ENABLE_METALFX": "0",
    "D3DM_ENABLE_ASYNC_COMMIT": "0",
    "D3DM_SHOW_HUD_STATS": "0"
  },
  "winetricks": ["vcrun2019", "vcrun2022"],
  "launchArgs": "-windowed -ResX=1280 -ResY=720",
  "status": "guessed"
}
```

Why each one:

- **`avxEnabled: false`.** `avxEnabled` sets `ROSETTA_ADVERTISE_AVX=1`, which
  tells the binary AVX is available. Some binaries then emit an instruction
  Rosetta will not execute and die instantly with
  `EXCEPTION_ILLEGAL_INSTRUCTION` — before a window, before a log line worth
  reading. It is per-title: Satisfactory keeps AVX on and is fine, Solarpunk
  dies twice with it on. Since the failure is total and the cost of leaving it
  off is a few percent, off is the correct starting point and *on* is the
  optimisation you try later.
- **`-windowed`.** Fullscreen swapchain creation is the single most fragile
  operation in this stack. On Solarpunk, D3DMetal fullscreen reached frame 1 and
  died with `EXCEPTION_ACCESS_VIOLATION` writing `0x980`; DXVK fullscreen failed
  swapchain creation outright. Windowed worked on the first try. Two independent
  layers failing the same operation is the strongest signal in the whole
  investigation.
- **`-ResX=1280 -ResY=720`.** Cheap, and keeps the first launch off any
  display-mode edge cases. Note this is *not* what fixed Solarpunk — see §6.
- **HUD and MetalFX at `"0"`.** Measured: MetalFX on crawls to ~0.1–2 fps and
  then SIGILLs in `D3DMCommandQueue::ExecuteCommandLists`. The validator refuses
  anything else, so this is not optional.
- **`=b` overrides.** On `d3dmetal` the d3d DLLs must be builtin. Native-first
  (`=n,b`) is correct only under `dxmt`, and the validator scopes the rule that
  way.
- **`msync`.** 118 of 119 profiles.
- **`win10`.** 119 of 120.
- **`vcrun2019` + `vcrun2022`.** 114 and 79 profiles respectively. Note that
  Wyn currently only *prints* `winetricks`; nothing installs them (§8).

For a UE game also set `"unrealProject": "<ProjectName>"` — that is what points
the diagnostics at `Saved/Logs/<ProjectName>.log`, and that log is where every
answer in §5 comes from. `-NO_EOS_OVERLAY` is worth adding on UE titles (9
profiles) if the game ships EOS.

---

## 4. Relax one knob at a time, in this order

Only after the game has reached a loaded map. One change per launch, and keep
the log from each.

1. Drop `-windowed`. Biggest quality-of-life win, most likely to regress.
2. Raise the resolution.
3. Turn `avxEnabled` on. Watch for an instant `EXCEPTION_ILLEGAL_INSTRUCTION`;
   if you see one, off is permanent for this title.
4. Nothing else. MetalFX and async commit stay off — that is measured, not
   cautious.

If a step regresses, revert it and stop. A profile that plays windowed at 720p
is worth shipping; one that might play fullscreen is not.

---

## 4b. Performance is part of the job

A profile that launches is not a profile that is finished, and the difference is
not cosmetic. Measured on Solarpunk — same settings, same resolution, same
machine:

| | DXVK | D3DMetal |
|---|---|---|
| median fps | 45.4 | **119.7** |
| min / max | 29.9 / 69.3 | 116.7 / 120.2 |
| layer log noise | 126,296 err/warn lines | none |

`wyn profiles performance <id>` (and `read_session_performance` over MCP) reads
this back out of the game's own log:

```
Layer that actually ran: D3DMetal (Apple GPTK)
  adapter reported: AMD Compatibility Mode
Frame rate: min 99.8  p25 117.0  median 119.6  p75 120.0  max 120.2  (33 min)
Rendering: 1280x720 at 45% screen percentage → ~576x324 effective
```

**Always check the layer before you read the frame rate.** The profile does not
decide it — the Wine tree the bottle is running does (§7b), and a number
measured on the wrong layer is not evidence about the right one.

Then judge the frame rate **against the resolution that produced it**. 45 fps is
fine at 4K and alarming at 576×324. Slow *at a low resolution* is the signature
of a structural problem, and the reflex it has to override is "turn the settings
down" — that reflex cost a day here.

Frames above the display's refresh rate are discarded: power and heat for
nothing. VSync in the game's own settings is the fix. Never `-ExecCmds`.

---

## 5. What counts as "it works"

Not "a window appeared". From the game's own log — for UE that is
`Saved/Logs/<Project>.log`, not the crash directory:

- `LogWorld: ... LoadMap(/Game/Maps/<something>)` — it got past the engine into
  actual content.
- A frame count in the hundreds. Solarpunk's verified run logged 998+.
- `LogExit: Exiting.` — a clean shutdown, which rules out a crash you did not
  notice because you closed the window first.
- No crash directory newer than the run.

`status: "verified"` means those four things were observed and written down.
A model connected over MCP cannot set it — `save_profile` forces `guessed`
whatever the field says, Wyn promotes to `launched` by itself after a minute of
uptime, and `verified` is a human act. `onlyMeasuredProfilesClaimVerified` in
the test suite is the enforcement: it enumerates every verified profile by name,
so adding one without measuring breaks the build.

---

## 6. Read the crash correctly

Three ways we nearly fooled ourselves on one game:

**The last line before a crash is not the cause.** Solarpunk's final log line
was `LogRenderer: Forcing update for all mesh draw commands: SkyLight change`,
which looks damning. It also appears at frame 908 of the *working* run, and
during clean shutdown. Before believing a line caused a crash, grep it in a
healthy log.

**Do not change two things at once.** We nearly credited `-ResX=1280 -ResY=720`
with fixing Solarpunk. Checking the crashing run's log showed
`LogConfig: Set CVar [[r.setres:1280x720]]` was already present there too, so
resolution was constant across both runs and `-windowed` was the only live
variable. Diff the logs before you write down a cause.

**"It got worse" is a result.** Switching to DXVK made Solarpunk fail *earlier*,
at swapchain creation. That looked like a wasted attempt and was actually the
decisive one: it identified the swapchain as the fragile operation, which is
what suggested `-windowed`.

Noise you can ignore: `invalid ShaderMap` and "uncooked shader map" errors — the
engine runs hundreds of frames past them.

---

## 7. The layer secretly picks the launch path

Not obvious, and it bit us:

- **`d3dmetal`** runs the game executable directly. Always. `--direct` is
  implied and the flag is ignored.
- **`dxvk` / `dxmt`** go through `steam.exe -applaunch <appid>`, which means
  *Steam* chooses which executable runs. Use `wyn play <id> --direct` to bypass
  that.

Why it matters: when Steam picks the executable it often picks the small prereq
shim (`Solarpunk.exe`) rather than the real binary
(`SolarpunkSteam-Win64-Shipping.exe`), and that shim throws a "Visual C++
2015-2022 Redistributable" dialog. **This dialog is a false negative.** The
redistributable was installed the whole time — the registry showed
`VC\Runtimes\x64 Installed=1, Version v14.51.36247.00`. On `d3dmetal` the dialog
never appears, because the direct launch bypasses the shim entirely.

You no longer have to read the registry by hand for either half of this. The
effective layer and the launch path it implies show in `wyn profiles show`, in
the app's status strip beside the selected game, and in the diagnostics bundle;
§8 covers the runtime check. Both were added because this investigation needed
them and neither existed.

---

## 7b. The profile does not decide the translation layer

Worse than §7, and the same shape. `WINEDLLOVERRIDES d3d11=b` asks for
**builtin**, and builtin is D3DMetal only in the **game-host** Wine tree. If the
bottle's wineserver is already up on the frankea tree — because Steam was
started there, and Wyn adopts a live Steam rather than restarting it — the game
gets the bottle's own native DXVK `d3d11.dll` instead. The profile is correct
and irrelevant.

This ran a two-hour session at a third of the frame rate with no symptom but a
warm Mac.

**Before launching**, `wyn runtime status`:

```
GPTK stubs:  D3DMetal selected            <- what is installed
Live tree:   game (GPTK-aware Libraries)  <- what the next launch will get
```

**After launching**, the adapter in the game's own log, which is the only
reliable answer:

| Layer | Adapter | VendorId |
|---|---|---|
| D3DMetal | `AMD Compatibility Mode` | `0x1002` |
| DXVK | `NVIDIA GeForce 6800` | `0x10de` |

Remedy: `wyn steam quit`, then launch again. **Never `wineserver -k`.**

---

## 8. What `winetricks` in a profile means

**It is a declaration, not an installation.** Wyn does not run winetricks and
does not download Microsoft redistributables. The games that need them get them
from Steam's own prerequisite installer when the game installs.

What Wyn does do is *check*. `wyn profiles show <id>` reads the bottle's
`system.reg` and reports what is actually there:

```
Runtimes:
  Visual C++ 2015-2022 runtime: present (v14.51.36247.00)
```

The same check runs before `wyn play` (a warning, never a block — it is a
registry heuristic), appears in the app's status strip when something is
genuinely absent, and lands in the diagnostics bundle as
`windows-runtimes.txt`. That last one matters most: a beta report should not
require the reporter to know to go and read a registry hive.

Three outcomes, deliberately, because two would force a lie: **present**,
**missing**, and **not checked** — the last for a bottle with no registry yet,
or a verb Wyn has no probe for. A verb nobody taught it to look for is never
silently reported as satisfied. `everyVerbInTheShippedCorpusIsRecognised` fails
the build if a profile starts declaring something new.

Note `vcrun2019` and `vcrun2022` are the same redistributable — Microsoft has
shipped 2015 through 2022 as one 14.x runtime since 2017, with one registry key
— so a profile listing both gets one line, not two.

---

## 9. Never

These are in the validator, the guardrails, or both, and each one cost us
something:

- `wineserver -k` — kills the bottle out from under a running game.
- `wineboot -u` — reinitialises the prefix.
- `xinput*=d`, `FG.InputMode`, `ForceMouse` — break input in ways that look like
  a hang.
- `-ExecCmds` — arbitrary console commands, unpredictable per engine version.
- `MTL_HUD_ENABLED=1`, `D3DM_SHOW_HUD_STATS=1`, `metalHud: true` — a developer
  overlay drawn over the game.
- `D3DM_ENABLE_METALFX=1`, `D3DM_ENABLE_ASYNC_COMMIT=1` — measured crash.
- `=n,b` d3d overrides under `d3dmetal`.
- Shipping a GPTK or D3DMetal binary in the repo.

---

## 10. Case files

**Solarpunk** (UE5, D3D11, `d3dmetal`) — four launches: AVX on ⇒ instant
`EXCEPTION_ILLEGAL_INSTRUCTION`; AVX off fullscreen ⇒
`EXCEPTION_ACCESS_VIOLATION 0x980` at frame 1; DXVK ⇒ no swapchain
(`E_FAIL`); AVX off + `-windowed` ⇒ 998 frames, clean exit. Under §3 this is one
launch. `-dx11` turned out to be a no-op — an empty command line already logged
`Using Default RHI: D3D11`.

**Satisfactory** (UE5, D3D11, `d3dmetal`) — the counterexample that keeps §3
honest: `avxEnabled: true` and fullscreen, both fine. Its crash was MetalFX,
which is why MetalFX is now refused corpus-wide.

**The 72** — profiles generated in batches of ten with MetalFX and HUD on,
written from recall. Fixed by script, then locked down by `ProfileValidator`
plus a test that runs every rule against every shipped profile, so the class of
error cannot come back.
