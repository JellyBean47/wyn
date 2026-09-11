# Working on Wyn

Wyn runs Windows games on macOS through Wine plus a Direct3D→Metal layer
(D3DMetal/GPTK, DXMT, DXVK). This file is what a session should know before
touching anything. It is short on purpose; the long-form evidence lives in
`Documentation/` and in `~/wyn-handovers/`.

**Start by reading the newest `~/wyn-handovers/HANDOVER-*-START-HERE.md`.** It
carries the current state, what is half-finished, and which theories have
already been disproved. Handovers are outside the repo deliberately —
`Documentation/HANDOVER-*` is gitignored and was lost to branch switches once.

## The one rule that matters most

**Measure the running process. Never conclude from a file size, a declared
config field, or a profile's own notes.**

`lsof -p <pid>` on the live game is the instrument. It has overturned a
confident wrong answer three times in this project:

- "Switching trees corrupts the prefix — `winemetal.dll` is the broken joint",
  argued from file sizes. `lsof` showed `winemetal.dll` loads from the *running
  tree*, so the PE/unixlib pair is always matched. See
  `FINDING-20260911-tree-switch-corrupts-prefix.md`.
- "Army Men and New Vegas run on their declared layers." They do not. Both load
  builtin `ddraw`/`d3d9` → `wined3d` → OpenGL, with their DXMT/DXVK payload
  deployed into the prefix and **never opened**.
- "DOOM hangs" — inferred from one core pinned and no file growth. It was
  rendering a 91% loading screen the whole time and waiting on audio.

Two corollaries:

- **What a launch deploys is not what the process loads.** Both are worth
  measuring, and they disagree often.
- **When a process looks hung, make its own tooling say so.** `sample` cannot
  unwind Wine stacks (it collapses into a bogus `__wine_syscall_dispatcher`
  recursion). `MVK_CONFIG_LOG_LEVEL=3` and `WINEDEBUG=+ole` each answered in
  one run what guesswork got wrong for an hour.

When a previous finding turns out to be wrong, **say so at the top of the
document that carries it** rather than quietly writing a new one. Every
`FINDING-*.md` here has dated corrections in it; that is the format working as
intended.

## Facts that cost real time to rediscover

**Two Wine trees, and they are not interchangeable.**
`Libraries` is the game-host tree (winecx, GPTK/D3DMetal); `Libraries.steam` is
a symlink chain to `Libraries.dxmt-wine11.0` (the "frankea" gcenx build). A
launch on the other tree **re-provisions the prefix** — ~600 DLLs per arch —
and a running wineserver from one tree locks the other out
(`version mismatch 930/1812`). Re-provisioning is triggered by the *tree
switch*, not by launching.

**The live D3DMetal lives in a directory named `.bak`.**
`Libraries/Wine/lib/external` is a symlink to `external-3.0.bak`. Deliberate.
Do not "clean it up".

**One bottle is shared by every game.** A profile's settings are applied
launch-scoped (`ProfileApplicator.launchSettings` / `launchLayerOverride`) and
must not be written back — a persisted per-game layer becomes the next game's
default, which is how New Vegas left the bottle on `dxmt`. `wyn profiles apply`
is the one deliberate write.

**Per-exe `AppDefaults\<exe>\DllOverrides` persist forever.** Nothing removes
them, so every launch must state what it needs; a stale `d3d*=b` from an old
D3DMetal run silently pins a DXVK launch to the builtins.

**Launch paths behave differently, and it matters:**
- `wyn play <id>` on a dxmt/dxvk profile goes through `steam.exe -applaunch`,
  and **Steam runs the app's own default launch option — not the exe the
  profile resolved.**
- `--direct` runs the resolved exe on the game tree, and needs Steam **logged
  in on that same tree** or a Denuvo title exits instantly (`e06d7363`).
- A graceful Steam shutdown must be driven by the tree that owns the
  wineserver: `WINEPREFIX=<bottle> WINEMSYNC=1 WINEESYNC=1
  <tree>/Wine/bin/wine64 "C:\Program Files (x86)\Steam\steam.exe" -shutdown`.
  Steam sometimes comes back once; check `pgrep -fl wineserver` and repeat.
- Launching a game by hand needs `WINEMSYNC=1 WINEESYNC=1`.

**Vulkan-native titles (id Tech) need none of the D3D layers** and hit a
different wall entirely — see `Documentation/vulkan-titles.md`.

**The GUI app owns `Metadata.plist`.** If Wyn.app is running, it can rewrite a
bottle with defaults (this renamed the Steam bottle to "Bottle" and reset its
layer mid-session). Check `pgrep -f Wyn.app` before hand-editing a bottle, and
re-check the file after.

**`swift test` touches real state.** `GameLibraryInstalledTests` and
`MCPServerTests` read the actual `~/Library/Application Support/com.fly.gaming/
Profiles`, so their failures come and go and both fail on clean `main`. Verify
by stashing before blaming your change.

## Profile status is a claim, not a label

`guessed` → `launched` → `verified`, and the ladder is enforced by tests that
enumerate ids by name (`onlyMeasuredProfilesClaimVerified`,
`onlyDocumentedProfilesClaimLaunched`). `verified` requires §5 of
`Documentation/adding-a-game.md` — a loaded map, frames in the hundreds, a
clean exit, no crash directory — observed on *this* Mac and written into the
notes. Engines that keep no log (REDengine, Ready or Not) cannot reach it; say
that in the notes instead of stretching the bar.

**Do not add guessed catalog entries**, and do not make a catalog claim that
depends on a hand-installed binary — that is what user profiles in
`~/Library/Application Support/com.fly.gaming/Profiles/` are for.

## Notes and commit messages

Profile `notes` are the project's memory and get read by the next session in
place of the logs. Write what was *measured*, with the numbers and the file
names, and say plainly when something is unverified. The same goes for commit
messages: what changed, what the evidence was, and what it does **not** claim.
