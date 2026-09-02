# Install from source

Walked on an Apple Silicon Mac (macOS 14+, Xcode 16 / Swift 6) as a new user.
Wyn is **source only**. It does not ship Wine binaries, Apple GPTK, Steam, or games.

## 1. Platform

Apple Silicon, macOS 14+, **Xcode 16+ (Swift 6)**, Rosetta 2. Several gigabytes
free (Wine extract is ~1 GB; plan **~8 GB** if Steam + RV There Yet? are the
first-game test). Confirm:

```bash
./scripts/check-environment.sh
```

The check fails without `xcodebuild`, even if you only want the CLI. It also
needs `x86_64-w64-mingw32-gcc` so `build.sh` can produce the Steam CEF shim
(`brew install mingw-w64`).

## 2. Build Wyn

```bash
git clone https://github.com/JellyBean47/wyn.git
cd wyn
./scripts/check-environment.sh
./scripts/build.sh
```

`build.sh` produces:

- CLI: `./.build/release/wyn`
- App: `/Applications/Wyn.app` (copied from the Xcode build). Spotlight and
  Launchpad find **Wyn**. A local compile is ad-hoc signed and usually has no
  quarantine, so Gatekeeper does not block it.

`./install.sh` runs check + build + setup + Wine Mono, then copies the CLI to
`~/.local/bin/wyn` (and a `fly` symlink). That single command is the whole
standard install; the sections below are what it does for you.

To also build the D3DMetal game-host, read Apple's Game Porting Toolkit licence
and add both flags:

```bash
./install.sh --with-d3dmetal --accept-gptk-licence
```

That chains the winecx build, `runtime install --gptk-aware`, `gptk install`
and `renderer set d3dmetal`. Both flags are required — `--with-d3dmetal` alone
stops before doing any work and prints the licence URL, so nothing involving
Apple's toolkit happens by accident. It compiles Wine from source, so it is
much slower than the standard install.

The game-host build also needs `ccache` and `mingw-w64`, which the standard
install does not. Those are checked **before** anything is installed, so a
missing package costs you a message rather than a wasted build and a 317 MB
download. Wyn prints the `brew` command and stops; add
`--install-missing-tools` to let it run `brew install` for you.

Consistent with `WYN_ALLOW_BREW_HEROIC`, Wyn never runs `brew` unless asked.
It will not install Homebrew itself either — if `brew` is absent, it points at
<https://brew.sh> and stops.

## Uninstalling

```bash
./scripts/uninstall.sh              # everything, asks first
./scripts/uninstall.sh --dry-run    # show what would go, remove nothing
./scripts/uninstall.sh --keep-bottles
```

Removes `/Applications/Wyn.app`, `~/.local/bin/wyn` (and the `fly` alias), the
Wine runtime under `Application Support`, `~/Library/Caches/wyn`, logs, the
`wyn` / `fly` / `com.wyn.gaming` preference domains, and the bottles under
`Containers`.

Preferences need `killall cfprefsd` as well as deleting the plist — the daemon
holds them in memory and writes them straight back, which is how a "clean"
reinstall ends up reading the previous install's `FlyRuntimeSource`. The script
does this for you.

Never touched: Homebrew packages, `~/Downloads` (including the GPTK image), and
the source checkout. `--clean-build` opts into clearing `.build`, `Tools/bin`
and `.scratch` — note `.scratch` holds the compiled winecx tree, so removing it
means recompiling Wine from source.

Plain bash and no dependency on the Wyn CLI, since the CLI is one of the things
being removed.

## Diagnosing a broken setup

```bash
./scripts/doctor.sh
```

Reports what is installed against what should be, and prints the exact command
to fix each problem. It covers build prerequisites, the Wyn build, the Wine
runtime and which tree it is, D3DMetal/GPTK, renderer wiring, bottles and
Steam's CEF shim.

Written in plain bash with no dependency on the Wyn CLI, because the case it
exists for is a machine where nothing has been built yet. Checks that would
need the CLI are skipped with a reason rather than failing.

It only reports — it never installs or rewires anything, so it is safe to run
at any time and safe to paste into an issue. Exit status is 0 when nothing is
broken and 1 when something is, so CI can use it too.

Distinct from `wyn doctor`, which is a deep per-bottle dump (DLL probes,
launch environment, log tails) for when Wyn is working but a specific game is
not.

## 3. FOSS Wine runtime

```bash
./scripts/setup.sh
```

Downloads frankea `Libraries.tar.gz` **v3.1.1** (see
[DEPENDENCIES.md](../../DEPENDENCIES.md)), verifies SHA-256, refuses Apple GPTK
payloads, and unpacks into
`~/Library/Application Support/com.fly.gaming/Libraries/`.

This is **Wine only**. It does not create a Steam bottle. Cache file:
`~/Library/Caches/wyn/Libraries-v3.1.1.tar.gz`.

To use a tarball you already have:

```bash
./.build/release/wyn runtime install --from /path/to/Libraries.tar.gz
```

That path still scans the archive for D3DMetal files.

One-shot CLI (Wine + Steam bottle, optional installer download):

```bash
./.build/release/wyn install --skip-steam-download
```

## 4. Wine Mono (Terminal / `msiexec /qn`)

Wine's first bottle run can pop a **Wine Mono** installer. That GUI hangs
(stuck at 0% CPU). Do not click it. The first-time path is scripts plus
`wyn steam install`:

```bash
./scripts/install-wine-mono.sh
```

That curls the WineHQ MSI that matches **live** `Libraries/Wine` into
`~/Library/Caches/wyn/` and
`~/Library/Application Support/com.fly.gaming/Libraries/Wine/share/wine/mono/`.
frankea Wine (`./scripts/setup.sh`) wants `wine-mono-10.4.1-x86.msi`. FOSS
winecx wants `wine-mono-11.2.0-x86.msi` (winecx `addons.c`). Replacing
`Libraries/` with the game-host wipes the frankea copy;
`./scripts/install-foss-game-host.sh` stages 11.2.0 again from the cache.

`wyn steam install` then runs `msiexec /qn` into the Steam bottle **before**
SteamSetup, so wineboot never shows the dialog. Do not copy Mono from a
parked Wyn install.

If the dialog already appeared, close only that window (not wineserver)
and:

```bash
./scripts/install-wine-mono.sh --into-bottle
```

Wine Gecko (HTML) is the same class of dialog. If that one hangs, the
same idea applies: put the official MSI under `share/wine/gecko/` from
https://dl.winehq.org/wine/wine-gecko/ instead of clicking Install.

## 5. Open the app

```bash
open /Applications/Wyn.app
# or
./.build/release/wyn --help
```

GPTK/D3DMetal is optional. The first-run sheet should clear once Wine and a
Steam bottle exist. Default graphics are **DXMT** (D3D11 → Metal). D3DMetal is
an opt-in for D3D12-only titles (`wyn renderer set d3dmetal` after
`wyn gptk install`).

## 6. Steam + first game (RV There Yet?)

Wyn never downloads a Steam title. Steam does.

`wyn steam install` stages Wine Mono with `msiexec /qn` (section 4), then
runs SteamSetup **unattended** (`/S`). It does not leave the wizard's
"Run Steam" checkbox as the first client — that HWND is black (no CEF
args, no steamwebhelper shim). Wyn waits for `bin/cef/cef.win*` if needed,
shims every variant, and opens Steam the same way `wyn steam launch` does.

```bash
./.build/release/wyn steam install     # msiexec /qn, silent SteamSetup, then login window
./.build/release/wyn steam launch      # log in, check Remember me
```

On FOSS Wine the client uses frankea / DXVK (no D3DMetal). In Steam, install
**RV There Yet?** (app **3949040**, ~3.2 GB). Then either click the tile in
Wyn.app or:

```bash
./.build/release/wyn play rv-there-yet
```

`wyn play` looks for `ride.exe` / `ride-win64-shipping.exe` after Steam has
written `appmanifest_3949040.acf`. The profile lists `vcrun2019`; Wyn does
**not** run winetricks automatically.

## 7. Optional D3DMetal (FOSS winecx game-host)

Default setup stays on frankea Wine (DXMT/DXVK). D3DMetal needs a **different
Wine tree**: self-built FOSS winecx, not Whisky 11 with GPTK bolted on. Wyn
does not download Wine for `--gptk-aware`. Full path:
[game-host.md](game-host.md).

1. Build winecx (mingw-w64 gcc, x86_64 unix half, Nix x86_64-darwin libs):

   ```bash
   ./scripts/build-foss-game-host.sh
   ```

2. Copy or link the prefix into `~/Library/Application Support/com.fly.gaming/Libraries/`:

   ```bash
   wyn runtime install --gptk-aware --directory /path/to/wine-root
   # or
   ./scripts/install-foss-game-host.sh --directory /path/to/wine-root
   ```

   `--gptk-aware` does **not** download a tarball. It refuses proprietary
   Wine.app / wineloader layouts and Whisky 11 without ntdll
   `CX_APPLEGPTK_LIBD3DSHARED_PATH` (winecx’s GPTK hook).
3. Apple GPTK 3.0 is separate (user DMG). Read the SLA, then:

   ```bash
   wyn gptk install
   # or: wyn gptk install --from /path/to/redist
   wyn renderer set d3dmetal   # only if you want D3DMetal; default stays DXMT
   ```

   Put Apple’s `Game_Porting_Toolkit_3.0.dmg` in `~/Downloads`. Wyn mounts it
   (including the nested Evaluation redist) and copies `D3DMetal.framework` +
   `libd3dshared.dylib`. GPTK install does **not** select D3DMetal.
   `wyn renderer set d3dmetal` repoints unix `d3d11.so` as a **symlink** to
   `libd3dshared`. Wyn never downloads GPTK.

   DXMT is D3D11 → Metal (Satisfactory already uses `-dx11`). D3D12-only
   titles still need GPTK. D3DMetal is an opt-in upgrade, not a replacement.

Steam UI for 3.0 lives on the game-host wineserver. Isolation AppDefaults for
`steam.exe` / `steamwebhelper` are `=b`. frankea (`Libraries.steam`) is DXMT /
window rollback only. `wyn steam launch` and the Steam tile already use the
game-host when this FOSS identity is present. D3DMetal play does not fall back
to frankea DXVK.

## 8. Other stores

- **Epic / GOG:** install [Heroic](https://heroicgameslauncher.com), then use
  those tiles. Wyn does not `brew install heroic` unless
  `WYN_ALLOW_BREW_HEROIC=1`.
- **Battle.net / EA:** click Install in Wyn (official vendor download).

Wyn does **not** install or launch Xbox Game Pass, the Xbox app, UTM, or a
Windows VM.

## 9. On disk

- Wine: `~/Library/Application Support/com.fly.gaming/Libraries/`
- Bottles: `~/Library/Containers/com.fly.gaming/Bottles/`
- Logs: `~/Library/Logs/com.fly.gaming/`

The bundle id is `com.wyn.gaming`; on-disk folders stay `com.fly.gaming`.
