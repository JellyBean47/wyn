# Contributing

## License

Contributions are accepted under **GPL-3.0-or-later**, the same license as Wyn.
Wine-specific patches under `patches/wine/` should be **LGPL-2.1-or-later** so
they can apply to Wine.

## Do not commit

- Apple GPTK / D3DMetal / `libd3dshared` / `libmetalirconverter`
- Wine `Libraries/` trees, `*.so`, bottle prefixes, `*.tar.gz`
- Store installers (`SteamSetup.exe`, `Battle.net-Setup.exe`, …)
- Game files, logs, credentials, operational `Docs/HANDOVER-*`
- Built helpers under `Tools/bin/`
- Proprietary Wine.app bundles or loaders (the D3DMetal game-host is
  self-built winecx)
- Microsoft fonts / `d3dcompiler_47.dll`
- Windows ISOs, UTM `.utm` guests, Xbox Game Pass packages

Pull requests that add those files will be rejected. Keep
[`DEPENDENCIES.md`](DEPENDENCIES.md) hashes in sync if you change download URLs.

Do not describe Wyn as a clone of another Wine product in user-facing docs
or CLI help. Credit CodeWeavers only for LGPL winecx corresponding source.

## Build

Needs Swift 6 (Xcode 16+). `macos-14` / Swift 5.10 will fail.

```bash
./scripts/check-environment.sh
./scripts/build.sh
```

Do not require `~/Desktop/wyn` or a local `whisky-wine/` tree.

## Code of conduct

Be respectful. This is a compatibility tool: do not contribute exploits against
anti-cheat, account systems, or store DRM.
