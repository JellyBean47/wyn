# Packaging Wyn.dmg

See [apple-developer.md](apple-developer.md) for the certificate.

```bash
./scripts/check-signing-identity.sh
./scripts/package-dmg.sh              # this Mac only (ad-hoc)
./scripts/package-dmg.sh --notarize   # friends; needs Developer ID + notary profile
```

Packaging never installs anything: it builds with `WYN_NO_INSTALL=1` and packs
the build product, so the Wyn.app in `/Applications` is left alone.

## 1.1+: the image carries its runtime

```bash
./scripts/stage-runtime.sh \
  --wine-root <winecx wine-root> --wine-source <winecx checkout> \
  --dxvk <DXVK x32/x64> --dxmt <DXMT x32/x64/LICENSE> --winemetal <winemetal.so> \
  --mono-msi <wine-mono-11.2.0-x86.msi> --gptk-dmg ~/Downloads/Game_Porting_Toolkit_3.0.dmg
./scripts/package-dmg.sh --with-runtime .scratch/runtime-stage --notarize
```

`stage-runtime.sh` refuses:
- a Wine tree without winecx's `CX_APPLEGPTK` hook
- a tree with absolute symlinks or Apple files already inside it
- a GPTK image other than the pinned 3.0 one (by SHA-256)
- a Mono MSI other than the pinned one

It copies Apple's evaluation environment into `GPTK/` byte for byte, and
fails if D3DMetal stops verifying as Apple-signed.

`package-dmg.sh --with-runtime` puts it in
`Wyn.app/Contents/SharedSupport/Runtime` and hands it to `sign-runtime.sh`:
- Developer ID, hardened runtime and a timestamp on every Mach-O
- `WynApp/WineRuntime.entitlements` on the Wine executables only
- Apple's GPTK is never re-signed

The image is LZMA-compressed (ULMO). A 1 GB runtime becomes a ~290 MB image.

On first launch, setup installs `Runtime/` into Application Support instead of
downloading. `BundledRuntime.install` copies it (a clone on APFS), wires
D3DMetal in through the same `GPTKInstaller` a user's DMG goes through, and
clears the quarantine flag on the copies. It never replaces an installed
runtime unless asked: `wyn runtime install --bundled --replace`.

**What a public 1.1 release owes, beyond the image:**
- the exact corresponding source for every LGPL binary in `Runtime/`, published
  as a release asset next to `Wyn.dmg`
- Wyn staying non-commercial, because Apple's grant for D3DMetal is
  non-commercial only

Both are spelled out in
[`../bundled-runtime-licensing.md`](../bundled-runtime-licensing.md).

## 1.0: the image without a runtime

The image is **Wyn.app, an Applications symlink, and `Legal/`**. It does not
contain Wine binaries, GPTK, or games. First launch uses the in-app setup sheet
to download the hash-pinned Wine runtime. A title whose profile names
`d3dmetal` does not run from this image. It needs the source install (the
winecx game-host is compiled by `build-foss-game-host.sh`) and the user's own
GPTK.

`Wyn.app/Contents/Resources/wyn` is the CLI, put there by `build.sh` and
installed to `~/.local/bin` by **Install Command Line Tool…** in the app's Help
menu. Without it, a DMG install has no `wyn` at all.

Setup refuses to start without Rosetta 2 (`WynInstaller.setup`), because Wine's
unix half is x86_64 and `check-environment.sh` never runs on this path.

`Legal/` carries `LICENSE`, `NOTICE`, `COPYRIGHT`, `THIRD_PARTY_LICENSES.md`
and `licenses/`; the same files are copied into
`Wyn.app/Contents/Resources/` before signing, so the notices survive someone
keeping only the app (GPL-3 §4). Packaging signs the Mach-O helpers in
`Contents/Resources/` individually before sealing the bundle — signing the
bundle alone leaves them ad-hoc, and notarization rejects that.

Distributing the DMG obliges you to offer the corresponding source from the
same place (GPL-3 §6(d)). `website/lib/html.mjs` holds `DOWNLOAD_URL` beside
`SOURCE_URL` for that reason, and a test refuses a page that prints one without
the other.

Create a notary keychain profile once (App Store Connect API key):

```bash
xcrun notarytool store-credentials wyn \
  --apple-id YOUR_APPLE_ID \
  --team-id YOUR_TEAM_ID \
  --password APP_SPECIFIC_PASSWORD
```

Output: `.scratch/Wyn.dmg` (gitignored). Never commit it. Never upload an
ad-hoc DMG to wyn-dev.com.
