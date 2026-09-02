//
//  SteamLauncher.swift
//  WynKit
//

import Foundation

/// A game Steam reports as installed in a Wine bottle (`appmanifest_*.acf`).
public struct SteamInstalledApp: Sendable, Hashable {
    public let appId: Int
    public let name: String
    public let installDirectory: URL
}

public enum SteamLauncher {
    public static let setupDownloadURL = URL(
        string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe"
    )!

    public static let defaultBottleName = "Steam"

    /// Windows path to steam.exe inside a bottle (default Steam install location).
    public static func steamExePath(in bottle: Bottle) -> URL {
        bottle.url
            .appending(path: "drive_c")
            .appending(path: "Program Files (x86)")
            .appending(path: "Steam")
            .appending(path: "steam.exe")
    }

    public static func isSteamInstalled(in bottle: Bottle) -> Bool {
        FileManager.default.fileExists(atPath: steamExePath(in: bottle).path(percentEncoded: false))
    }

    /// Typical folder for a Steam library game install.
    public static func gameInstallDirectory(in bottle: Bottle, folderName: String) -> URL {
        bottle.url
            .appending(path: "drive_c")
            .appending(path: "Program Files (x86)")
            .appending(path: "Steam")
            .appending(path: "steamapps")
            .appending(path: "common")
            .appending(path: folderName)
    }

    /// All `steamapps` roots known to Wine Steam (default C: library + extras from libraryfolders.vdf).
    /// External drives show up as e.g. `Z:\Volumes\SSD1TB\SteamLibrary` when `z:` → `/`.
    public static func steamappsRoots(in bottle: Bottle) -> [URL] {
        let steamRoot = bottle.url
            .appending(path: "drive_c")
            .appending(path: "Program Files (x86)")
            .appending(path: "Steam")
        let defaultApps = steamRoot.appending(path: "steamapps")

        var roots: [URL] = []
        var seen = Set<String>()

        func appendRoot(_ url: URL) {
            let path = url.standardizedFileURL.path(percentEncoded: false)
            guard !seen.contains(path) else { return }
            guard FileManager.default.fileExists(atPath: path) else { return }
            seen.insert(path)
            roots.append(url)
        }

        appendRoot(defaultApps)

        let vdfs = [
            defaultApps.appending(path: "libraryfolders.vdf"),
            steamRoot.appending(path: "config").appending(path: "libraryfolders.vdf"),
        ]
        for vdf in vdfs {
            guard let contents = try? String(contentsOf: vdf, encoding: .utf8) else { continue }
            for winPath in parseManifestValues(named: "path", in: contents) {
                guard let libraryRoot = unixURL(forWindowsPath: winPath, in: bottle) else { continue }
                appendRoot(libraryRoot.appending(path: "steamapps"))
            }
        }

        return roots
    }

    /// Steamworks redistributables and similar non-game app IDs.
    private static let ignoredAppIDs: Set<Int> = [
        228980, // Steamworks Common Redistributables
    ]

    /// Installed Steam apps across every library folder, one tile per install directory.
    /// When several manifests share a folder (DLC), the lowest app ID is kept (usually the base game).
    public static func installedApps(in bottle: Bottle) -> [SteamInstalledApp] {
        let fm = FileManager.default
        var byInstallDir: [String: SteamInstalledApp] = [:]

        for steamApps in steamappsRoots(in: bottle) {
            let listing = (try? fm.contentsOfDirectory(
                at: steamApps,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []

            for url in listing {
                guard url.pathExtension.lowercased() == "acf" else { continue }
                let file = url.lastPathComponent
                guard file.hasPrefix("appmanifest_"), file.hasSuffix(".acf") else { continue }
                let idPart = file.dropFirst("appmanifest_".count).dropLast(".acf".count)
                guard let appId = Int(idPart), !ignoredAppIDs.contains(appId) else { continue }

                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                guard let installdir = parseManifestValue(named: "installdir", in: text),
                      !installdir.isEmpty
                else { continue }

                let path = steamApps.appending(path: "common").appending(path: installdir)
                guard fm.fileExists(atPath: path.path(percentEncoded: false)) else { continue }
                guard hasWindowsGameExecutable(in: path) else { continue }

                let name = parseManifestValue(named: "name", in: text) ?? installdir
                let app = SteamInstalledApp(appId: appId, name: name, installDirectory: path)
                let key = path.standardizedFileURL.path(percentEncoded: false)
                if let existing = byInstallDir[key] {
                    if app.appId < existing.appId {
                        byInstallDir[key] = app
                    }
                } else {
                    byInstallDir[key] = app
                }
            }
        }

        return byInstallDir.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Resolve a game's install folder from `appmanifest_<id>.acf` across all Steam libraries.
    public static func installDirectory(forAppId appId: Int, in bottle: Bottle) -> URL? {
        for steamApps in steamappsRoots(in: bottle) {
            let manifest = steamApps.appending(path: "appmanifest_\(appId).acf")
            guard let contents = try? String(contentsOf: manifest, encoding: .utf8) else { continue }
            guard let installdir = parseManifestValue(named: "installdir", in: contents) else { continue }
            let path = steamApps.appending(path: "common").appending(path: installdir)
            guard FileManager.default.fileExists(atPath: path.path(percentEncoded: false)) else { continue }
            return path
        }
        return nil
    }

    /// Find the first matching game executable under a Steam app install.
    public static func findGameExecutable(forAppId appId: Int, in bottle: Bottle, profile: GameProfile) -> URL? {
        let searchRoots: [URL]
        if let installDir = installDirectory(forAppId: appId, in: bottle) {
            searchRoots = [installDir]
        } else {
            searchRoots = []
        }

        for root in searchRoots {
            if let match = findExecutable(matching: profile, under: root) {
                return match
            }
        }
        return nil
    }

    public static func downloadInstaller() async throws -> URL {
        let (tempURL, response) = try await URLSession.shared.download(from: setupDownloadURL)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SteamError.downloadFailed
        }

        let dest = FileManager.default.temporaryDirectory
            .appending(path: "Wyn-SteamSetup-\(UUID().uuidString).exe")
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }

    /// Unattended SteamSetup (`/S`). Does not leave SteamSetup's "Run Steam" as
    /// the first client — that path has no CEF args and no steamwebhelper shim,
    /// so the HWND is black. Wine Mono is `msiexec /qn` first so wineboot never
    /// shows the hung GUI installer. Caller then starts Steam via `launchSteam`.
    public static func runSteamInstaller(in bottle: Bottle, installer: URL) async throws {
        try await WineMono.preparePrefix(bottle)
        Wine.allowMacWindows()
        print("Installing Steam (unattended)…")
        _ = try await Wine.runWine(
            [installer.path(percentEncoded: false), "/S"],
            bottle: bottle
        )

        guard isSteamInstalled(in: bottle) else {
            throw SteamError.steamSetupFailed
        }

        // NSIS `/S` still often Exec's steam.exe from .onInstSuccess — unshimmed.
        if await waitBrieflyForSteamClient(in: bottle, seconds: 8) {
            print("SteamSetup started the client; stopping it so Wyn can launch with CEF flags…")
            await waitUntilSteamClientReadyForShutdown(in: bottle, seconds: 30)
            try await requestSteamShutdownUntilExit(in: bottle)
        }
    }

    /// Default game EXE names for Steam AppDefaults isolation when no profile is in scope.
    private static let defaultD3DMetalGameExeNames: [String] = [
        "factorygamesteam.exe",
        "factorygame.exe",
        "factorygamesteam-win64-shipping.exe",
        "factorygame-win64-shipping.exe"
    ]

    /// D3DMetal game EXEs that need AppDefaults so Steam Play (`CreateProcess`) loads GPTK builtins.
    /// Includes bundled D3DMetal profiles, not just Satisfactory — Play can start any of them.
    public static func d3dMetalGameExeNames(extra: [String] = []) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        func append(_ raw: String) {
            let name = (raw as NSString).lastPathComponent
            guard name.lowercased().hasSuffix(".exe") else { return }
            let key = name.lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key)
            names.append(name)
        }
        extra.forEach(append)
        defaultD3DMetalGameExeNames.forEach(append)
        for profile in ProfileStore.loadAll() where profile.id != "steam" {
            guard profile.bottle?.translationLayer == .d3dMetal else { continue }
            profile.exePatterns.forEach(append)
        }
        return names
    }

    /// Environment Steam Play children inherit.
    ///
    /// winecx's `bin/wine` deletes `WINEDLLOVERRIDES` and drives graphics via
    /// `CX_GRAPHICS_BACKEND` (winecx env). Wyn has no per-exe compat DB, so the Steam
    /// process itself must carry GPTK (`CX_APPLEGPTK_LIBD3DSHARED_PATH`) and D3DMetal
    /// `d3d*=b`. `steam.json` used to export `dxgi,d3d11,d3d10core=n,b` (DXMT native-first)
    /// and `ProfileApplicator.apply` set the bottle to DXMT — every green Play button then
    /// spawned the game without Wyn's wrapper, which is why `wyn play` was required.
    private static func gameHostSteamEnvironment(program: Program) -> [String: String] {
        var environment = program.generateEnvironment()
        environment.merge(GPTKInstaller.launchEnvironment(), uniquingKeysWith: { _, new in new })
        let d3dMetal = TranslationLayer.d3dMetal.environmentOverrides(
            dxvkHud: program.bottle.settings.dxvkHud,
            dxvkAsync: program.bottle.settings.dxvkAsync
        )
        environment.merge(d3dMetal, uniquingKeysWith: { _, new in new })
        // Overlay must be *disabled* (`=d`), not native (`=n`). Steam Play children inherit
        // this env; `=n` lets Valve's overlay hook DXGI vtables inside D3DMetal. Frankea play
        // already used `=d`. 32-bit overlay stays `=d`.
        let cefSafe = "winemenubuilder.exe=d;gameoverlayrenderer64=d;gameoverlayrenderer=d"
        if let existing = environment["WINEDLLOVERRIDES"], !existing.isEmpty {
            environment["WINEDLLOVERRIDES"] = "\(cefSafe);\(existing)"
        } else {
            environment["WINEDLLOVERRIDES"] = cefSafe
        }
        // Match D3DMetal game profiles so Play children get MetalFX without a second `wyn play`.
        if environment["D3DM_ENABLE_METALFX"] == nil {
            environment["D3DM_ENABLE_METALFX"] = "1"
        }
        forwardCEFFlags(into: &environment)
        return environment
    }

    private static func forwardCEFFlags(into environment: inout [String: String]) {
        let hostEnv = ProcessInfo.processInfo.environment
        for key in ["WYN_CEF_FLAGS", "FLY_CEF_FLAGS", "AETHER_CEF_FLAGS"] {
            if let value = hostEnv[key], !value.isEmpty {
                environment[key] = value
            }
        }
    }

    /// Pin the bottle on D3DMetal and write per-exe AppDefaults. Do **not** apply `steam.json`
    /// (`translationLayer: dxmt`) — that is what made Play inherit DXMT.
    private static func prepareGameHostSteam(
        in bottle: Bottle,
        gameExeNames: [String],
        debug: Bool
    ) throws {
        bottle.settings.translationLayer = .d3dMetal
        bottle.settings.dxvk = false
        try Wine.applyD3DMetalSteamIsolation(
            bottle: bottle,
            gameExeNames: d3dMetalGameExeNames(extra: gameExeNames),
            debug: debug
        )
    }

    /// Launch the Steam client with Wyn's Steam compatibility profile applied.
    /// Default: game-host `Libraries/` (FOSS winecx + D3DMetal).
    /// Rollback: `preferFrankeaSteam` / `--frankea-steam` → `Libraries.steam`.
    public static func launchSteam(
        in bottle: Bottle,
        options: Wine.LaunchOptions = Wine.LaunchOptions(),
        gameExeNames: [String] = []
    ) async throws {
        let plan = try makeSteamLaunchPlan(
            in: bottle, options: options, gameExeNames: gameExeNames
        )
        if plan.useGameHost {
            try await ensureGameHostCEFReady(plan: plan, bottle: bottle)
            _ = try await SteamCEFShim.installUntilSteamsVariantIsShimmed(
                into: bottle, debug: plan.options.debug
            )
            if !plan.options.debug {
                print("Steam UI: game-host Wine (Libraries/ — FOSS winecx + D3DMetal).")
                print("Press Play in Steam — games inherit this D3DMetal wrapper. wyn play is fallback.")
            }
        }

        // Never start a second steam.exe. A leftover `-silent` bootstrap cannot
        // show a window — shut it down (retried) and fall through to a visible
        // launch. A windowed client is adopted as-is.
        if isSteamClientRunning(in: bottle) {
            if isSilentSteamClientRunning(in: bottle) {
                print("Steam is running in the background (-silent); asking it to exit so the window can show…")
                await waitUntilSteamClientReadyForShutdown(in: bottle, seconds: 60)
                try await requestSteamShutdownUntilExit(in: bottle, options: plan.options)
            } else {
                print("Steam is already running.")
                return
            }
        } else if anySteamClientRunning() {
            throw SteamError.steamAlreadyRunningElsewhere
        }

        Wine.allowMacWindows()
        var launchArgs = plan.args
        // Stub SteamSetup has no SteamUI.dll. `-noverifyfiles` makes the updater
        // skip the first client download → "Failed to load steamui.dll".
        if !steamUILooksReady(in: bottle) {
            launchArgs = launchArgs.filter { $0.lowercased() != "-noverifyfiles" }
        }
        let baseline = connectionLogFingerprint(in: bottle)
        try await Wine.runProgram(
            at: plan.steamURL,
            args: launchArgs,
            bottle: bottle,
            environment: plan.environment,
            options: plan.options
        )
        if plan.options.detachAfterStart {
            await waitUntilLoggedOnThenReturn(in: bottle, baseline: baseline)
        }
    }

    /// Overlay callers detach so they do not wait for Steam to quit. Stay up until
    /// a **fresh** Logged On (Remember me), the user Exits, or a short timeout.
    /// Never throws and never starts Steam again after Exit.
    private static func waitUntilLoggedOnThenReturn(
        in bottle: Bottle,
        baseline: ConnectionLogFingerprint,
        seconds: TimeInterval = 90
    ) async {
        var sawClient = false
        progress("Waiting for Steam Logged On…")
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if Task.isCancelled { return }
            let running = isSteamClientRunning(in: bottle)
            if running { sawClient = true }
            if running, isSteamLoggedOn(in: bottle, baseline: baseline) {
                progress("Steam Logged On.")
                return
            }
            if sawClient, !running {
                progress("Steam exited.")
                return
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    private struct SteamLaunchPlan {
        let steamURL: URL
        let args: [String]
        let environment: [String: String]
        var options: Wine.LaunchOptions
        let useGameHost: Bool
    }

    private static func makeSteamLaunchPlan(
        in bottle: Bottle,
        options: Wine.LaunchOptions,
        gameExeNames: [String]
    ) throws -> SteamLaunchPlan {
        let steamURL = steamExePath(in: bottle)
        guard FileManager.default.fileExists(atPath: steamURL.path(percentEncoded: false)) else {
            throw SteamError.steamNotInstalled
        }

        let profile = ProfileStore.profile(id: "steam")
        let program = Program(url: steamURL, bottle: bottle)
        let args = ProfileApplicator.launchArguments(profile: profile, program: program)
        var steamOptions = options
        let environment: [String: String]

        // Game host only when Wine can load D3DMetal. Fresh FOSS setup
        // (frankea DXMT/DXVK) has no CX_APPLEGPTK hooks — stay on frankea.
        let useGameHost = !options.preferFrankeaSteam && GPTKInstaller.isWineGPTKAware()
        if useGameHost {
            guard WynWineInstaller.isWynWineInstalled() else {
                throw SteamError.steamWineMissing
            }
            try prepareGameHostSteam(
                in: bottle,
                gameExeNames: gameExeNames,
                debug: options.debug
            )
            environment = gameHostSteamEnvironment(program: program)
            steamOptions.wineTree = .game
            steamOptions.preferGPTKSteam = true
            steamOptions.translationLayerOverride = .d3dMetal
            if options.debug {
                print("[wyn:debug] Steam UI → game-host Wine tree (\(WynWineInstaller.libraryFolder.path))")
                print("[wyn:debug] Play inherits WINEDLLOVERRIDES=\(environment["WINEDLLOVERRIDES"] ?? "(none)")")
            }
        } else {
            if let profile {
                ProfileApplicator.apply(profile: profile, to: bottle)
            }
            _ = try WynWineInstaller.ensureSteamWineTree()
            guard WynWineInstaller.isSteamWineInstalled() else {
                throw SteamError.steamWineMissing
            }
            // Frankea Wine: drop Wine-11 local PEs + CEF shim left by GPTK isolation.
            try Wine.prepareFrankeaSteamClient(bottle: bottle, debug: options.debug)
            var frankeaEnv = ProfileApplicator.launchEnvironment(profile: profile, program: program)
            forwardCEFFlags(into: &frankeaEnv)
            environment = frankeaEnv
            steamOptions.wineTree = .steam
            if options.debug {
                print("[wyn:debug] Steam UI → frankea Wine tree (\(WynWineInstaller.steamLibraryFolder.path))")
            } else {
                print("Steam UI: frankea Wine (Libraries.steam rollback).")
            }
        }

        return SteamLaunchPlan(
            steamURL: steamURL,
            args: args,
            environment: environment,
            options: steamOptions,
            useGameHost: useGameHost
        )
    }

    /// The disk is right and the process is wrong.
    ///
    /// Shimming a variant does nothing to a `steamwebhelper` that is *already*
    /// running out of it — only a restart repaints the login window. Two states
    /// need one: a `-silent` bootstrap client, which can never show a window at
    /// all, and a client whose live helper was launched before the shim reached
    /// its variant. The second is the black login window users work around by
    /// hand — stop Steam, launch it again. Do it for them.
    private static func restartSteamIfItsWindowCannotPaint(
        plan: SteamLaunchPlan,
        bottle: Bottle
    ) async throws {
        let staleHelper = SteamCEFShim.lastWebHelperLaunch(in: bottle).map { launch in
            !launch.shimmed && SteamCEFShim.shimmedVariants(in: bottle).contains(launch.variant)
        } ?? false

        if staleHelper {
            print("Steam's login window is running an unshimmed CEF helper; restarting Steam so it paints…")
        } else if isSilentSteamClientRunning(in: bottle) {
            print("Steam is running in the background (-silent); asking it to exit so the window can show…")
        } else {
            return
        }
        await waitUntilSteamClientReadyForShutdown(in: bottle, seconds: 60)
        try await requestSteamShutdownUntilExit(in: bottle, options: plan.options)
    }

    /// First install often has no `bin/cef/cef.win*` yet — it appears after Steam's
    /// win32→win64 self-update. Start Steam with the same CEF args as a normal
    /// launch **plus `-silent`**, wait until the client is actually up (not merely
    /// until the helper file appears), shim the variant Steam itself loads, then
    /// `-shutdown` (retried) so the visible login window is a shimmed process.
    ///
    /// `-silent` is the fix that prevents an unshimmed black first HWND on the
    /// `wyn steam launch` path. Never `wineserver -k`.
    private static func ensureGameHostCEFReady(plan: SteamLaunchPlan, bottle: Bottle) async throws {
        // A running client: wait/shim if needed, shut down `-silent` leftovers,
        // adopt a windowed client. Never start a second steam.exe here.
        if isSteamClientRunning(in: bottle) {
            if SteamCEFShim.hasAnyHelper(in: bottle) {
                _ = try await SteamCEFShim.installUntilSteamsVariantIsShimmed(
                    into: bottle, debug: plan.options.debug
                )
                try await restartSteamIfItsWindowCannotPaint(plan: plan, bottle: bottle)
                return
            }
            if steamUILooksReady(in: bottle) {
                print("Steam is preparing the login window (first run)…")
                let appeared = try await SteamCEFShim.waitUntilHelperExists(
                    in: bottle, seconds: 180, debug: plan.options.debug
                )
                guard appeared else { throw SteamError.cefDidNotAppear }
                _ = try await SteamCEFShim.installUntilSteamsVariantIsShimmed(
                    into: bottle, debug: plan.options.debug
                )
                try await restartSteamIfItsWindowCannotPaint(plan: plan, bottle: bottle)
                return
            }
            print("Steam stub cannot load steamui.dll yet; asking it to exit so the first download can run…")
            try await requestSteamShutdownUntilExit(in: bottle, options: plan.options)
        }

        if SteamCEFShim.hasAnyHelper(in: bottle) {
            _ = try await SteamCEFShim.installUntilSteamsVariantIsShimmed(
                into: bottle, debug: plan.options.debug
            )
            return
        }

        guard SteamCEFShim.bundledShimURL != nil else {
            throw SteamCEFShimError.shimBinaryMissing
        }

        print("Steam is preparing the login window (first run)…")
        var bootstrap = plan.options
        bootstrap.detachAfterStart = true
        var bootstrapArgs = plan.args
        // SteamSetup only unpacks a stub. `-noverifyfiles` then skips the first
        // client download and Steam dies with "Failed to load steamui.dll".
        if !steamUILooksReady(in: bottle) {
            print("Downloading the Steam client (file verify left on until SteamUI.dll exists)…")
            bootstrapArgs = bootstrapArgs.filter { $0.lowercased() != "-noverifyfiles" }
        }
        if !bootstrapArgs.contains(where: { $0.lowercased() == "-silent" }) {
            bootstrapArgs.append("-silent")
        }
        Wine.allowMacWindows()
        _ = try await Wine.runProgram(
            at: plan.steamURL,
            args: bootstrapArgs,
            bottle: bottle,
            environment: plan.environment,
            options: bootstrap
        )

        let appeared = try await SteamCEFShim.waitUntilHelperExists(
            in: bottle, seconds: 180, debug: plan.options.debug
        )
        guard appeared else {
            throw SteamError.cefDidNotAppear
        }
        _ = try await SteamCEFShim.installUntilSteamsVariantIsShimmed(
                into: bottle, debug: plan.options.debug
            )
        await waitUntilSteamClientReadyForShutdown(in: bottle, seconds: 60)
        try await requestSteamShutdownUntilExit(in: bottle, options: plan.options)
    }

    /// Ask Steam to exit once. Never `wineserver -k`.
    /// Prefer `requestSteamShutdownUntilExit` — a single `-shutdown` is often
    /// ignored during Steam's win32→win64 self-update.
    public static func requestSteamShutdown(
        in bottle: Bottle,
        options: Wine.LaunchOptions = Wine.LaunchOptions()
    ) async throws {
        let steamURL = steamExePath(in: bottle)
        guard FileManager.default.fileExists(atPath: steamURL.path(percentEncoded: false)) else {
            return
        }
        var shutdownOptions = options
        shutdownOptions.detachAfterStart = false
        shutdownOptions.useWineBuiltinD3D = true
        _ = try await Wine.runProgram(
            at: steamURL,
            args: ["-shutdown"],
            bottle: bottle,
            environment: [:],
            options: shutdownOptions
        )
    }

    /// Quit Steam the way Steam's own Exit menu item does: `steam.exe
    /// -shutdown`, retried with backoff.
    ///
    /// Deliberately never `wineserver -k`. That kills every process in the
    /// prefix — the running game included — and skips the D3DMetal exit
    /// bookkeeping, which is what the 120 s GPU settle depends on. Callers that
    /// want to stop a game ask the player to quit it from its own window;
    /// `runningGameNames(among:)` tells them whether to ask.
    ///
    /// Returns `true` when Steam is gone (including when it was not running).
    @discardableResult
    public static func quitSteam(
        in bottle: Bottle,
        options: Wine.LaunchOptions = Wine.LaunchOptions()
    ) async throws -> Bool {
        guard isSteamInstalled(in: bottle) else { return true }
        guard isSteamClientRunning(in: bottle) else { return true }
        try await requestSteamShutdownUntilExit(in: bottle, options: options)
        return !isSteamClientRunning(in: bottle)
    }

    /// Display names of the given profiles whose game EXE is running right now.
    ///
    /// Detection only — nothing is signalled or killed. Steam, steamwebhelper
    /// and wineserver rows are excluded by `leftoverSessionCommands`, so a
    /// running Steam client on its own is not reported as a game.
    public static func runningGameNames(among profiles: [GameProfile]) -> [String] {
        var nameForExe: [String: String] = [:]
        for profile in profiles {
            for pattern in profile.exePatterns {
                // windowsExeBasename lowercases; exePatterns are authored that
                // way too, but do not rely on the author for a match.
                nameForExe[pattern.lowercased()] = profile.name
            }
        }
        guard !nameForExe.isEmpty else { return [] }

        var running: Set<String> = []
        for command in leftoverSessionCommands(matching: Set(nameForExe.keys)) {
            guard let base = windowsExeBasename(fromCommand: command),
                  let name = nameForExe[base] else { continue }
            running.insert(name)
        }
        return running.sorted()
    }

    /// `-shutdown` two or three times with backoff. Steam ignores the first
    /// request when the helper file has just appeared mid self-update.
    private static func requestSteamShutdownUntilExit(
        in bottle: Bottle,
        options: Wine.LaunchOptions = Wine.LaunchOptions(),
        attempts: Int = 3
    ) async throws {
        guard isSteamClientRunning(in: bottle) else { return }
        let pauses: [UInt64] = [0, 2_000_000_000, 5_000_000_000]
        let waits: [TimeInterval] = [15, 20, 45]
        let n = min(max(attempts, 1), pauses.count)
        for i in 0..<n {
            if !isSteamClientRunning(in: bottle) { return }
            if i > 0 {
                print("Steam ignored -shutdown; retrying (\(i + 1)/\(n))…")
                try await Task.sleep(nanoseconds: pauses[i])
            } else {
                print("Asking Steam to exit…")
            }
            try await requestSteamShutdown(in: bottle, options: options)
            if await steamClientDidExit(in: bottle, seconds: waits[i]) {
                return
            }
        }
        print("Steam did not exit after -shutdown. Use Steam → Exit, then: wyn steam launch")
        throw SteamError.steamDidNotExit
    }

    /// Helper-on-disk is not "client fully up". Wait until `steam.exe` has
    /// stayed running, preferably with SteamUI.dll or a CEF helper present.
    private static func waitUntilSteamClientReadyForShutdown(
        in bottle: Bottle,
        seconds: TimeInterval
    ) async {
        let deadline = Date().addingTimeInterval(seconds)
        var stableSince: Date?
        while Date() < deadline {
            if isSteamClientRunning(in: bottle) {
                if stableSince == nil { stableSince = Date() }
                let waited = Date().timeIntervalSince(stableSince!)
                let fullyUp = steamUILooksReady(in: bottle) || SteamCEFShim.hasAnyHelper(in: bottle)
                if fullyUp && waited >= 5 { return }
                if waited >= 15 { return }
            } else {
                stableSince = nil
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private static func steamUILooksReady(in bottle: Bottle) -> Bool {
        let url = steamExePath(in: bottle)
            .deletingLastPathComponent()
            .appending(path: "SteamUI.dll")
        let path = url.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber
        else { return false }
        return size.int64Value > 100_000
    }

    private static func waitBrieflyForSteamClient(in bottle: Bottle, seconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if isSteamClientRunning(in: bottle) { return true }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        return false
    }

    private static func steamClientDidExit(in bottle: Bottle, seconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !isSteamClientRunning(in: bottle) { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    /// Write `steam_appid.txt` so Steamworks can initialize when the game exe is started
    /// outside a full Steam session (direct Wine launch / some UE bootstrap paths).
    @discardableResult
    public static func ensureSteamAppIdFile(appId: Int, inDirectory directory: URL) throws -> URL {
        let file = directory.appending(path: "steam_appid.txt")
        let contents = "\(appId)\n"
        if let existing = try? String(contentsOf: file, encoding: .utf8),
           existing.trimmingCharacters(in: .whitespacesAndNewlines) == "\(appId)" {
            return file
        }
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// Convenience: write `steam_appid.txt` next to the game EXE.
    @discardableResult
    public static func ensureSteamAppIdFile(appId: Int, nextToExecutable exe: URL) throws -> URL {
        try ensureSteamAppIdFile(appId: appId, inDirectory: exe.deletingLastPathComponent())
    }

    /// Place `steam_appid.txt` next to the game exe and at the Steam install root.
    public static func ensureSteamAppIdFiles(appId: Int, executable: URL, installDirectory: URL?) throws {
        try ensureSteamAppIdFile(appId: appId, inDirectory: executable.deletingLastPathComponent())
        if let installDirectory {
            try ensureSteamAppIdFile(appId: appId, inDirectory: installDirectory)
        }
    }

    /// Launch a Steam-distributed game with its compatibility profile applied.
    ///
    /// **D3DMetal (Option A / Apple model):** run the game EXE under GPTK-aware Wine
    /// with a **co-resident frankea Steam client** (same bottle / wineserver).
    /// `steam_appid.txt` alone is not enough for titles that use Steam→EOS identity
    /// (e.g. Satisfactory): SteamAPI must initialize against a live Steam session.
    /// Log in once via `wyn steam launch`, Remember me — leave Steam running for play,
    /// or `wyn play` will start it silently.
    ///
    /// **DXMT / DXVK:** default is `steam.exe -applaunch` (frankea Steam Wine).
    /// Pass `direct: true` to skip Steam for those layers (many titles then exit).
    @discardableResult
    public static func launchGame(
        profile: GameProfile,
        in bottle: Bottle,
        direct: Bool = false,
        options: Wine.LaunchOptions = Wine.LaunchOptions()
    ) async throws -> URL {
        guard let appId = profile.steamAppId else {
            throw SteamError.missingSteamAppId(profileId: profile.id)
        }
        guard isSteamInstalled(in: bottle) else {
            throw SteamError.steamNotInstalled
        }

        try await waitOutPreviousD3DMetalSession(profile: profile, bottle: bottle)

        var options = options
        if profile.needsUbisoftConnectPlay {
            try await prepareUbisoftConnectThenFrankeaSteam(in: bottle, options: &options)
        }

        // Unprofiled Steam library titles: ask Steam to launch, do not guess an EXE.
        if profile.exePatterns.isEmpty {
            try await launchGameViaSteam(
                appId: appId,
                profile: profile,
                bottle: bottle,
                options: options
            )
            return steamExePath(in: bottle)
        }

        guard let exe = findGameExecutable(forAppId: appId, in: bottle, profile: profile) else {
            throw SteamError.gameNotInstalled(appId: appId)
        }

        ProfileApplicator.apply(profile: profile, to: bottle)
        try ensureSteamAppIdFiles(
            appId: appId,
            executable: exe,
            installDirectory: installDirectory(forAppId: appId, in: bottle)
        )

        let gameArgs = ProfileApplicator.launchArguments(
            profile: profile,
            program: Program(url: exe, bottle: bottle)
        )

        let layer = profile.bottle?.translationLayer
            ?? bottle.settings.translationLayer

        // Steam relaunches often drop CLI `-dx11`; pin D3D11 in Unreal Saved config.
        if UnrealCompatibility.wantsDX11(launchArgs: gameArgs) {
            let projectName = profile.unrealProject
                ?? installDirectory(forAppId: appId, in: bottle)?.lastPathComponent
            if let projectName {
                let pinned = (try? UnrealCompatibility.pinDX11(
                    in: bottle, projectName: projectName
                )) ?? []
                if options.debug, !pinned.isEmpty {
                    for url in pinned {
                        print("[wyn:debug] Pinned DX11 in \(url.path(percentEncoded: false))")
                    }
                }
                // Translated GPUs cannot sustain Epic UE5 defaults — force Low + 40 FPS.
                if layer == .dxvk || layer == .d3dMetal || layer == .dxmt {
                    let scaled = (try? UnrealCompatibility.pinLowScalability(
                        in: bottle, projectName: projectName
                    )) ?? []
                    if options.debug, !scaled.isEmpty {
                        for url in scaled {
                            print("[wyn:debug] Pinned low scalability in \(url.path(percentEncoded: false))")
                        }
                    }
                    let hitch = (try? UnrealCompatibility.pinHitchLogging(
                        in: bottle, projectName: projectName
                    )) ?? []
                    if options.debug, !hitch.isEmpty {
                        for url in hitch {
                            print("[wyn:debug] Pinned hitch logging in \(url.path(percentEncoded: false))")
                        }
                    }
                }
            }
        }

        // Apple D3DMetal model: always direct GPTK EXE (never frankea -applaunch).
        if layer == .d3dMetal {
            try await launchGameDirectD3DMetal(
                appId: appId,
                executable: exe,
                profile: profile,
                bottle: bottle,
                gameArgs: gameArgs,
                options: options
            )
            return exe
        }

        if direct {
            let program = Program(url: exe, bottle: bottle)
            var environment = ProfileApplicator.launchEnvironment(profile: profile, program: program)
            environment["SteamAppId"] = "\(appId)"
            environment["SteamGameId"] = "\(appId)"
            if layer == .dxmt {
                // Undo leftover GPTK AppDefaults (d3d*=b) from prior D3DMetal sessions.
                let gameDXMT: [String: String] = [
                    "d3d11": "n",
                    "dxgi": "n",
                    "d3d10core": "n",
                    "d3d12": "d",
                    "atidxx64": "d"
                ]
                for raw in profile.exePatterns {
                    let name = (raw as NSString).lastPathComponent
                    guard name.lowercased().hasSuffix(".exe") else { continue }
                    try Wine.setAppDllOverrides(bottle: bottle, exeName: name, overrides: gameDXMT)
                }
            }
            var directOptions = options
            directOptions.wineTree = .game
            try await Wine.runProgram(
                at: exe, args: gameArgs, bottle: bottle, environment: environment, options: directOptions
            )
            return exe
        }

        try await launchGameViaSteam(
            appId: appId,
            profile: profile,
            bottle: bottle,
            gameArgs: gameArgs,
            options: options
        )
        return exe
    }

    /// Run a short process and capture stdout without pipe deadlock.
    /// (`waitUntilExit` before reading fills the pipe on large `ps axeww` → hang.)
    private static func captureProcessOutput(executable: String, arguments: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return ""
        }
        // Read to EOF first (EOF arrives when the child exits); then reap.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Bottle path forms Wine may put in `WINEPREFIX=` (raw + symlink-resolved).
    private static func bottlePrefixCandidates(for bottle: Bottle) -> [String] {
        Array(Set([
            bottle.url.path(percentEncoded: false),
            bottle.url.path,
            bottle.url.resolvingSymlinksInPath().path(percentEncoded: false),
            bottle.url.resolvingSymlinksInPath().path
        ].filter { !$0.isEmpty }))
    }

    /// True when `line` has `WINEPREFIX=<prefix>` as a full env assignment (not a longer path).
    private static func lineHasWinePrefix(_ line: String, prefix: String) -> Bool {
        let needle = "WINEPREFIX=\(prefix)"
        guard let range = line.range(of: needle) else { return false }
        if range.upperBound == line.endIndex { return true }
        let next = line[range.upperBound]
        return next == " " || next == "\t"
    }

    private static func lineMatchesAnyBottlePrefix(_ line: String, prefixes: [String]) -> Bool {
        prefixes.contains { lineHasWinePrefix(line, prefix: $0) }
    }

    /// Wine PE `steam.exe` (not steamwebhelper lines that only mention steampath=…steam.exe).
    static func lineIsSteamClientExe(_ line: String) -> Bool {
        let lower = line.lowercased()
        if lower.contains("steamwebhelper") { return false }
        if lower.contains("steampath=") { return false }
        // Typical Wine PE: `C:\Program Files (x86)\Steam\steam.exe …`
        if lower.contains("\\steam\\steam.exe") || lower.contains("/steam/steam.exe") {
            return true
        }
        // Fallback: command token is steam.exe
        return lower.range(of: #"(^|[\\/ ])steam\.exe([\s]|$)"#, options: .regularExpression) != nil
    }

    /// Whether a wineserver process owns this bottle (`WINEPREFIX` on that PID only).
    public static func isBottleWineserverRunning(in bottle: Bottle, snapshot: String? = nil) -> Bool {
        let prefixes = bottlePrefixCandidates(for: bottle)
        // Prefer targeted probe — never dump every process environ (pipe deadlock + slow).
        if snapshot == nil {
            let pidsText = captureProcessOutput(
                executable: "/usr/bin/pgrep",
                arguments: ["-x", "wineserver"]
            )
            let pids = pidsText.split(whereSeparator: \.isNewline).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            for pid in pids {
                let envLine = captureProcessOutput(
                    executable: "/bin/ps",
                    arguments: ["eww", "-p", "\(pid)"]
                )
                if lineMatchesAnyBottlePrefix(envLine, prefixes: prefixes) {
                    return true
                }
            }
            return false
        }
        // Legacy full-snapshot path (tests / callers that already have text).
        return snapshot!.split(whereSeparator: \.isNewline).contains { line in
            let s = String(line)
            guard s.localizedCaseInsensitiveContains("wineserver") else { return false }
            return lineMatchesAnyBottlePrefix(s, prefixes: prefixes)
        }
    }

    /// `pid` + command from a cheap `ps` (no environ — CEF `ps eww` can deadlock).
    static func pidAndCommandRows() -> [(pid: Int, command: String)] {
        let text = captureProcessOutput(
            executable: "/bin/ps",
            arguments: ["-ax", "-o", "pid=,command="]
        )
        var rows: [(pid: Int, command: String)] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            guard let idx = line.firstIndex(where: { $0.isWhitespace }) else { continue }
            let pidStr = String(line[..<idx])
            let cmd = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            guard let pid = Int(pidStr) else { continue }
            rows.append((pid, cmd))
        }
        return rows
    }

    private static func wineserverProcessCount() -> Int {
        captureProcessOutput(executable: "/usr/bin/pgrep", arguments: ["-x", "wineserver"])
            .split(whereSeparator: \.isNewline)
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .count
    }

    /// Command lines of Wine PE `steam.exe` owned by this bottle.
    /// Prefers `WINEPREFIX` on that PID; if the PE has no prefix, a single
    /// `steam.exe` plus a single wineserver is treated as this bottle.
    private static func steamClientCommandLines(in bottle: Bottle) -> [String] {
        guard isBottleWineserverRunning(in: bottle) else { return [] }
        let prefixes = bottlePrefixCandidates(for: bottle)
        var matched: [String] = []
        var unmatched: [String] = []
        for (pid, cmd) in pidAndCommandRows() where lineIsSteamClientExe(cmd) {
            let envLine = captureProcessOutput(
                executable: "/bin/ps",
                arguments: ["eww", "-p", "\(pid)"]
            )
            if lineMatchesAnyBottlePrefix(envLine, prefixes: prefixes) {
                matched.append(cmd)
            } else {
                unmatched.append(cmd)
            }
        }
        if !matched.isEmpty { return matched }
        if unmatched.count == 1, wineserverProcessCount() == 1 {
            return unmatched
        }
        return []
    }

    private static func commandHasSilentFlag(_ command: String) -> Bool {
        command.split(whereSeparator: \.isWhitespace).contains {
            $0.caseInsensitiveCompare("-silent") == .orderedSame
        }
    }

    /// True when this bottle's `steam.exe` was started with `-silent`
    /// (bootstrap that cannot show a login window).
    private static func isSilentSteamClientRunning(in bottle: Bottle) -> Bool {
        steamClientCommandLines(in: bottle).contains { commandHasSilentFlag($0) }
    }

    /// Any Wine PE `steam.exe` on the machine (not bottle-scoped).
    private static func anySteamClientRunning() -> Bool {
        pidAndCommandRows().contains { lineIsSteamClientExe($0.command) }
    }

    /// Whether Windows `steam.exe` is running for this bottle.
    ///
    /// Avoids `ps axeww` (huge CEF environs → pipe deadlock with `waitUntilExit` first).
    /// Bottle ownership: wineserver `WINEPREFIX=<bottle>`, then `steam.exe` PIDs.
    public static func isSteamClientRunning(in bottle: Bottle) -> Bool {
        !steamClientCommandLines(in: bottle).isEmpty
    }

    /// Executable path from a wineserver `ps` command line (macOS paths may contain spaces).
    private static func wineserverExecutablePath(fromCommand cmd: String) -> String? {
        let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: "wineserver", options: [.caseInsensitive, .backwards]) else {
            return nil
        }
        // From start through the "wineserver" filename — do not split on spaces.
        return String(trimmed[..<range.upperBound])
    }

    /// Whether the bottle's wineserver binary belongs to the given Wyn Wine tree.
    public static func isBottleWineserverFromTree(in bottle: Bottle, tree: WineTree) -> Bool {
        let expected = Wine.wineserverBinary(for: tree).resolvingSymlinksInPath().path
        let prefixes = bottlePrefixCandidates(for: bottle)
        let pidsText = captureProcessOutput(
            executable: "/usr/bin/pgrep",
            arguments: ["-x", "wineserver"]
        )
        let pids = pidsText.split(whereSeparator: \.isNewline).compactMap {
            Int($0.trimmingCharacters(in: .whitespaces))
        }
        for pid in pids {
            let envLine = captureProcessOutput(
                executable: "/bin/ps",
                arguments: ["eww", "-p", "\(pid)"]
            )
            guard lineMatchesAnyBottlePrefix(envLine, prefixes: prefixes) else { continue }
            let cmd = captureProcessOutput(
                executable: "/bin/ps",
                arguments: ["-p", "\(pid)", "-o", "command="]
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let exePath = wineserverExecutablePath(fromCommand: cmd) else { continue }
            let resolved = URL(fileURLWithPath: exePath).resolvingSymlinksInPath().path
            if resolved == expected { return true }
        }
        return false
    }

    static func progress(_ message: String) {
        LaunchProgress.emit(message)
    }

    /// Start Steam in the bottle if needed for SteamAPI. Default: game-host `Libraries/`.
    /// With `preferFrankeaSteam`: frankea `Libraries.steam`. Does not kill an already-running Steam session.
    public static func ensureSteamRunningForAuth(
        in bottle: Bottle,
        options: Wine.LaunchOptions = Wine.LaunchOptions(),
        gameExeNames: [String] = []
    ) async throws {
        guard isSteamInstalled(in: bottle) else {
            throw SteamError.steamNotInstalled
        }

        let useGameHost = !options.preferFrankeaSteam
        if useGameHost {
            guard WynWineInstaller.isWynWineInstalled() else {
                throw SteamError.steamWineMissing
            }
        } else {
            _ = try WynWineInstaller.ensureSteamWineTree()
            guard WynWineInstaller.isSteamWineInstalled() else {
                throw SteamError.steamWineMissing
            }
        }

        progress(options.debug
            ? "[wyn:debug] Checking Steam (pgrep wineserver + cheap ps for steam.exe)…"
            : "Checking Steam client for platform auth…")

        if isSteamClientRunning(in: bottle) {
            progress(options.debug
                ? "[wyn:debug] Steam client already running — keeping session for SteamAPI"
                : "Steam is running — keeping it for platform auth (SteamAPI → EOS).")
            return
        }

        let treeLabel = useGameHost ? "game-host" : "frankea"
        progress(options.debug
            ? "[wyn:debug] No Steam client — resetting bottle, then starting \(treeLabel) Steam"
            : "Starting Steam (\(treeLabel) Wine) so the game can authenticate…")

        // Final guard immediately before -k: never kill a live Steam/CEF session.
        if isSteamClientRunning(in: bottle) {
            progress("Steam appeared before reset — keeping session (skipping wineserver -k).")
            return
        }

        progress(options.debug
            ? "[wyn:debug] wineserver -k (no steam.exe for this bottle)…"
            : "Resetting bottle wineserver…")
        try await Wine.killBottleAndWait(bottle: bottle)
        progress(options.debug ? "[wyn:debug] wineserver -k done" : "Bottle reset complete.")

        let steamURL = steamExePath(in: bottle)
        let profile = ProfileStore.profile(id: "steam")
        let program = Program(url: steamURL, bottle: bottle)
        let environment: [String: String]

        if useGameHost {
            try prepareGameHostSteam(
                in: bottle,
                gameExeNames: gameExeNames,
                debug: options.debug
            )
            environment = gameHostSteamEnvironment(program: program)
        } else {
            if let profile {
                ProfileApplicator.apply(profile: profile, to: bottle)
            }
            try Wine.prepareFrankeaSteamClient(bottle: bottle, debug: options.debug)
            var frankeaEnv = ProfileApplicator.launchEnvironment(profile: profile, program: program)
            forwardCEFFlags(into: &frankeaEnv)
            environment = frankeaEnv
        }

        // Silent keeps CEF quieter; still needs a prior Remember-me login.
        var args = ProfileApplicator.launchArguments(profile: profile, program: program)
        if !args.contains(where: { $0.localizedCaseInsensitiveContains("-silent") }) {
            args.append("-silent")
        }

        var steamOptions = options
        steamOptions.wineTree = useGameHost ? .game : .steam
        steamOptions.preferGPTKSteam = useGameHost
        steamOptions.preferFrankeaSteam = !useGameHost
        if useGameHost {
            steamOptions.translationLayerOverride = .d3dMetal
        }
        // steam.exe -silent stays resident for the whole session, so awaiting its
        // exit never returns: the readiness loop below — and its 90s warning —
        // become unreachable and `wyn play` hangs on "Launching Steam…" forever.
        // Every other launchSteam caller already detaches; this one was the
        // outlier. Detach, then let the loop decide when Steam is actually up.
        steamOptions.detachAfterStart = true

        progress(options.debug
            ? "[wyn:debug] Launching \(treeLabel) steam.exe -silent…"
            : "Launching Steam…")
        try await Wine.runProgram(
            at: steamURL, args: args, bottle: bottle, environment: environment, options: steamOptions
        )

        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            try Task.checkCancellation()
            if isSteamClientRunning(in: bottle) {
                // Give steamclient a moment after process spawn.
                try await Task.sleep(nanoseconds: 2_000_000_000)
                progress(options.debug
                    ? "[wyn:debug] Steam client ready for SteamAPI"
                    : "Steam ready for platform auth.")
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        progress("Warning: Steam did not appear within 90s — SteamAPI may still fail. Check: wyn steam launch")
    }

    /// Snapshot of connection_log used to detect stale Logged-On after wineserver kill/migrate.
    public struct ConnectionLogFingerprint: Sendable, Equatable {
        public let lastStateLine: String?
        public let fileSize: UInt64
        public let mtime: Date?
    }

    /// Fingerprint of Steam connection_log.txt (size + last login-state line).
    public static func connectionLogFingerprint(in bottle: Bottle) -> ConnectionLogFingerprint {
        let log = connectionLogURL(in: bottle)
        let fm = FileManager.default
        guard fm.fileExists(atPath: log.path(percentEncoded: false)),
              let attrs = try? fm.attributesOfItem(atPath: log.path(percentEncoded: false)),
              let text = try? String(contentsOf: log, encoding: .utf8) else {
            return ConnectionLogFingerprint(lastStateLine: nil, fileSize: 0, mtime: nil)
        }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = attrs[.modificationDate] as? Date
        return ConnectionLogFingerprint(
            lastStateLine: lastLoginStateLine(in: text),
            fileSize: size,
            mtime: mtime
        )
    }

    private static func connectionLogURL(in bottle: Bottle) -> URL {
        bottle.url
            .appending(path: "drive_c")
            .appending(path: "Program Files (x86)")
            .appending(path: "Steam")
            .appending(path: "logs")
            .appending(path: "connection_log.txt")
    }

    private static func lastLoginStateLine(in text: String) -> String? {
        var lastState: String?
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            if line.contains("[Logged On") || line.contains("[Logged Off")
                || line.contains("[Logging On") || line.contains("[Connecting")
            {
                lastState = line
            }
        }
        return lastState
    }

    /// Whether Steam's connection log shows a logged-on account (Steamworks requires this for Init).
    /// See: partner.steamgames.com/doc/api/steam_api — license on the currently active Steam account.
    ///
    /// `steam.exe` must still be running — a leftover `[Logged On]` line from last night
    /// must not light the header or dismiss the overlay while Steam is dead.
    /// When `baseline` is set (post-migrate / post-restart), require a **new** login-state line
    /// so a pre-kill frankea `[Logged On]` cannot unlock GPTK D3DMetal.
    public static func isSteamLoggedOn(
        in bottle: Bottle,
        baseline: ConnectionLogFingerprint? = nil
    ) -> Bool {
        guard isSteamClientRunning(in: bottle) else { return false }
        let snap = LaunchDiagnostics.steamLoginSnapshot(bottle: bottle, baseline: baseline)
        return snap.loggedOn
    }

    /// One-Wine: Steam + game on game-host wineserver for D3DMetal.
    /// Per Steamworks docs, a Logged-On client is mandatory — never play on Logged-Off Steam.
    ///
    /// Default (P0-c): prefer/migrate to game-host Logged-On. Frankea+DXVK only when
    /// `preferFrankeaSteam` or migrate fails.
    public static func ensureSteamCoResidentForD3DMetal(
        in bottle: Bottle,
        gameExeNames: [String],
        options: Wine.LaunchOptions = Wine.LaunchOptions()
    ) async throws {
        guard isSteamInstalled(in: bottle) else {
            throw SteamError.steamNotInstalled
        }

        progress("Checking Steam session (Steamworks requires Logged On + ownership)…")

        let steamUp = isSteamClientRunning(in: bottle)
        let loggedOn = isSteamLoggedOn(in: bottle)
        let onGPTK = isBottleWineserverFromTree(in: bottle, tree: .game)
        let onFrankea = isBottleWineserverFromTree(in: bottle, tree: .steam)

        if steamUp, loggedOn, onGPTK {
            progress("Steam Logged On on game-host Wine — one-Wine path ready (SteamAPI → EOS + D3DMetal).")
            return
        }

        if steamUp, loggedOn, onFrankea {
            if options.preferFrankeaSteam {
                progress("Steam Logged On on frankea — keeping session (preferFrankeaSteam / --frankea-steam).")
                progress("Auth path: frankea + DXVK-macOS (3D may be weak). For D3DMetal: wyn steam launch without --frankea-steam.")
                return
            }
            progress("Steam Logged On on frankea — migrating to game-host Wine for D3DMetal…")
            let migrated = await tryMigrateSteamToGPTKLoggedOn(
                in: bottle,
                gameExeNames: gameExeNames,
                options: options
            )
            if migrated {
                progress("Game-host Steam Logged On — D3DMetal path unlocked.")
                return
            }
            progress("Game-host migrate failed — frankea Logged-On restored; last-resort DXVK-macOS.")
            return
        }

        if steamUp, !loggedOn {
            progress("Steam process is up but Logged Off — SteamAPI_Init will fail (Valve docs).")
            progress("Fix: wyn steam launch → log in (Remember me). Not starting Logged-Off Steam.")
            throw SteamError.steamNotLoggedOn
        }

        // Connect (or other frankea process) owns this bottle — never wineserver -k.
        if !steamUp, onFrankea, options.preferFrankeaSteam {
            progress("Frankea wineserver is up without Steam — starting Steam on it (keeping Connect).")
            var startOptions = options
            startOptions.preferFrankeaSteam = true
            startOptions.preferGPTKSteam = false
            startOptions.detachAfterStart = true
            try await launchSteam(in: bottle, options: startOptions)
            try await waitForSteamClient(in: bottle, seconds: 45)
            if isSteamLoggedOn(in: bottle) {
                progress("Frankea Steam Logged On — keeping Connect wineserver.")
                return
            }
            progress("Steam started on frankea but is not Logged On.")
            throw SteamError.steamNotLoggedOn
        }

        // No Steam: start game-host -silent (unless frankea rollback).
        var startOptions = options
        if options.preferFrankeaSteam {
            startOptions.preferGPTKSteam = false
            startOptions.preferFrankeaSteam = true
            progress("No Steam client — starting frankea Steam -silent (needs prior Remember-me login)…")
        } else {
            startOptions.preferGPTKSteam = true
            startOptions.preferFrankeaSteam = false
            progress("No Steam client — starting game-host Steam -silent (needs prior Remember-me login)…")
        }
        try await ensureSteamRunningForAuth(
            in: bottle,
            options: startOptions,
            gameExeNames: gameExeNames
        )
        // ensureSteamRunningForAuth returns once the *client process* exists, but
        // Steamworks needs it Logged On, and logging on is a separate ~20-25s of
        // network round-trips after that. Checking once here meant a cold start
        // always lost the race: the first Play after a reboot threw
        // steamNotLoggedOn and you had to click a second time once Steam settled.
        //
        // waitForSteamLoggedOn already existed for exactly this, but only the
        // frankea fallback used it — so the fallback path waited patiently for
        // login while the primary D3DMetal path did not. 60s matches that caller
        // and is generous against the observed gap.
        // Only the timeout is swallowed: falling through re-uses the existing
        // Logged-On check and its message below. Cancellation must still
        // propagate — the app's Cancel button relies on it.
        do {
            try await waitForSteamLoggedOn(in: bottle, seconds: 60)
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            // Timed out waiting for login — handled below.
        }

        if isSteamLoggedOn(in: bottle) {
            let tree = isBottleWineserverFromTree(in: bottle, tree: .game) ? "game-host" : "frankea"
            progress("\(tree) Steam Logged On — ready for SteamAPI.")
            if !options.preferFrankeaSteam,
               isBottleWineserverFromTree(in: bottle, tree: .steam)
            {
                progress("Silent start landed on frankea — migrating to game-host…")
                let migrated = await tryMigrateSteamToGPTKLoggedOn(
                    in: bottle,
                    gameExeNames: gameExeNames,
                    options: options
                )
                if migrated {
                    progress("Game-host Steam Logged On — D3DMetal path unlocked.")
                    return
                }
                progress("Migrate failed — staying on frankea Logged-On.")
            }
            return
        }
        progress("Warning: Steam started but not Logged On — check: wyn steam launch")
        throw SteamError.steamNotLoggedOn
    }

    /// Stop frankea, start GPTK Steam -silent, poll **fresh** Logged On.
    /// On failure: kill GPTK, restore frankea -silent until Logged On.
    /// Returns true only when Steam is Logged On on the GPTK wineserver with a new log line.
    @discardableResult
    public static func tryMigrateSteamToGPTKLoggedOn(
        in bottle: Bottle,
        gameExeNames: [String],
        options: Wine.LaunchOptions = Wine.LaunchOptions()
    ) async -> Bool {
        guard GPTKInstaller.isWineGPTKAware() else {
            progress("GPTK migrate skipped — Wine is not GPTK-aware.")
            return false
        }
        guard isSteamInstalled(in: bottle) else { return false }

        let baseline = connectionLogFingerprint(in: bottle)
        LaunchDiagnostics.printAuthSignal(
            bottle: bottle,
            wineTree: .steam,
            phase: "pre-migrate"
        )

        progress("Migrating Steam → game-host wineserver (required for D3DMetal; stops frankea)…")
        do {
            try await Wine.killBottleAndWait(bottle: bottle)
        } catch {
            progress("Warning: wineserver -k failed: \(error.localizedDescription)")
        }

        do {
            try prepareGameHostSteam(
                in: bottle,
                gameExeNames: gameExeNames,
                debug: options.debug
            )
        } catch {
            progress("GPTK Steam isolation failed: \(error.localizedDescription) — rolling back.")
            await rollbackSteamToFrankeaLoggedOn(in: bottle, options: options)
            return false
        }

        let steamURL = steamExePath(in: bottle)
        let steamProfile = ProfileStore.profile(id: "steam")
        let program = Program(url: steamURL, bottle: bottle)
        var environment = gameHostSteamEnvironment(program: program)
        environment.removeValue(forKey: "WINESERVER")
        var args = ProfileApplicator.launchArguments(profile: steamProfile, program: program)
        if !args.contains(where: { $0.localizedCaseInsensitiveContains("-silent") }) {
            args.append("-silent")
        }

        var steamOptions = options
        steamOptions.wineTree = .game
        steamOptions.preferD3DMetalAuth = false
        steamOptions.preferFrankeaSteam = false
        steamOptions.translationLayerOverride = .d3dMetal
        steamOptions.useWineBuiltinD3D = false

        progress("Launching GPTK steam.exe -silent…")
        LaunchDiagnostics.printAuthSignal(
            bottle: bottle,
            wineTree: .game,
            phase: "gptk-steam-poll"
        )

        // Detach so we can poll Logged On while wine start is in flight / Steam stays up.
        Task.detached(priority: .userInitiated) {
            _ = try? await Wine.runProgram(
                at: steamURL,
                args: args,
                bottle: bottle,
                environment: environment,
                options: steamOptions
            )
        }

        let pollSeconds: TimeInterval = 45
        let deadline = Date().addingTimeInterval(pollSeconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if isSteamClientRunning(in: bottle),
               isSteamLoggedOn(in: bottle, baseline: baseline),
               isBottleWineserverFromTree(in: bottle, tree: .game)
            {
                LaunchDiagnostics.printAuthSignal(
                    bottle: bottle,
                    wineTree: .game,
                    phase: "d3dmetal-go"
                )
                progress("GPTK Steam Logged On within \(Int(pollSeconds))s (fresh connection_log).")
                return true
            }
        }

        let login = LaunchDiagnostics.steamLoginSnapshot(bottle: bottle, baseline: baseline)
        progress("GPTK Steam did not reach fresh Logged On (\(login.summary)) — rolling back to frankea.")
        await rollbackSteamToFrankeaLoggedOn(in: bottle, options: options)
        return false
    }

    /// Kill current (likely GPTK) wineserver and restore frankea Steam Logged-On via -silent.
    private static func rollbackSteamToFrankeaLoggedOn(
        in bottle: Bottle,
        options: Wine.LaunchOptions
    ) async {
        LaunchDiagnostics.printAuthSignal(
            bottle: bottle,
            phase: "rollback-frankea"
        )
        progress("Rollback: stopping GPTK bottle, restarting frankea Steam -silent…")
        let baseline = connectionLogFingerprint(in: bottle)
        do {
            try await Wine.killBottleAndWait(bottle: bottle)
        } catch {
            progress("Warning: rollback wineserver -k failed: \(error.localizedDescription)")
        }

        do {
            _ = try WynWineInstaller.ensureSteamWineTree()
            try Wine.prepareFrankeaSteamClient(bottle: bottle, debug: options.debug)

            let steamURL = steamExePath(in: bottle)
            let steamProfile = ProfileStore.profile(id: "steam")
            let program = Program(url: steamURL, bottle: bottle)
            var environment = ProfileApplicator.launchEnvironment(profile: steamProfile, program: program)
            environment.removeValue(forKey: "WINESERVER")
            var args = ProfileApplicator.launchArguments(profile: steamProfile, program: program)
            if !args.contains(where: { $0.localizedCaseInsensitiveContains("-silent") }) {
                args.append("-silent")
            }

            var steamOptions = options
            steamOptions.wineTree = .steam
            steamOptions.preferD3DMetalAuth = false
            steamOptions.preferFrankeaSteam = true

            Task.detached(priority: .userInitiated) {
                _ = try? await Wine.runProgram(
                    at: steamURL,
                    args: args,
                    bottle: bottle,
                    environment: environment,
                    options: steamOptions
                )
            }

            let deadline = Date().addingTimeInterval(90)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if isSteamClientRunning(in: bottle),
                   isSteamLoggedOn(in: bottle, baseline: baseline),
                   isBottleWineserverFromTree(in: bottle, tree: .steam)
                {
                    progress("Rollback OK — frankea Steam Logged On again.")
                    LaunchDiagnostics.printAuthSignal(
                        bottle: bottle,
                        wineTree: .steam,
                        phase: "rollback-frankea-done"
                    )
                    return
                }
            }
            progress("Warning: frankea rollback did not reach Logged On in 90s — run: wyn steam launch --frankea-steam")
        } catch {
            progress("Rollback failed: \(error.localizedDescription) — run: wyn steam launch --frankea-steam")
        }
    }

    /// Prefer game-host + D3DMetal when Steam is Logged On there; otherwise last-resort frankea+DXVK
    /// on the frankea wineserver (migrate failed or `preferFrankeaSteam`).
    public static func launchGameDirectD3DMetal(
        appId: Int,
        executable: URL,
        profile: GameProfile,
        bottle: Bottle,
        gameArgs: [String],
        options: Wine.LaunchOptions = Wine.LaunchOptions()
    ) async throws {
        let gameExeNames = profile.exePatterns

        try await ensureSteamCoResidentForD3DMetal(
            in: bottle,
            gameExeNames: gameExeNames,
            options: options
        )

        let onGPTK = isBottleWineserverFromTree(in: bottle, tree: .game)
        let steamUp = isSteamClientRunning(in: bottle)
        let loggedOn = isSteamLoggedOn(in: bottle)

        if onGPTK, steamUp, loggedOn {
            guard GPTKInstaller.isWineGPTKAware() else {
                throw Wine.D3DMetalError.wineNotGPTKAware
            }
            progress("D3DMetal play: game EXE + Logged-On Steam on game-host Wine (one wineserver).")
            try await launchGameOnGPTKWithD3DMetal(
                appId: appId,
                executable: executable,
                profile: profile,
                bottle: bottle,
                gameArgs: gameArgs,
                gameExeNames: gameExeNames,
                options: options
            )
            return
        }

        if onGPTK, steamUp, !loggedOn {
            progress("Refusing D3DMetal on Logged-Off game-host Steam — restoring frankea auth path.")
            await rollbackSteamToFrankeaLoggedOn(in: bottle, options: options)
        }

        // Last resort: frankea Logged-On + DXVK-macOS (migrate failed or frankea preference).
        progress("Falling back to frankea + DXVK-macOS (not the P0-c D3DMetal path).")
        try await launchGameOnFrankeaWithDXVKMacOS(
            appId: appId,
            executable: executable,
            profile: profile,
            bottle: bottle,
            gameArgs: gameArgs,
            options: options
        )
    }

    /// Connect on frankea, then Steam on the same wineserver, then play with `preferFrankeaSteam`.
    /// GPTK already owning the bottle is a hard fail — silent GPTK Steam would hang Logged Off
    /// and `wineserver -k` would kill Connect.
    private static func prepareUbisoftConnectThenFrankeaSteam(
        in bottle: Bottle,
        options: inout Wine.LaunchOptions
    ) async throws {
        if isBottleWineserverFromTree(in: bottle, tree: .game) {
            throw PlatformLaunchError.connectOnGPTK
        }

        options.preferFrankeaSteam = true
        options.preferGPTKSteam = false

        progress("Opening Ubisoft Connect…")
        try await ConnectLauncher.launch(in: bottle)
        try Task.checkCancellation()

        if !isSteamClientRunning(in: bottle) {
            progress("Opening Steam…")
            var steamOptions = options
            steamOptions.preferFrankeaSteam = true
            steamOptions.preferGPTKSteam = false
            steamOptions.detachAfterStart = true
            try await launchSteam(in: bottle, options: steamOptions)
            try await waitForSteamClient(in: bottle, seconds: 45)
        }
        try Task.checkCancellation()

        if isBottleWineserverFromTree(in: bottle, tree: .game) {
            throw PlatformLaunchError.connectOnGPTK
        }

        try await waitForSteamLoggedOn(in: bottle, seconds: 60)
        progress("Launching game…")
    }

    private static func waitForSteamClient(in bottle: Bottle, seconds: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try Task.checkCancellation()
            if isSteamClientRunning(in: bottle) { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        progress("Steam did not appear after Connect. Log in with Steam on frankea, then Play again.")
        throw SteamError.steamNotLoggedOn
    }

    private static func waitForSteamLoggedOn(in bottle: Bottle, seconds: TimeInterval) async throws {
        if isSteamLoggedOn(in: bottle) { return }
        progress("Waiting for Steam Logged On…")
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try Task.checkCancellation()
            if isSteamLoggedOn(in: bottle) { return }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw SteamError.steamNotLoggedOn
    }

    /// Proven auth path: frankea wineserver + DXVK-macOS 1.10.3 (UI+EOS; 3D may be black).
    private static func launchGameOnFrankeaWithDXVKMacOS(
        appId: Int,
        executable: URL,
        profile: GameProfile,
        bottle: Bottle,
        gameArgs: [String],
        options: Wine.LaunchOptions
    ) async throws {
        progress("Auth-preserving play: frankea Wine + Logged-On Steam (SteamAPI→EOS).")
        _ = try WynWineInstaller.ensureSteamWineTree()
        progress("Graphics: DXVK-macOS 1.10.3 on frankea (not upstream 2.x — needs geometryShader).")
        try Wine.prepareFrankeaSteamClient(bottle: bottle, debug: options.debug)

        let frankeaGame: [String: String] = [
            "d3d11": "n",
            "dxgi": "n",
            "d3d10core": "n",
            "d3d12": "d",
            "atidxx64": "d",
            "gameoverlayrenderer64": "d",
            "gameoverlayrenderer": "d"
        ]
        for raw in profile.exePatterns {
            let name = (raw as NSString).lastPathComponent
            guard name.lowercased().hasSuffix(".exe") else { continue }
            try Wine.setAppDllOverrides(bottle: bottle, exeName: name, overrides: frankeaGame)
        }

        let program = Program(url: executable, bottle: bottle)
        var environment = ProfileApplicator.launchEnvironment(profile: profile, program: program)
        environment["SteamAppId"] = "\(appId)"
        environment["SteamGameId"] = "\(appId)"
        environment.removeValue(forKey: "WINESERVER")
        for key in ["D3DM_ENABLE_METALFX", "D3DM_SHOW_HUD_STATS", "MTL_HUD_ENABLED", "CX_APPLEGPTK_D3DMETAL"] {
            environment.removeValue(forKey: key)
        }
        environment["WINEDLLOVERRIDES"] =
            "d3d11,dxgi,d3d10core=n,b;d3d12=d;gameoverlayrenderer64=d;gameoverlayrenderer=d"
        environment["DXVK_ASYNC"] = "1"
        environment["DXVK_LOG_LEVEL"] = "info"
        try Wine.ensureDXVKLogDirectory(bottle: bottle)
        // Forward slashes: DXVK appends "/d3d11.log" itself, and Wine resolves the mixed
        // form less predictably than a fully forward-slashed drive path.
        environment["DXVK_LOG_PATH"] = "C:/fly/logs"
        // DXVK_STATE_CACHE_PATH is deliberately left unset: steamclient64.dll already points
        // DXVK at steamapps/shadercache/<appId>/DXVK_state_cache, and that cache is populated.
        environment["MTL_HUD_ENABLED"] = "0"

        var playOptions = options
        playOptions.wineTree = .steam
        playOptions.translationLayerOverride = .dxvk
        playOptions.useWineBuiltinD3D = false
        playOptions.preferD3DMetalAuth = false

        LaunchDiagnostics.printAuthSignal(
            bottle: bottle,
            profile: profile,
            wineTree: .steam,
            layer: .dxvk,
            phase: "pre-launch (frankea+DXVK)"
        )
        progress("Launching under frankea Wine (same wineserver as Logged-On Steam)…")
        progress("DXVK-macOS + MoltenVK (not wined3d — that triggers Feature Level 11.0).")
        let exitStatus = try await Wine.runProgram(
            at: executable,
            args: gameArgs,
            bottle: bottle,
            environment: environment,
            options: playOptions
        )
        LaunchDiagnostics.printAuthSignal(
            bottle: bottle,
            profile: profile,
            wineTree: .steam,
            layer: .dxvk,
            wineExitStatus: exitStatus,
            phase: "post-launch (frankea+DXVK)"
        )
    }

    private static func launchGameOnGPTKWithD3DMetal(
        appId: Int,
        executable: URL,
        profile: GameProfile,
        bottle: Bottle,
        gameArgs: [String],
        gameExeNames: [String],
        options: Wine.LaunchOptions
    ) async throws {
        progress(options.debug
            ? "[wyn:debug] Applying D3DMetal game DLL overrides…"
            : "Preparing D3DMetal overrides…")
        try Wine.applyD3DMetalGameOverrides(
            bottle: bottle,
            gameExeNames: gameExeNames,
            debug: options.debug
        )

        let program = Program(url: executable, bottle: bottle)
        var environment = ProfileApplicator.launchEnvironment(profile: profile, program: program)
        environment["SteamAppId"] = "\(appId)"
        environment["SteamGameId"] = "\(appId)"
        environment.removeValue(forKey: "WINESERVER")
        let gptkOverrides = TranslationLayer.d3dMetal.environmentOverrides()
        environment.merge(gptkOverrides, uniquingKeysWith: { _, new in new })
        let overlayOff = "gameoverlayrenderer64=d;gameoverlayrenderer=d"
        if let existing = environment["WINEDLLOVERRIDES"], !existing.isEmpty {
            environment["WINEDLLOVERRIDES"] = "\(overlayOff);\(existing)"
        } else {
            environment["WINEDLLOVERRIDES"] = overlayOff
        }

        var playOptions = options
        playOptions.wineTree = .game

        if options.debug {
            progress("[wyn:debug] play → GPTK game Wine (\(WynWineInstaller.libraryFolder.path))")
            progress("[wyn:debug] exe: \(executable.path(percentEncoded: false))")
            progress("[wyn:debug] args: \(gameArgs.joined(separator: " "))")
        } else {
            progress("Launching under GPTK-aware Wine. Look for D3DM in logs; no Feature Level 11.0 dialog.")
        }

        LaunchDiagnostics.printAuthSignal(
            bottle: bottle,
            profile: profile,
            wineTree: .game,
            layer: .d3dMetal,
            phase: "pre-launch (GPTK+D3DMetal)"
        )
        let exitStatus = try await Wine.runProgram(
            at: executable,
            args: gameArgs,
            bottle: bottle,
            environment: environment,
            options: playOptions
        )
        scheduleD3DMetalExitStamp(profile: profile, bottle: bottle)
        LaunchDiagnostics.printAuthSignal(
            bottle: bottle,
            profile: profile,
            wineTree: .game,
            layer: .d3dMetal,
            wineExitStatus: exitStatus,
            phase: "post-launch (GPTK+D3DMetal)"
        )
    }

    /// Launch a Steam game through `steam.exe -applaunch` so OnlineSubsystemSteam
    /// does not immediately exit with "Game restarting within Steam client".
    ///
    /// Game profile env (DXMT DLL overrides, `-dx11`, etc.) is applied to the Wine
    /// process so Steam-spawned children inherit it.
    public static func launchGameViaSteam(
        appId: Int,
        profile: GameProfile,
        bottle: Bottle,
        gameArgs: [String]? = nil,
        options: Wine.LaunchOptions = Wine.LaunchOptions()
    ) async throws {
        let steamURL = steamExePath(in: bottle)
        guard FileManager.default.fileExists(atPath: steamURL.path(percentEncoded: false)) else {
            throw SteamError.steamNotInstalled
        }

        let viaSteamOnly = profile.exePatterns.isEmpty
        if !viaSteamOnly {
            ProfileApplicator.apply(profile: profile, to: bottle)
        }

        let steamProgram = Program(url: steamURL, bottle: bottle)
        var environment = ProfileApplicator.launchEnvironment(profile: profile, program: steamProgram)

        let layer = profile.bottle?.translationLayer
            ?? bottle.settings.translationLayer

        // D3DMetal must not use this path — Option A is GPTK direct EXE.
        // Unprofiled library titles have no EXE; frankea Steam -applaunch is the launch path.
        if layer == .d3dMetal && !viaSteamOnly {
            throw SteamError.d3dMetalRequiresDirectLaunch
        }

        let effectiveLayer: TranslationLayer = (viaSteamOnly && layer == .d3dMetal) ? .dxmt : layer

        // Keep Steam overlay quirk, but do NOT let steam.json's dxgi/d3d11=n,b
        // clobber the game's layer.
        if let steamProfile = ProfileStore.profile(id: "steam"),
           let steamOverrides = steamProfile.environment["WINEDLLOVERRIDES"] {
            let overlayOnly = steamOverrides
                .split(separator: ";")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.lowercased().contains("gameoverlayrenderer") }
                .joined(separator: ";")
            if !overlayOnly.isEmpty {
                if let existing = environment["WINEDLLOVERRIDES"], !existing.isEmpty {
                    environment["WINEDLLOVERRIDES"] = "\(existing);\(overlayOnly)"
                } else {
                    environment["WINEDLLOVERRIDES"] = overlayOnly
                }
            }
        }

        environment["SteamAppId"] = "\(appId)"
        environment["SteamGameId"] = "\(appId)"

        let resolvedGameArgs = gameArgs ?? ProfileApplicator.launchArguments(
            profile: profile,
            program: steamProgram
        )

        // Critical: if Steam is already running, `-applaunch` only signals that process.
        // Cold-restart so game args / DLL overrides apply.
        //
        // GPTK-aware Wine breaks Steam CEF — play uses frankea Steam Wine for DXMT/DXVK.
        if options.debug {
            print("[wyn:debug] Restarting Wine bottle for frankea Steam -applaunch…")
        } else {
            print("Restarting Steam (frankea Wine) so the game can launch…")
        }
        try await Wine.killBottleAndWait(bottle: bottle)

        _ = try WynWineInstaller.ensureSteamWineTree()
        try Wine.prepareFrankeaSteamClient(bottle: bottle, debug: options.debug)

        if effectiveLayer == .dxmt {
            // Game EXEs: DXMT natives. Steam: frankea builtins (set by prepareFrankea).
            let gameDXMT: [String: String] = [
                "d3d11": "n",
                "dxgi": "n",
                "d3d10core": "n",
                "d3d12": "d",
                "atidxx64": "d"
            ]
            for raw in profile.exePatterns {
                let exe = (raw as NSString).lastPathComponent
                guard exe.lowercased().hasSuffix(".exe") else { continue }
                try Wine.setAppDllOverrides(bottle: bottle, exeName: exe, overrides: gameDXMT)
            }
            environment["WINEDLLOVERRIDES"] =
                "d3d11,dxgi,d3d10core=n,b;gameoverlayrenderer64=n;steamerrorreporter64.exe,steamerrorreporter.exe=d"
        }

        let hostEnv = ProcessInfo.processInfo.environment
        for key in ["WYN_CEF_FLAGS", "FLY_CEF_FLAGS", "AETHER_CEF_FLAGS"] {
            if let value = hostEnv[key], !value.isEmpty {
                environment[key] = value
            }
        }

        var args: [String] = []
        if let steamProfile = ProfileStore.profile(id: "steam") {
            args.append(contentsOf: ProfileApplicator.launchArguments(
                profile: steamProfile, program: steamProgram
            ))
        }
        args.append(contentsOf: ["-applaunch", "\(appId)"])
        args.append(contentsOf: resolvedGameArgs)

        var playOptions = options
        playOptions.wineTree = .steam

        if options.debug {
            print("[wyn:debug] play → frankea Steam Wine (\(WynWineInstaller.steamLibraryFolder.path))")
            print("[wyn:debug] steam args: \(args.joined(separator: " "))")
            print("[wyn:debug] WINEDLLOVERRIDES=\(environment["WINEDLLOVERRIDES"] ?? "(none)")")
            SteamUIDiagnostics.printSnapshot(bottle: bottle, label: "pre-launch")
        }

        let sampler: Task<Void, Never>? = options.debug
            ? SteamUIDiagnostics.startSampling(bottle: bottle)
            : nil
        defer { sampler?.cancel() }

        try await Wine.runProgram(
            at: steamURL,
            args: args,
            bottle: bottle,
            environment: environment,
            options: playOptions
        )

        if options.debug {
            SteamUIDiagnostics.printSnapshot(bottle: bottle, label: "post-exit")
        }
    }

    /// Ensure the default Steam bottle exists in the registry.
    @discardableResult
    public static func ensureSteamBottle() throws -> Bottle {
        var data = BottleData()
        let bottles = data.loadBottles()

        if let existing = bottles.first(where: { $0.settings.name == defaultBottleName }) {
            return existing
        }

        let bottleURL = BottleData.defaultBottleDir.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: bottleURL, withIntermediateDirectories: true)

        let bottle = Bottle(bottleUrl: bottleURL, inFlight: true)
        bottle.settings.name = defaultBottleName
        bottle.settings.windowsVersion = .win10
        bottle.settings.translationLayer = .dxmt
        bottle.settings.enhancedSync = .msync
        bottle.settings.avxEnabled = true

        data.paths.append(bottleURL)
        return bottle
    }

    // MARK: - Private

    private static func parseManifestValue(named key: String, in manifest: String) -> String? {
        parseManifestValues(named: key, in: manifest).first
    }

    private static func parseManifestValues(named key: String, in manifest: String) -> [String] {
        let pattern = #""\#(key)"\s+"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(manifest.startIndex..., in: manifest)
        return regex.matches(in: manifest, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: manifest) else { return nil }
            return String(manifest[r])
        }
    }

    /// Map a Wine/Steam Windows path (`C:\…`, `Z:\Volumes\…`) onto the host filesystem.
    private static func unixURL(forWindowsPath winPath: String, in bottle: Bottle) -> URL? {
        let trimmed = winPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }

        let normalized = trimmed.replacingOccurrences(of: "/", with: "\\")
        guard normalized.count >= 2, normalized[normalized.index(normalized.startIndex, offsetBy: 1)] == ":" else {
            return nil
        }

        let drive = normalized[normalized.startIndex].lowercased()
        let rest = String(normalized.dropFirst(2))
            .trimmingCharacters(in: CharacterSet(charactersIn: "\\"))
            .replacingOccurrences(of: "\\", with: "/")

        let dosLink = bottle.url.appending(path: "dosdevices").appending(path: "\(drive):")
        let resolvedDos = dosLink.resolvingSymlinksInPath()
        if rest.isEmpty {
            return resolvedDos
        }
        return resolvedDos.appending(path: rest)
    }

    /// True when the Steam install folder has a Windows game EXE (not Mac `.app` / redistributables).
    public static func hasWindowsGameExecutable(in installDirectory: URL) -> Bool {
        let skipFolders: Set<String> = [
            "_commonredist",
            "easyanticheat",
            "__installer",
        ]
        let helperNeedles = [
            "uninstall",
            "vcredist",
            "vc_redist",
            "dxsetup",
            "unitycrashhandler",
            "crashhandler",
            "easyanticheat",
            "ue4prereq",
        ]

        guard let enumerator = FileManager.default.enumerator(
            at: installDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return false }

        for case let url as URL in enumerator {
            let name = url.lastPathComponent.lowercased()
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

            if isDirectory {
                if url.pathExtension.lowercased() == "app" || skipFolders.contains(name) {
                    enumerator.skipDescendants()
                }
                continue
            }

            if url.pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }) {
                continue
            }

            guard url.pathExtension.lowercased() == "exe" else { continue }
            if name.hasPrefix("unins") { continue }
            if helperNeedles.contains(where: { name.contains($0) }) { continue }
            return true
        }

        return false
    }

    private static func findExecutable(matching profile: GameProfile, under root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var matched: [URL] = []
        var fallback: URL?
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "exe" else { continue }
            if profile.matches(executable: url) {
                matched.append(url)
            } else if fallback == nil {
                fallback = url
            }
        }

        // Honor profile.exePatterns order (shipping before launcher).
        for pattern in profile.exePatterns {
            let needle = pattern.lowercased()
            if let hit = matched.first(where: {
                fnmatch(needle, $0.lastPathComponent.lowercased(), 0) == 0
            }) {
                return hit
            }
        }
        return matched.first ?? fallback
    }
}

public enum SteamError: LocalizedError {
    case downloadFailed
    case steamNotInstalled
    case steamSetupFailed
    case steamWineMissing
    case steamNotLoggedOn
    case steamDidNotExit
    case steamAlreadyRunningElsewhere
    case cefDidNotAppear
    case gameNotInstalled(appId: Int)
    case missingSteamAppId(profileId: String)
    case d3dMetalRequiresDirectLaunch
    case previousSessionStillRunning(summary: String)

    public var errorDescription: String? {
        switch self {
        case .downloadFailed:
            return "Failed to download SteamSetup.exe from Steam CDN."
        case .steamNotInstalled:
            return "Steam is not installed in this bottle. Run: wyn steam install"
        case .steamSetupFailed:
            return "SteamSetup finished without steam.exe. Re-run: wyn steam install"
        case .steamWineMissing:
            return "Wine tree missing for Steam. One-Wine needs Libraries/ (GPTK-aware); frankea fallback needs Libraries.steam or Libraries.pre-gptk-aware.bak."
        case .steamNotLoggedOn:
            return "Steam is not Logged On. Steamworks requires a logged-in client that owns the game. Run: wyn steam launch → log in (Remember me)."
        case .steamDidNotExit:
            return "Steam did not exit after steam.exe -shutdown. Use Steam → Exit (never wineserver -k), then: wyn steam launch"
        case .steamAlreadyRunningElsewhere:
            return "Steam is already running in another bottle or session. Use Steam → Exit (never wineserver -k), then retry."
        case .cefDidNotAppear:
            return "Steam did not unpack CEF (bin/cef/cef.win*). Quit Steam via Steam → Exit, then: wyn steam launch"
        case .gameNotInstalled(let appId):
            return "Game (Steam app \(appId)) is not installed. Open Steam and install it first."
        case .missingSteamAppId(let profileId):
            return "Profile \"\(profileId)\" has no Steam app id."
        case .d3dMetalRequiresDirectLaunch:
            return """
            D3DMetal profiles use GPTK direct game EXE with Steam co-resident (Apple model). \
            Log in with: wyn steam launch → Remember me → wyn play <profile> (leave Steam running)
            """
        case .previousSessionStillRunning(let summary):
            return """
            Previous session still running (\(summary)). Quit the game from its window \
            (never wineserver -k), then: wyn play
            """
        }
    }
}
