# Ubisoft Connect rendering

Build Wyn using `scripts/build.sh` as described in the project README. The build
compiles and packages the present helpers from `Tools/`; Connect does not require
a developer's `.scratch` directory, saved HTTP cache, or a hardcoded Wine username.
With Ubisoft Connect installed in the Steam bottle, open its platform tile in Wyn.

Connect uses software CEF rendering, parent-native shared memory, and the Cocoa
login bridge. The FLY4 fast presentation route is specific to EA's window and must
remain disabled for Connect. Keep both bridge outputs enabled: the shared-memory
path presents native surfaces, and the BGRA file supplies the Cocoa fallback.

Startup allows up to 120 seconds for StartView and a fresh, complete FLY2 frame.
A StartView log entry alone can accompany a transparent window. Old log entries
and frames from a previous launch do not satisfy the readiness check. When joining
an existing Wine session, Wyn also waits for a frame without stopping that session.
Connect maintains its own CEF cache; Wyn no longer deletes it or restores a local
snapshot over it at every launch.

Verified on 9 September 2026 with Ubisoft Connect 173.1.13333 and the installed
Wine 11.0 runtime: the login screen rendered repeatedly, including after the CEF
cache was regenerated without an old snapshot. The software-rendering launch
produced its first login frame after approximately 35 seconds. This verification
covers launcher rendering; it does not establish compatibility for Ubisoft games.

Regression checks: `swift test --package-path WynKit --filter ConnectLauncherTests`.
