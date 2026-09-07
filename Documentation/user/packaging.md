# Packaging Wyn.dmg

See [apple-developer.md](apple-developer.md) for the certificate.

```bash
./scripts/check-signing-identity.sh
./scripts/package-dmg.sh              # this Mac only (ad-hoc)
./scripts/package-dmg.sh --notarize   # friends; needs Developer ID + notary profile
```

The image is **Wyn.app plus an Applications symlink**. It does not contain Wine
binaries, GPTK, or games. First launch uses the in-app setup sheet to download
the hash-pinned Wine runtime.

Create a notary keychain profile once (App Store Connect API key):

```bash
xcrun notarytool store-credentials wyn \
  --apple-id YOUR_APPLE_ID \
  --team-id YOUR_TEAM_ID \
  --password APP_SPECIFIC_PASSWORD
```

Output: `.scratch/Wyn.dmg` (gitignored). Never commit it. Never upload an
ad-hoc DMG to wyn-dev.com.
