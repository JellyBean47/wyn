# Correction — 29/30 September 2026: the block page is DataDome; what got past it

"Access is temporarily restricted" is DataDome, Ubisoft's bot filter.
Connect's own browser history records the page as
`geo.captcha-delivery.com/captcha/…&t=bv`. `t=bv` is DataDome's hard block,
not a puzzle. It answers the login request that Connect's sign-in form sends
(`connect.cdn.ubisoft.com/overlay/default/`, which loads `dd.ubisoft.com/tags.js`).

Measured on build 9, in a brand-new bottle with a new browser profile and a new
device ID:
- The very first login was blocked (21:46).
- Three later logins were blocked too (22:02, 23:09, 23:56).

So parking the browser cache (below, 17 Sep) is not what recovered the 15 Sep
sign-in. `wyn connect signin --fresh-browser-cache` no longer claims it is.

What Wyn changed:
- **CEF flags.** Game-host Connect no longer pins `--use-angle`, and it keeps
  Wine's builtin d3d11/dxgi. DataDome's tag reads the WebGL renderer in a Web
  Worker; Connect disables WebGL on the page's main thread itself.
  - `=swiftshader-webgl` (build 9 and earlier) never gave SwiftShader. The
    worker reported `ANGLE (Apple, … Apple M4 …, MoltenVK)`, a Windows PC with
    an Apple GPU.
  - With no pin, ANGLE falls back to D3D9Ex over wined3d and reports
    `ANGLE (NVIDIA, NVIDIA GeForce 8800 GTX Direct3D9Ex …)`, Wine's standard
    card.
  - **30 Sep 09:46, the first sign-in since 15 Sep.** Fresh CEF profile (old
    one renamed), this renderer, `TZ=Africa/Johannesburg` for that one launch,
    and a phone hotspot. DataDome showed only its device check (interstitial),
    which passed by itself. Every failure had shown `t=bv` straight away.
  - **30 Sep 18:04, the same profile resumed its session on home Wi-Fi with
    no `TZ` override**: `AccountStartupUser` 18 s after start, the token
    refreshed, and no DataDome page at all in the history. Neither the
    hotspot nor the time zone is needed to stay signed in. Whether a fresh
    password login passes without them is untested.
  - DXVK beside upc.exe (tried 29 Sep) still reports "Apple M4", so Wyn now
    removes it if it finds it there.
  - Never pin `--use-angle=d3d11`: on the builtin d3d11, CEF retries GPU
    startup forever.
- **A flagged cookie follows the profile.** Every blocked attempt leaves a
  `datadome` cookie in Connect's CEF profile, and DataDome recognises it on
  any network. All retests before 30 Sep reused that profile, so they tested
  nothing.
- **Detection.** Launches and `wyn connect signin` read Connect's browser
  history (a private copy, kinds and times only). A hard block ends the wait
  with `connectBlockedByUbisoft`, not "sign-in could not be confirmed". The
  cold-start retry loop stops on it instead of relaunching Connect.
- **Reporting.** `wyn connect status` and the diagnostics bundle (`connect.txt`,
  `connect-logs/`) show the last bot-check results.

With DXVK WebGL and (by hand) the correct time zone, the 23:09 and 23:56
logins were still hard-blocked, but they reused the flagged profile, so they
say nothing about the flags. (iCloud Private Relay is not offered in South
Africa, so it played no part in any test.) See
`~/wyn-handovers/FINDING-20260929-connect-datadome.md`.

Also found: every bottle reports its time zone as the first registry zone with
matching rules (Kaliningrad for Africa/Johannesburg). Wine only maps
`/etc/localtime` to an IANA name under `/usr/share/zoneinfo`, and macOS's link
resolves under `/private/var/db/timezone/`. Setting `TZ` fixes the name but
breaks msvcrt/UCRT local time (Connect's own log went one hour wrong). The fix
belongs in winecx.

# Correction — 15 September 2026: rendering is not authentication

The shared Windows-user profile prevents profile divergence; it cannot prevent
session expiry or a web sign-in block. On 14 September the shared link was intact,
Connect recorded no account startup, and CEF history contained CAPTCHA visits.
The exact cause of the token change and browser rejection remains unproven.

Game callers now explicitly request authenticated startup. Both Wine paths and
already-running Connect require an `AccountStartupUser.cpp` account line from the
latest startup. Existing clients additionally require the line's timestamp to be
within the live process lifetime; missing or ambiguous process metadata fails
closed. This is startup evidence, not a server-side token validation API: it cannot
prove that a session has not subsequently expired without a new startup log.

The visible Connect tile still opens a painted sign-in window without requiring
an account or announcing successful sign-in. Game-host Connect cannot provide the
same painted window; unconfirmed authentication explains how to reopen the tile
after quitting Connect and Steam normally. Authentication timeouts leave Connect open, report
“sign-in could not be confirmed”, and do not enter the six-attempt restart loop.
Game launches retain the 30-second settling period, including existing clients
that may have just signed in, and recheck the current process afterward. No token size is used as an authentication signal.

This change does not clear cookies, restore tokens, modify browser flags, or claim
to fix Ubisoft's web challenge. Live sign-in and Odyssey play remain unverified.
The patch is isolated on `codex/connect-auth-readiness`; revert its single fix
commit with `git revert <commit>` to undo the code, tests, and documentation.
There is no bottle migration or credential change to undo.

Validation on 15 September: all 13 Connect tests passed. The full WynKit run
passed 376 of 377 tests; `catalogProfilesMatchCanonicalSlugs` fails on the live
Satisfactory variant profiles, and the same assertion fails on unchanged main.
Those profiles were left intact. Release CLI and universal macOS app builds
succeeded. No live Connect sign-in or game launch was attempted.

# Ubisoft Connect rendering

Build Wyn using `scripts/build.sh` as described in the project README. The build
compiles and packages the present helpers from `Tools/`; Connect does not require
a developer's `.scratch` directory, saved HTTP cache, or a hardcoded Wine username.
With Ubisoft Connect installed in the Steam bottle, open its platform tile in Wyn.

Connect uses CEF `--in-process-gpu` plus SwiftShader (`--use-angle=swiftshader-webgl`)
and the FLY4 present path from `Tools/present-fast-run.sh`: every window-targeted
StretchBlt is replayed into a shared surface, and the parent presents dirty
rectangles. Do not pass `--disable-gpu` — that leaves a transparent HWND because
ANGLE fails MoltenVK (`VK_KHR_win32_surface`) and FLY4 never sees a blit. The
Cocoa `.bgra` login bridge is a fallback; it drops partial updates (for example
942×633), so typing and caret motion stay stale until a fuller repaint.

`FLY_COCOA_FAST` applies FLY4 pixels to windows titled `EA`. That is not the
Connect path.

Startup allows up to 120 seconds for StartView **and** a non-blank FLY4 surface
with a window handle. A StartView log entry alone can accompany a transparent
window. Old log entries from a previous launch do not satisfy the readiness
check. When joining an existing Wine session, Wyn waits for that frame without
stopping the session (`wineserver -k` is only for a cold Connect-only bottle).
Connect maintains its own CEF cache; Wyn does not delete it or restore a local
snapshot over it at every launch.

Verified on 9 September 2026 with Ubisoft Connect 173.1.13333 and Wine 11.0
(`Libraries.steam` → `Libraries.dxmt-wine11.0`). FLY4 with `--in-process-gpu`
presents dirty rects without a window switch; typing, caret blink, and scrolling
were confirmed on that path. `--disable-gpu` was a regression: StartView logged
but FAST blit/s stayed 0 and the HWND stayed transparent.

Regression checks: `swift test --package-path WynKit --filter ConnectLauncherTests`.

# Connect readiness and recovery — 17 September 2026

Three failures were measured on this project, and Wyn now treats them as three
different things instead of "the window looks fine".

**1. Signed out / web sign-in blocked.** 14 Sep: Connect discarded its saved
sign-in, and Ubisoft's bot check (DataDome) refused the sign-in page inside
Connect's CEF. Recovered by hand on 15 Sep by renaming the CEF profile
(`…/Ubisoft Game Launcher/cache/http2`) and signing in on a tree that paints a
window. That recovery is now a command:

    wyn connect status              # running / signed in / ownership / store
    wyn connect signin              # open Connect and wait for the account line
    wyn connect signin --fresh-browser-cache

`--fresh-browser-cache` **renames** the CEF profile to `http2.parked-<stamp>` and
lets Connect build a new one. Nothing is deleted, and saved credentials are never
read or written. Restore by renaming the parked directory back to `http2`.

**2. Signed in, ownership refused.** Measured 9 Sep 19:32 and 15 Sep 21:42, both
within five minutes of a signed-in Connect being killed: `AccountStartupUser`
appears, then `Ownership connection is not set up` and a `dolphin-028` recovery
page. A game launched into that client cannot be authorised.
`ConnectLauncher.ownershipStatus` reads the newest session and a game launch now
fails with `connectOwnershipUnavailable`, which says to wait about five minutes.
`Ownership connection lost` after play (10 Sep 18:47, 23 minutes in) is a network
drop and is explicitly not treated as a startup failure.

**3. Sign-in confirmation on non-US Macs.** `ps -o lstart` is locale-formatted;
an en_ZA Mac prints `Tue 15 Sep …`, not `Tue Sep 15 …`. The readiness check found
no process start date and refused every launch with "sign-in could not be
confirmed" while Connect was signed in (15 Sep 23:35). `ps` now runs with
`LC_ALL=C`, and the parser accepts day-first output as well.

What this does not do: it does not defeat Ubisoft's bot check, validate a token
server-side, or prove a session is still valid without a fresh startup line.
