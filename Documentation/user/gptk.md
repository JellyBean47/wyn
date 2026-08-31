# Apple GPTK / D3DMetal (optional)

Wyn’s default graphics path is **DXMT** (MIT v0.80 in frankea Wine) and
**DXVK-macOS**. D3DMetal is optional and needs **self-built FOSS winecx**
as the game-host — not Whisky with GPTK overlaid. See [game-host.md](game-host.md).

## What Wyn will not do

- Put GPTK files in git or GitHub Releases
- Download GPTK from Apple or from unofficial mirrors
- Reverse-engineer D3DMetal
- Treat GPTK as required for a source build

## What you may do

If you already obtained Game Porting Toolkit from Apple for your own
evaluation/development use, you may point Wyn at that local redist:

```bash
wyn gptk install
wyn gptk status
wyn renderer status
wyn renderer set d3dmetal   # opt-in; install does not select D3DMetal
```

Default: `~/Downloads/Game_Porting_Toolkit_3.0.dmg` (or another Game Porting
Toolkit 3.x DMG / extracted folder there). `--from` is only needed for a
redist somewhere else. Wyn does not search `~/Desktop/wyn/whisky-wine` and
never downloads GPTK.

Install FOSS winecx first (`./scripts/build-foss-game-host.sh`, then
`wyn runtime install --gptk-aware --directory …`).
`wyn gptk install` copies Apple D3DMetal 3.0 onto that tree so it is
**selectable**; it is not a Wine installer. It mounts the Apple DMG
(including the nested Evaluation redist), refuses D3DMetal 2.x, and does
**not** repoint `d3d11.so`. The default renderer stays **DXMT**
(D3D11 → Metal). D3D12-only titles still need GPTK:

```bash
wyn renderer set d3dmetal
```

Switch back without reinstalling:

```bash
wyn renderer set dxmt
```

## Terms

The GPTK Software License Agreement is a **personal**, limited license for
installing and testing in connection with developing, testing, or evaluating
video games on Apple-branded hardware. Distribution of Redistributables is
limited to **non-commercial** use. Reverse engineering and modification of
Apple Software are prohibited except as the agreement allows for included
open-source pieces.

Whether using D3DMetal as a general end-user game launcher fits section 2.A
is **not settled here**. That is not legal advice; read the SLA that shipped
with your toolkit (and consider counsel before shipping a product that depends
on D3DMetal). Wyn has no commercial D3DMetal license.

Official download:
https://developer.apple.com/download/all/?q=game%20porting%20toolkit
