# Verify the next games

Do not add guessed catalog entries. Do not set `"status": "verified"` unless
§5 of [adding-a-game.md](adding-a-game.md) is true on **this** Mac.

Verified today (bundled): `satisfactory`, `solarpunk` (and `solarpunk-dxmt`
as a measured layer variant). Target **5–10 verified titles**, not 75.

## The bar (copy from adding-a-game.md §5)

From the game’s own log, not a screenshot of a window:

- Loaded map / world (UE: `LogWorld` LoadMap into real content)
- Frame count in the hundreds
- Clean exit (`LogExit: Exiting.` or equivalent)
- Notes say chip, macOS, layer, and what was seen
- `wyn profiles performance <id>` adapter line matches the layer

`save_profile` cannot mark verified. The test
`onlyMeasuredProfilesClaimVerified` lists every bundled verified id; adding
one without measuring fails CI.

## Queue (play what is already installed)

Prefer titles already on disk. Suggested order if they are in Steam:

1. Assetto Corsa (`assetto-corsa`) — long notes, still `guessed`. Finish the
   bar or leave it guessed.
2. Any other installed catalog slug you can reach a loaded map on.

After a measured run: edit
`WynKit/Sources/WynKit/Resources/Profiles/<id>.json`, set `"status":
"verified"`, write notes, extend `onlyMeasuredProfilesClaimVerified` with
that id, then `cd website && npm run deploy` so wyn-dev.com matches.
