# Shipping the runtime inside Wyn.app (1.1): licensing

Checked 27 Sep 2026 by reading the licence texts themselves: Apple's
`License.rtf` from the Game Porting Toolkit 3.0 and 4.0 beta 2 images, and
the licence files of every other component the runtime carries. This is
an engineering record of what the texts say and what Wyn does about each
one. It is not legal advice.

## Verdict

**Wyn may ship Wine, D3DMetal, DXMT, DXVK, MoltenVK and Wine Mono inside
one notarized Wyn.app**, on these conditions:

- Wyn stays non-commercial (Apple's condition for D3DMetal).
- Apple's files are shipped unmodified, together with Apple's notices.
- Every LGPL binary is shipped with its exact corresponding source,
  published from the same place as the download.

Two things are **not yet** release-ready and are listed at the end. Both
are build and provenance work; neither is a licensing blocker.

## Component by component

| Component | Licence | Ship it? | What Wyn owes |
| --- | --- | --- | --- |
| Wyn | GPL-3.0-or-later | yes | Source offer next to the download (already in place: `SOURCE_URL` beside `DOWNLOAD_URL`) |
| Apple GPTK 3.0 evaluation environment: `D3DMetal.framework`, `libd3dshared.dylib`, the PE shims | Apple SLA EA18380 | **yes, non-commercially** | Unmodified; framework whole; `License.rtf` + `Acknowledgements.rtf` travel with it; never sold, paywalled or ad-supported (details below) |
| Wine: winecx (CodeWeavers' CrossOver 26.3 Wine changes on WineHQ 11.15) | LGPL-2.1-or-later | yes | The exact corresponding source, from where the DMG is served; `COPYING.LIB`, `AUTHORS`, `NOTICES.md` in the app; never call it CrossOver |
| DXMT 0.80 | MIT | yes | Notice. DXMT 1.0 and later are LGPL-2.1+, so moving past 0.80 adds a source obligation |
| DXVK-macOS 1.10.3 | zlib | yes | Notice (requested, not required, for binaries) |
| MoltenVK | Apache-2.0 | yes | Licence text |
| Wine Mono 11.2.0 | Mono parts LGPL or MIT X11; SharpZipLib GPL with exception; FNA MS-PL; FAudio/SDL zlib; the rest MIT (its `COPYING`, read 27 Sep 2026) | yes | Notices, plus the corresponding source: WineHQ's `wine-mono-11.2.0` source tarball, mirrored with the rest. The MSI is WineHQ's, byte for byte |
| GnuTLS, Nettle, GMP, libtasn1, libunistring, libidn2, libiconv, gettext `libintl` | LGPL (2.1+ or 3+) | yes | Exact source for each, same as Wine |
| FreeType, libpng, zlib, bzip2, brotli, zstd, lz4, xz, ICU, libxml2, libxslt, libffi, SDL2, libinotify, p11-kit, libpcap | permissive | yes | Notices (FreeType's FTL asks for a credit line in the documentation) |
| MacPorts `legacy-support` (pulled in by the MacPorts GnuTLS) | mixed, unverified | **remove** | Rebuilding GnuTLS for macOS 14+ drops it |

**Never in the image:** Microsoft redistributables and fonts
(`d3dcompiler_47`, corefonts, VC++ runtimes), Steam and other store
clients, GPL or non-free codecs (x264, x265, fdk-aac), and libdvdcss.

## Apple's licence, clause by clause

The text is identical in GPTK 3.0 and 4.0 beta 2 (EA18380, dated
8/17/2023).

- **§2A(iii)** grants the right to "distribute the Apple Software solely
  for non-commercial purposes and in accordance with this Agreement,
  including Section 2C."
- **§2C**: components "may not be separated from the Apple Software for
  distribution. Notwithstanding the foregoing, the Framework in its
  entirety or any part of the Redistributables may be distributed
  separately", and all of it "subject to the non-commercial restriction".
  Redistributables are the image's `/redist`; Wyn ships the whole
  evaluation volume, so nothing is separated at all.
- **§2A** (copies): every copy must reproduce Apple's notices. The app
  carries `GPTK/License.rtf` and `Acknowledgements.rtf`, and the disk
  image repeats them in `Legal/runtime/`.
- **§2C**: Apple hardware only, and no renting, leasing, lending, hosting
  or selling. Wyn is a macOS app, so this is met, and it rules out ever
  offering Wyn as a hosted service.
- **§2D**: no modification or reverse engineering. So Wyn never re-signs
  Apple's code. `sign-runtime.sh`, `stage-runtime.sh` and
  `package-dmg.sh` each fail if D3DMetal stops verifying against
  `anchor apple`.
- **§9**: US export rules apply to the Apple Software.
- Apple's own Read Me says that "free and commercial products incorporate
  the supplemental evaluation layers from this distribution within a
  pre-built WINE environment", and names Gcenx's Homebrew casks and
  CrossOver. That is exactly the shape of a Wyn 1.1 release.

**What non-commercial means for Wyn in practice:**

- a free download
- no paid tier, no ads, no sale
- no paid support tied to the download

`.github/FUNDING.yml` is fully commented out and `SUPPORT_PAGE_ENABLED` is
false. Keep it that way while the image carries D3DMetal. The licence
does not define the term, and a donation button beside the download is
the grey edge of it.

**Residual risk:** the use grant (§2A(i)) is framed around developing,
testing and evaluating games, and Apple can end the licence with notice
(§5). If Apple ever objects, Wyn stops shipping D3DMetal in the image.
The user-supplied path (`wyn gptk install`) already exists and keeps
working.

**Not 4.0 beta 2.** Its licence text is byte-identical, but it is
pre-release software from the developer portal, and pre-release software
stays out of a release. `runtime-pins.env` pins the 3.0 image by
SHA-256, and `stage-runtime.sh` refuses anything else.

## GPL-3 next to a proprietary library

Wyn's own code never links D3DMetal. Wine, a separate program under the
LGPL, loads it, and the LGPL permits loading non-free libraries.
Wyn.app holding both is an aggregate under GPL-3 §5 ("separate and
independent works … on a volume of a storage or distribution medium"),
which does not extend the GPL to D3DMetal. Apple's own original GPTK
combined D3DMetal with LGPL Wine in exactly this way.

## Signing and notarization (measured)

- D3DMetal and `libd3dshared.dylib` are signed by Apple ("Software
  Signing", no team ID, no hardened-runtime flag). They stay as they are.
- Wine's executables are signed with the Developer ID, hardened runtime,
  a secure timestamp and `WynApp/WineRuntime.entitlements`. Its
  libraries get the same signature without entitlements.
- Under that signature, on this Mac, 27 Sep 2026:
  - `wine cmd /c ver` created a fresh prefix.
  - A D3D12 probe (`CreateDXGIFactory1` + `D3D12CreateDevice`) got
    "AMD Compatibility Mode" 0x1002/0x66af and `S_OK`.
  - `lsof` showed `D3DMetal`, `libd3dshared.dylib`,
    `libmetalirconverter.dylib` and `default.metallib` loaded from the
    tree.
  - This held both on the staged tree and on the copy that
    `wyn runtime install --bundled` installed from the disk image.

## Before a public 1.1 release

1. **Rebuild the runtime from pinned source on a clean builder.** The
   prototype image uses a winecx build from 30 Aug at the pinned commit
   `c2cce0e`. Its companion libraries are Gcenx/MacPorts binaries whose
   exact source Wyn cannot reproduce.
2. **Build the LGPL companion libraries from pinned upstream tarballs.**
   That drops MacPorts `legacy-support` too. These then become the
   corresponding-source asset, published next to `Wyn.dmg` with a
   pointer to it in `Legal/`:
   - the library tarballs
   - the winecx commit
   - WineHQ's `wine-mono-11.2.0` source
   - the build scripts
3. **Do not redistribute frankea's `winecx-gptk` runtime 4.6.4 as it
   is.** It bundles x264 and x265 (GPL), fdk-aac (GPL-incompatible) and
   libdvdcss, and ships no licence files. If Wyn wants a media stack,
   build an LGPL-only one.
4. **Update the copy** that says D3DMetal is not in the download: the
   NOTICE GPTK paragraph and the site's download and game pages, at
   release time.
