# Apple Developer enrollment (signed DMG)

Wyn’s friend-ready download is a **Developer ID** signed, notarized
`Wyn.dmg`. That needs the [Apple Developer Program](https://developer.apple.com/programs/)
($99/year). Ad-hoc signing (`codesign -s -`) is what
[`scripts/build.sh`](../scripts/build.sh) does today; Gatekeeper will warn.

## Enroll

1. Sign in at [developer.apple.com/account](https://developer.apple.com/account)
   with the Apple ID that should own Wyn.
2. Join the Developer Program. Approval can take hours to a few days.
3. In Xcode: Settings → Accounts → Download Manual Profiles.
4. Create a **Developer ID Application** certificate (not Apple Development,
   not Mac App Store). Keep it in the login keychain.

Check whether this Mac can already sign:

```bash
./scripts/check-signing-identity.sh
```

When that prints a `Developer ID Application:` line, packaging can notarize:

```bash
./scripts/package-dmg.sh --notarize
```

Until then, `./scripts/package-dmg.sh` still builds an **ad-hoc** image for
your own machine. Do not publish that file as Wyn 1.0. Do not put it on
wyn-dev.com.

GPTK/D3DMetal stays user-supplied. The DMG must not contain Apple GPTK,
Wine `Libraries/`, or games — same rule as the rest of this repo.
