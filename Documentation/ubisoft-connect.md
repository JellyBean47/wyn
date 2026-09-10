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
