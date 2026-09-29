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

Build on the internal SSD. The Wine build runs the assembler once per exported
symbol, tens of thousands of tiny files. On the USB hard disk it stalled with
every `winebuild` blocked on I/O; on the SSD it completes normally.

```bash
# 1. FreeType, GnuTLS, SDL2 (+ their deps) from pinned tarballs; MoltenVK from Khronos
./scripts/build-runtime-deps.sh
# 2. winecx at WINECX_COMMIT plus patches/winecx, against those libraries
#    (WINECX_SEED_REPO: a local checkout holding the commit, to skip the clone
#    on a slow line)
WINECX_DEPS_PREFIX=$PWD/.scratch/runtime-deps/prefix CCACHE_DISABLE=1 \
  WINECX_BUILD_DIR=<dir on the SSD> ./scripts/build-foss-game-host.sh
# 3. assemble Runtime/ from the build and the publishers' pinned releases
./scripts/stage-runtime.sh \
  --wine-root <build>/prefix/wine-root --wine-source <build>/winecx \
  --deps-prefix .scratch/runtime-deps/prefix \
  --dxvk-tarball <dxvk-macOS-async-v1.10.3-20230507.tar.gz> \
  --dxmt-tarball <dxmt-v0.80-builtin.tar.gz> \
  --mono-msi <wine-mono-11.2.0-x86.msi> --gptk-dmg ~/Downloads/Game_Porting_Toolkit_3.0.dmg
# 4. seal it into the app and the image, then measure it
./scripts/package-dmg.sh --with-runtime .scratch/runtime-stage
./scripts/smoke-runtime.sh .scratch/Wyn.dmg
# 5. notarize the image that passed, and cut the source archive for the release
xcrun notarytool submit .scratch/Wyn.dmg --keychain-profile wyn --wait && xcrun stapler staple .scratch/Wyn.dmg
./scripts/package-sources.sh --wine-source <build>/winecx \
  --deps-sources .scratch/runtime-deps/sources --mono-source <wine-mono-11.2.0-src.tar.xz> \
  --dxmt-source <dxmt v0.80 source> --dxvk-source <DXVK-macOS source>
```

All URLs and SHA-256 pins are in `scripts/runtime-pins.env` and
`scripts/runtime-deps.env`.

`build-foss-game-host.sh` applies `patches/winecx/*.patch` in name order to
a clean checkout of the pin and refuses any other change to it. The tree it
installs records the result in `share/wine/wyn-winecx-source.txt`: the pin,
the git tree hash of pin + series, and each patch's SHA-256.

`stage-runtime.sh` refuses:
- a Wine tree without winecx's `CX_APPLEGPTK` hook, or a checkout that is not
  exactly the pinned commit plus `patches/winecx`, or a tree whose
  `wyn-winecx-source.txt` names a different source tree than the checkout
- any library in the tree that `build-runtime-deps.sh` did not build, byte
  for byte
- a tree with absolute symlinks or Apple files already inside it
- any GPTK image, Mono MSI, DXVK or DXMT release other than the pinned one

DXMT's D3D trio gets exactly one change: the 16-byte builtin marker is
rewritten so Wine loads the DLLs as native. `smoke-runtime.sh` installs the
image the way a first launch does, into a throwaway HOME, and checks the
running processes: fonts, HTTPS, D3DMetal (D3D12 and D3D11), `%gs` (the TEB
outside D3DMetal, so `GetCurrentFiber()` works), DXMT, DXVK and SDL.

The build also refuses Wine binaries that weak-import a libSystem symbol newer
than `MACOSX_DEPLOYMENT_TARGET` (15.0): an unguarded call to one jumps to
address 0 on an older macOS. The macOS 27 SDK made configure find `pipe2`,
and builds 1–6 had exactly that in `ntdll.so`; `ac_cv_func_pipe2=no` keeps
Wine on `pipe()` + `FD_CLOEXEC`.

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
