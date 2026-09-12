# Verify the next games

Do not add guessed catalog entries. Do not set `"status": "verified"` unless
§5 of [adding-a-game.md](adding-a-game.md) is true on **this** Mac.

Verified today (bundled): `satisfactory`, `solarpunk` (and `solarpunk-dxmt`
as a measured layer variant), `ready-or-not`, `ac-odyssey`, `rv-there-yet`,
`witcher-3`, `wolfenstein-youngblood`, `doom-2016`.
Target **5–10 verified titles**, not 75 — eight of them now exist.

## The bar (copy from adding-a-game.md §5)

From the game’s own log, not a screenshot of a window:

- Loaded map / world (UE: `LogWorld` LoadMap into real content)
- Frame count in the hundreds
- Clean exit (`LogExit: Exiting.` or equivalent)
- Notes say chip, macOS, layer, and what was seen
- `wyn profiles performance <id>` adapter line matches the layer

`save_profile` cannot mark verified. The test
`onlyMeasuredProfilesClaimVerified` lists every bundled verified id; adding
one without measuring fails CI. `onlyDocumentedProfilesClaimLaunched` lists
the launched ids.

Launched (bundled, not the §5 bar): `assetto-corsa`, `ac-odyssey`,
`skyrim-se`, `cities-skylines`, `army-men-rts`. Do not promote those to
verified without a new measurement on this Mac.

## Queue (play what is already installed)

Prefer titles already on disk. This Mac's Windows installs live on
`/Volumes/SSD1TB/SteamLibrary` (Wine Steam already lists that library).
`wyn steam games` is the listing.

Installed catalog titles, verification order:

1. Assassin's Creed Odyssey (`ac-odyssey`) — AnvilNext DX11, `launched`.
   **Start from** [HANDOVER-20260909-ac-odyssey.md](HANDOVER-20260909-ac-odyssey.md).
   The game auths with **Steam and Ubisoft Connect**; `upc.exe` must be
   running on the same wineserver or `ACOdyssey.exe` sits idle with no
   window. 21:35 D3DMetal play attached Connect on GPTK and the Connect
   window painted; Ubisoft then rate-limited (wait ~30 min). Do not
   `--frankea-steam` (DXVK DEVICE_LOST freeze 9 Sep 19:46). Do not mark
   verified without a loaded-world measurement on GPTK D3DMetal.
2. STAR WARS Jedi: Fallen Order (`jedi-fallen-order`) — UE4, `guessed`.
3. Fallout 4 (`fallout-4`) — same DX11 family as launched Skyrim SE.
4. Cyberpunk 2077 (`cyberpunk-2077`) — heavier DX12, same REDengine family as
   verified `witcher-3`. There is no UE log; use the Witcher 3 notes as the
   bar (in-world play + lsof on D3DMetal + per-exe shader cache). Do not
   `--frankea-steam` for this DX12 title.
5. Fallout: New Vegas (`fallout-new-vegas`) — `guessed`, and **measured**
   11 Sep 2026: `lsof` on the live `FalloutNV.exe` shows builtin `d3d9` +
   `wined3d` + `opengl32` from the running tree and nothing from the DXVK
   payload it declares. Same module set alone or straight after another game.
   What is left is a §5 run (loaded map, frames, clean exit) — the render path
   is no longer the question. See
   `wyn-handovers/FINDING-20260911-taskb-legs.md`.
6. Assetto Corsa (`assetto-corsa`) — Magione/Monza loaded, still `launched`.
   Finish the bar or leave it launched.

`witcher-3` ran that day on GPTK D3DMetal from `bin/x64_dx12`, played
in-world and quit from the menu. REDengine keeps no log, so it is verified
on the Ready or Not bar: lsof of D3DMetal.framework on the live process,
`d3d12`/`dxgi` as builtins, a populated per-exe D3DMetal shader cache, and
`dx12user.settings` at 1920x1080 VSync.

`rv-there-yet` was the 11 Sep 2026 run: DXMT, loaded map, 1514 frames, clean
exit, and the first bundled title measured to actually load a translation layer
instead of falling through to wined3d.

Already verified: `satisfactory`, `solarpunk`, `ready-or-not`, `ac-odyssey`,
`rv-there-yet`, `witcher-3`, `wolfenstein-youngblood`, `doom-2016`. Already
launched (do not promote without a new measurement): `skyrim-se`,
`cities-skylines`, `army-men-rts`. Ready or Not shipping did not write
`ReadyOrNot.log`; the verified notes say the layer is the GPTK D3DMetal
launch path.

## Vulkan titles: the MoltenVK feature wall, and the shim that clears it

Full treatment in [vulkan-titles.md](vulkan-titles.md); measured 11 Sep 2026.

id Tech uses no D3D, so no layer setting touches these. MoltenVK refuses the
device because Metal has no `shaderCullDistance` (39th `VkPhysicalDeviceFeatures`
flag) and no `depthBounds` (15th). **`fly-mvkshim`** — an interposer in front of
MoltenVK that reports those features present and strips them from the
device-create request — clears it, in front of stock MoltenVK 1.4.1.

- **Wolfenstein: Youngblood** (1056960) — **verified** with the shim; played by
  a person and it wrote `progression.bin` (23:19). Two fragment pipelines fail
  to compile, probably the price of dropping cull distance; it did not stop
  play. Bundled profile `wolfenstein-youngblood` — notes say the shim is
  required and where it now comes from.
- **DOOM (2016)** (379720) — **verified** 12 Sep 2026. Same shim, plus: launch
  through Steam (`wyn play doom-2016`, no `--direct`) so XAudio2 gets a COM
  apartment, and copy `DOOMx64vk.exe` over `DOOMx64.exe` because `-applaunch`
  runs the OpenGL default. Wrote `DOOMConfig.local` (`r_renderAPI 1`) and
  `profile.bin`. Bundled profile `doom-2016`.

**The shim is shipped, and is Wyn's own source** — `Tools/fly_mvkshim.c`, built
by `scripts/build-mvkshim.sh` and installed into the launching tree by
`WynWineInstaller.ensureVulkanFeatureShim`, called from
`SteamLauncher.launchGame` for any `isVulkanNative` profile. It replaces the
recovered Aug 2026 binary that had no source. These two are therefore ordinary
catalog claims now, not "it played on this Mac with a dylib you must find
yourself": CLAUDE.md forbids a catalog claim that depends on a hand-installed
binary, and until the rewrite both of these were exactly that.

What is still honest to say: the in-game runs above were measured with the
recovered binary, not the rewrite. The rewrite is verified to the same contract
by `Tools/fly_mvkshim_probe.c` (stock 1.4.1 →
`VK_ERROR_FEATURE_NOT_PRESENT`, shim → `VK_SUCCESS`, Apple M4) and produces
byte-identical log lines, but a §5 play-through on it has not been done. Doing
one on either title is the cheapest way to close that gap.

DOOM's extra trap is the opposite of Youngblood: do **not** `--direct` —
Steam's overlay is what creates the COM MTA XAudio2 needs.

While measuring those: `wyn play` on a dxmt/dxvk profile goes through
`steam.exe -applaunch`, and **Steam runs the app's default launch option, not
the exe the profile resolved** — the log said `DOOMx64vk.exe` and `DOOMx64.exe`
started. `--direct` runs the resolved exe, but on DOOM it is the 91% hang
(no COM apartment for XAudio2). Youngblood can `--direct`; DOOM must go
through Steam and the Vulkan exe must sit at `DOOMx64.exe`. That applies to
any title shipping more than one executable.

Skip for Wine: No Man's Sky (native Mac build; profile says DEFER). EVE
Online and LEGO DC Super-Villains have no Windows EXE on this disk.
Borderlands 2 and War Thunder are installed but have no catalog profile —
do not add guessed catalog entries; they show as `steam-<appid>` tiles.

After a measured run: edit
`WynKit/Sources/WynKit/Resources/Profiles/<id>.json`, set `"status":
"verified"`, write notes, extend `onlyMeasuredProfilesClaimVerified` with
that id, then `cd website && npm run deploy` so wyn-dev.com matches.
