# Install from source

## 1. Platform

Apple Silicon, macOS 14+, Xcode Command Line Tools, Rosetta 2. Confirm:

```bash
./scripts/check-environment.sh
```

## 2. Build Wyn

```bash
./scripts/build.sh
```

This builds the `wyn` CLI (`swift build -c release`) and Wyn.app (`xcodebuild`),
then compiles present-helper dylibs into `Tools/bin/` (local only, not git).

## 3. FOSS Wine runtime

```bash
./scripts/setup.sh
```

Downloads frankea `Libraries.tar.gz` **v3.1.1** (see
[DEPENDENCIES.md](../../DEPENDENCIES.md)), verifies SHA-256, rejects Apple GPTK
payloads, and unpacks into
`~/Library/Application Support/com.fly.gaming/Libraries/`.

To use a tarball you already have:

```bash
./.build/release/wyn runtime install --from /path/to/Libraries.tar.gz
```

That path still scans the archive for D3DMetal files.

## 4. Optional D3DMetal

1. Download Game Porting Toolkit from Apple (Apple ID required).
2. Read the included Software License Agreement.
3. `wyn gptk install --from /path/to/redist`  
   The folder must contain `lib/external` or `external` with
   `D3DMetal.framework` and `libd3dshared.dylib`.

Wyn will not download GPTK. Setup does not wire GPTK automatically.

For Wine that can *load* D3DMetal (ntdll `CX_APPLEGPTK_*` hooks):

```bash
wyn runtime install --gptk-aware
```

That is a different hash-pinned tarball (still without Apple blobs). Default
setup stays on frankea Wine (DXMT/DXVK).

## 5. Stores

- **Steam:** `wyn steam install` (official Valve installer).
- **Epic / GOG:** install [Heroic](https://heroicgameslauncher.com), then use
  those tiles. Wyn does not `brew install heroic` unless
  `WYN_ALLOW_BREW_HEROIC=1`.
- **Battle.net / EA:** click Install in Wyn (official vendor download).

Wyn does **not** install or launch Xbox Game Pass, the Xbox app, UTM, or a
Windows VM.

## 6. Disk

Keep several gigabytes free. A full data volume will fail Wine/Heroic extracts.
