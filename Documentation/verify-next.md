# Verify the next games

Do not add guessed catalog entries. Do not set `"status": "verified"` unless
§5 of [adding-a-game.md](adding-a-game.md) is true on **this** Mac.

Verified today (bundled): `satisfactory`, `solarpunk` (and `solarpunk-dxmt`
as a measured layer variant), `ready-or-not`. Target **5–10 verified titles**,
not 75.

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
4. Cyberpunk 2077 (`cyberpunk-2077`) / Witcher 3 (`witcher-3`) — heavier DX12.
5. Fallout: New Vegas (`fallout-new-vegas`) — `guessed`; old path was wined3d.
6. Assetto Corsa (`assetto-corsa`) — Magione/Monza loaded, still `launched`.
   Finish the bar or leave it launched.

Already verified: `satisfactory`, `solarpunk`, `ready-or-not`. Already
launched (do not promote without a new measurement): `ac-odyssey`,
`skyrim-se`, `cities-skylines`, `army-men-rts`. Ready or Not shipping did
not write `ReadyOrNot.log`; the verified notes say the layer is the GPTK
D3DMetal launch path.

Skip for Wine: No Man's Sky (native Mac build; profile says DEFER). EVE
Online and LEGO DC Super-Villains have no Windows EXE on this disk.
Borderlands 2 and War Thunder are installed but have no catalog profile —
do not add guessed catalog entries; they show as `steam-<appid>` tiles.

After a measured run: edit
`WynKit/Sources/WynKit/Resources/Profiles/<id>.json`, set `"status":
"verified"`, write notes, extend `onlyMeasuredProfilesClaimVerified` with
that id, then `cd website && npm run deploy` so wyn-dev.com matches.
