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
`VC\Runtimes\x64 Installed=1, Version v14.51.36247.00`. Check the registry
before chasing it. On `d3dmetal` the dialog never appears, because the direct
launch bypasses the shim entirely.

---

## 8. Known gaps

- **`winetricks` in a profile is never executed.** All 120 profiles carry the
  key; the only code that touches it is `print()` in `WynCmd/main.swift:430`. So
  `vcrun2019` in a profile documents a dependency, it does not satisfy one.
- **The launch path is invisible in the UI.** Changing the translation layer
  silently changes whether Steam or Wyn picks the executable (§7), and nothing
  says so on screen.

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
