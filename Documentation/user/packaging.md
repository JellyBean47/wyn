# Packaging Wyn.dmg

See [apple-developer.md](apple-developer.md) for the certificate.

```bash
./scripts/check-signing-identity.sh
./scripts/package-dmg.sh              # this Mac only (ad-hoc)
./scripts/package-dmg.sh --notarize   # friends; needs Developer ID + notary profile
```

The image is **Wyn.app, an Applications symlink, and `Legal/`**. It does not
contain Wine binaries, GPTK, or games. First launch uses the in-app setup sheet
to download the hash-pinned Wine runtime.

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
