//
//  PlatformCatalog.swift
//  WynKit
//
//  Installed Windows storefronts for the home-screen Platform row.
//  Probe known EXE paths only — never Steam ACF, never a recursive
//  EpicGamesLauncher.exe search (RDR2 ships a stub next to the game).
//

import Foundation

/// Windows storefronts Wyn can put on the Platform row.
public enum PlatformKind: String, Sendable, Hashable, CaseIterable, Identifiable {
    case steam
    case ubisoft
    case rockstar
    case epic
    case ea
    case battlenet
    case gog

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .steam: return "Steam"
        case .ubisoft: return "Ubisoft Connect"
        case .rockstar: return "Rockstar"
        case .epic: return "Epic (Heroic)"
        case .ea: return "EA App"
        case .battlenet: return "Battle.net"
        case .gog: return "GOG (Heroic)"
        }
    }

    /// Compact Platform tile symbol. Steam uses the Wyn logo instead.
    public var systemImage: String {
        switch self {
        case .steam: return "gamecontroller.fill"
        case .ubisoft: return "globe.europe.africa.fill"
        case .rockstar: return "star.fill"
        case .epic: return "circle.hexagongrid.fill"
        case .ea: return "e.circle.fill"
        case .battlenet: return "cloud.fill"
        case .gog: return "shippingbox.fill"
        }
    }

    /// Storefronts Wyn can install via the official Windows installer (not Steam / Connect / Rockstar).
    public static let installableStorefronts: [PlatformKind] = [.epic, .ea, .battlenet, .gog]

    public static let displayOrder: [PlatformKind] = [
        .steam, .ubisoft, .rockstar, .epic, .ea, .battlenet, .gog
    ]
}

/// A storefront EXE that exists on disk, plus the bottle it lives in.
public struct InstalledPlatform: Identifiable, Hashable, Sendable {
    public let kind: PlatformKind
    public let executable: URL
    public let bottleURL: URL

    public var id: String {
        "\(kind.rawValue):\(bottleURL.path(percentEncoded: false))"
    }

    public func bottle() -> Bottle {
        Bottle(bottleUrl: bottleURL, isAvailable: true)
    }
}

public enum PlatformLaunchError: LocalizedError, Sendable {
    case executableMissing(PlatformKind)
    case wineTreeMissing(WineTree)
    case presentDylibsMissing
    case connectOnGPTK
    case unexpectedWineserver
    case connectWedged
    case notWired(PlatformKind)

    public var errorDescription: String? {
        switch self {
        case .executableMissing(let kind):
            return "\(kind.displayName) is not installed."
        case .wineTreeMissing(let tree):
            return "Wine tree missing: \(tree.displayName)."
        case .presentDylibsMissing:
            return "Present dylibs were not found under Tools/bin (fly_stretch_epi_bridge + present_force_inject + winemac_rtld_global)."
        case .connectOnGPTK:
            return """
            Ubisoft Connect needs frankea Wine. Steam is already running on GPTK in this bottle — \
            quit Steam, then open Connect. Launching Connect on the GPTK tree shows a transparent window.
            """
        case .unexpectedWineserver:
            return "This bottle already has a wineserver that is not frankea. Quit it before opening Ubisoft Connect."
        case .connectWedged:
            return "Ubisoft Connect wedged at StartView. Try again in a moment."
        case .notWired(let kind):
            return "\(kind.displayName) is installed but Wyn does not launch it yet."
        }
    }
}

public enum PlatformCatalog {
    /// RDR2 / Rockstar clone. Not registered in BottleVM — metadata name is also "Steam".
    public static let knownRockstarBottleUUID = "F83BCCE3-5035-4EC9-993A-148CE70A6EF1"

    /// EXEs relative to `drive_c`. Epic paths are the store client only, not the RDR2 stub.
    public static func relativeExeComponents(for kind: PlatformKind) -> [[String]] {
        switch kind {
        case .steam:
            return [["Program Files (x86)", "Steam", "steam.exe"]]
        case .ubisoft:
            return [["Program Files (x86)", "Ubisoft", "Ubisoft Game Launcher", "upc.exe"]]
        case .rockstar:
            return [["Program Files", "Rockstar Games", "Launcher", "Launcher.exe"]]
        case .epic:
            // Win64 portal UI before Win32. The Win32 copy is a 4.8 MB stub
            // without EOSSDK — probing it first made Play fall through to
            // staged ProgramData, and Epic's self-update then spawned
            // UpdateInstall\Portal\Extras\Win64 (R6025).
            return [
                ["Program Files", "Epic Games", "Launcher", "Portal", "Binaries", "Win64", "EpicGamesLauncher.exe"],
                ["Program Files (x86)", "Epic Games", "Launcher", "Portal", "Binaries", "Win64", "EpicGamesLauncher.exe"],
                ["Program Files", "Epic Games", "Launcher", "Portal", "Binaries", "Win32", "EpicGamesLauncher.exe"],
                ["Program Files (x86)", "Epic Games", "Launcher", "Portal", "Binaries", "Win32", "EpicGamesLauncher.exe"]
            ]
        case .ea:
            // Also scans EA Desktop/<version>/EA Desktop/EADesktop.exe in exeURL.
            return [
                ["Program Files", "Electronic Arts", "EA Desktop", "EA Desktop", "EADesktop.exe"],
                ["Program Files", "Electronic Arts", "EA Desktop", "EA Desktop", "EALauncher.exe"],
                ["Program Files (x86)", "Origin", "Origin.exe"]
            ]
        case .battlenet:
            return [
                ["Program Files (x86)", "Battle.net", "Battle.net.exe"],
                ["Program Files (x86)", "Battle.net", "Battle.net Launcher.exe"]
            ]
        case .gog:
            // Galaxy 2.x is 64-bit Inno Setup — it lands in Program Files,
            // not (x86). Probing only (x86) left a full install looking like
            // "Click to install" and re-ran GOG_Galaxy_2.0.exe.
            return [
                ["Program Files", "GOG Galaxy", "GalaxyClient.exe"],
                ["Program Files (x86)", "GOG Galaxy", "GalaxyClient.exe"]
            ]
        }
    }

    public static func exeURL(kind: PlatformKind, in bottle: Bottle) -> URL? {
        let fm = FileManager.default
        let driveC = bottle.url.appending(path: "drive_c")
        for components in relativeExeComponents(for: kind) {
            let url = components.reduce(driveC) { $0.appending(path: $1) }
            if fm.fileExists(atPath: url.path(percentEncoded: false)) {
                return url
            }
        }
        if kind == .ea, let versioned = eaDesktopVersionedExe(driveC: driveC) {
            return versioned
        }
        return nil
    }

    /// EA App 13+ uses `Program Files/Electronic Arts/EA Desktop/<build>/EA Desktop/EADesktop.exe`.
    /// One-level scan only — not a recursive drive walk.
    private static func eaDesktopVersionedExe(driveC: URL) -> URL? {
        let fm = FileManager.default
        let root = driveC
            .appending(path: "Program Files")
            .appending(path: "Electronic Arts")
            .appending(path: "EA Desktop")
        guard let children = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let dirs = children
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for dir in dirs {
            let nested = dir.appending(path: "EA Desktop").appending(path: "EADesktop.exe")
            if fm.fileExists(atPath: nested.path(percentEncoded: false)) {
                return nested
            }
            let flat = dir.appending(path: "EADesktop.exe")
            if fm.fileExists(atPath: flat.path(percentEncoded: false)) {
                return flat
            }
        }
        return nil
    }

    /// Installed storefronts. Steam + Connect come only from the registered Steam bottle.
    /// Dedicated store bottles prefer their named BottleVM prefix. Rockstar is the clone
    /// prefix (not added to BottleVM). One tile per kind.
    public static func installed() -> [InstalledPlatform] {
        var found: [PlatformKind: InstalledPlatform] = [:]
        let steam = GameLibrary.steamBottle()
        var data = BottleData()
        let registered = data.loadBottles()

        for kind in PlatformKind.installableStorefronts {
            guard let name = kind.dedicatedBottleName else { continue }
            if let bottle = registered.first(where: { $0.settings.name == name }),
               let exe = exeURL(kind: kind, in: bottle) {
                found[kind] = InstalledPlatform(kind: kind, executable: exe, bottleURL: bottle.url)
            }
        }

        if let steam {
            for kind in [PlatformKind.steam, .ubisoft] {
                if let exe = exeURL(kind: kind, in: steam) {
                    found[kind] = InstalledPlatform(kind: kind, executable: exe, bottleURL: steam.url)
                }
            }
        }

        for url in unregisteredBottleURLs(excluding: steam?.url) {
            let bottle = Bottle(bottleUrl: url, isAvailable: true)
            if found[.rockstar] == nil, let exe = exeURL(kind: .rockstar, in: bottle) {
                found[.rockstar] = InstalledPlatform(kind: .rockstar, executable: exe, bottleURL: url)
            }
            for kind in PlatformKind.installableStorefronts {
                if found[kind] == nil, let exe = exeURL(kind: kind, in: bottle) {
                    found[kind] = InstalledPlatform(kind: kind, executable: exe, bottleURL: url)
                }
            }
        }

        return PlatformKind.displayOrder.compactMap { found[$0] }
    }

    /// Steam/Connect/Rockstar only when installed; Epic/EA/Battle.net/GOG always (Install if missing).
    public static func platformRow() -> [PlatformRowItem] {
        let byKind = Dictionary(uniqueKeysWithValues: installed().map { ($0.kind, $0) })
        return PlatformKind.displayOrder.compactMap { kind in
            if kind == .epic || kind == .gog {
                // Official EGL / Galaxy bottles do not count as installed.
                if let heroic = HeroicLauncher.appURL() {
                    return PlatformRowItem(
                        kind: kind,
                        installed: InstalledPlatform(
                            kind: kind,
                            executable: heroic,
                            bottleURL: heroic
                        )
                    )
                }
                return PlatformRowItem(kind: kind, installed: nil)
            }
            if let item = byKind[kind] {
                return PlatformRowItem(kind: kind, installed: item)
            }
            if PlatformKind.installableStorefronts.contains(kind) {
                return PlatformRowItem(kind: kind, installed: nil)
            }
            return nil
        }
    }

    public static func missingStorefronts(from installed: [InstalledPlatform] = installed()) -> [PlatformKind] {
        let present = Set(installed.map(\.kind))
        return PlatformKind.installableStorefronts.filter { !present.contains($0) }
    }

    public static func isRunning(_ kind: PlatformKind) -> Bool {
        if kind == .epic || kind == .gog {
            return HeroicLauncher.isRunning()
        }
        if kind == .battlenet {
            return isBattleNetRunningHealthy()
        }
        let commands = captureProcessOutput(executable: "/bin/ps", arguments: ["-ax", "-o", "command="])
        return commands.split(whereSeparator: \.isNewline).contains { lineLooksLike(kind, String($0)) }
    }

    /// Web installer / Inno Setup still up — not the Galaxy client.
    /// Play must not start a second `GOG_Galaxy_2.0.exe` on top of this.
    public static func isStoreInstallerRunning(_ kind: PlatformKind) -> Bool {
        let commands = captureProcessOutput(
            executable: "/bin/ps",
            arguments: ["-ax", "-o", "command="]
        )
        return commands.split(whereSeparator: \.isNewline).contains {
            lineLooksLikeStoreInstaller(kind, String($0))
        }
    }

    /// Dedicated BottleVM prefix for a storefront, if registered.
    public static func dedicatedBottle(for kind: PlatformKind) -> Bottle? {
        guard let name = kind.dedicatedBottleName else { return nil }
        var data = BottleData()
        return data.loadBottles().first { $0.settings.name == name }
    }

    /// frankea DXVK-macOS `d3d11.dll` is ~3.8 MB; Wine wined3d is ~427 KB.
    public static func bottleHasDXVKNative(in bottle: Bottle) -> Bool {
        let dll = bottle.url
            .appending(path: "drive_c")
            .appending(path: "windows")
            .appending(path: "system32")
            .appending(path: "d3d11.dll")
        let size = (try? FileManager.default.attributesOfItem(
            atPath: dll.path(percentEncoded: false)
        )[.size] as? NSNumber)?.int64Value ?? 0
        return size > 1_000_000
    }

    /// DXMT copies `winemetal.dll` next to native d3d11. 32-bit Battle.net CEF
    /// loads syswow64. Not GPTK.
    public static func bottleHasDXMTNative(in bottle: Bottle) -> Bool {
        let windows = bottle.url.appending(path: "drive_c").appending(path: "windows")
        let wow = windows.appending(path: "syswow64").appending(path: "winemetal.dll")
        let x64 = windows.appending(path: "system32").appending(path: "winemetal.dll")
        let fm = FileManager.default
        return fm.fileExists(atPath: wow.path(percentEncoded: false))
            || fm.fileExists(atPath: x64.path(percentEncoded: false))
    }

    /// winedbg on this prefix, or GalaxyClient.exe still up without DXVK (installer child).
    public static func gogPrefixNeedsReset(in bottle: Bottle) -> Bool {
        if prefixHasWinedbg(in: bottle) { return true }
        let commands = captureProcessOutput(
            executable: "/bin/ps",
            arguments: ["-ax", "-o", "command="]
        )
        let hasClient = commands.split(whereSeparator: \.isNewline).contains {
            lineLooksLikeGOGClient(String($0))
        }
        return hasClient && !bottleHasDXVKNative(in: bottle)
    }

    /// Any Battle.net.exe (including leftover Round 3 / no-FLY4). `isRunning`
    /// is the healthy FLY4+DXMT session only.
    public static func battleNetClientIsUp() -> Bool {
        let commands = captureProcessOutput(
            executable: "/bin/ps",
            arguments: ["-ax", "-o", "command="]
        )
        return commands.split(whereSeparator: \.isNewline).contains {
            lineLooksLikeBattleNetClient(String($0))
        }
    }

    /// winedbg, leftover DXVK (no winemetal), leftover 13:45/14:05 Chromium
    /// flag guesses, Round 3 `--in-process-gpu`, or DXMT without FLY4.
    public static func battleNetPrefixNeedsReset(in bottle: Bottle) -> Bool {
        if prefixHasWinedbg(in: bottle) { return true }
        let commands = captureProcessOutput(
            executable: "/bin/ps",
            arguments: ["-ax", "-o", "command="]
        )
        let clientLines = commands.split(whereSeparator: \.isNewline).filter {
            lineLooksLikeBattleNetClient(String($0))
        }
        guard !clientLines.isEmpty else { return false }
        if !bottleHasDXMTNative(in: bottle) { return true }
        // 13:45/14:05 Chromium guesses. Round 3 `--in-process-gpu` blanked Qt.
        if clientLines.contains { battleNetLineHasGuessedCefFlags(String($0)) } {
            return true
        }
        let mains = clientLines.filter { !String($0).contains("--type=") }
        if mains.contains(where: { String($0).contains("--in-process-gpu") }) {
            return true
        }
        if !battleNetPresentHookLoaded() { return true }
        return !battleNetMacdrvExportLoaded()
    }

    /// True when frankea `macdrv_functions` is promoted to RTLD_GLOBAL
    /// (3Shain/dxmt#170) in Battle.net.exe.
    private static func battleNetMacdrvExportLoaded() -> Bool {
        return battleNetMainMaps(needle: "winemac_rtld_global")
    }

    /// True when the FLY4 dylib is mapped into Battle.net.exe (not Agent).
    private static func battleNetPresentHookLoaded() -> Bool {
        return battleNetMainMaps(needle: "fly_stretch_epi")
    }

    private static func battleNetMainMaps(needle: String) -> Bool {
        let ps = captureProcessOutput(
            executable: "/bin/ps",
            arguments: ["-axo", "pid=,command="]
        )
        for raw in ps.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            let lower = line.lowercased()
            guard lower.contains("battle.net.exe") else { continue }
            if lower.contains("agent.exe") { continue }
            if lower.contains("--type=") { continue }
            let pid = line.trimmingCharacters(in: .whitespaces).prefix(while: { $0.isNumber })
            guard !pid.isEmpty else { continue }
            let lsof = captureProcessOutput(
                executable: "/usr/sbin/lsof",
                arguments: ["-p", String(pid), "-Fn"]
            )
            if lsof.contains(needle) {
                return true
            }
        }
        return false
    }

    private static func isGOGRunningHealthy() -> Bool {
        let commands = captureProcessOutput(
            executable: "/bin/ps",
            arguments: ["-ax", "-o", "command="]
        )
        let hasClient = commands.split(whereSeparator: \.isNewline).contains {
            lineLooksLikeGOGClient(String($0))
        }
        guard hasClient else { return false }
        guard let bottle = dedicatedBottle(for: .gog) else { return true }
        return !gogPrefixNeedsReset(in: bottle)
    }

    private static func lineLooksLikeGOGClient(_ line: String) -> Bool {
        let lower = line.lowercased()
        if lower.contains("winedbg") { return false }
        if lineLooksLikeStoreInstaller(.gog, line) { return false }
        // GalaxyClientService.exe contains the substring "galaxyclient.exe".
        if lower.contains("galaxyclientservice") { return false }
        if lower.contains("galaxyclient helper") { return false }
        return lower.contains("galaxyclient.exe")
    }

    private static func lineLooksLikeStoreInstaller(_ kind: PlatformKind, _ line: String) -> Bool {
        let lower = line.lowercased()
        switch kind {
        case .gog:
            return lower.contains("gog_galaxy_2.0.exe")
                || lower.contains("galaxyinstaller.exe")
                || lower.contains("galaxysetup.exe")
                || lower.contains("galaxywebinstaller")
        default:
            return false
        }
    }

    private static func isBattleNetRunningHealthy() -> Bool {
        let commands = captureProcessOutput(
            executable: "/bin/ps",
            arguments: ["-ax", "-o", "command="]
        )
        let hasClient = commands.split(whereSeparator: \.isNewline).contains {
            lineLooksLikeBattleNetClient(String($0))
        }
        guard hasClient else { return false }
        guard let bottle = dedicatedBottle(for: .battlenet) else { return true }
        return !battleNetPrefixNeedsReset(in: bottle)
    }

    private static func lineLooksLikeBattleNetClient(_ line: String) -> Bool {
        let lower = line.lowercased()
        if lower.contains("winedbg") { return false }
        return lower.contains("battle.net.exe")
    }

    /// EA-copied / SwiftShader Chromium args from 13:45 and 14:05.
    private static func battleNetLineHasGuessedCefFlags(_ line: String) -> Bool {
        line.contains("--use-gl=swiftshader")
            || line.contains("--use-angle=swiftshader")
            || line.contains("--enable-unsafe-swiftshader")
            || line.contains("--disable-gpu-compositing")
    }

    /// Cheap `ps` for winedbg, then `ps eww -p` / lsof only on those PIDs (never `ps axeww`).
    private static func prefixHasWinedbg(in bottle: Bottle) -> Bool {
        let uuid = bottle.url.lastPathComponent
        let prefixes = Set([
            bottle.url.path(percentEncoded: false),
            bottle.url.path,
            bottle.url.resolvingSymlinksInPath().path(percentEncoded: false),
            bottle.url.resolvingSymlinksInPath().path
        ].filter { !$0.isEmpty })
        let ps = captureProcessOutput(
            executable: "/bin/ps",
            arguments: ["-ax", "-o", "pid=,command="]
        )
        for raw in ps.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard line.lowercased().contains("winedbg") else { continue }
            if line.contains(uuid) { return true }
            let pid = line.trimmingCharacters(in: .whitespaces).prefix(while: { $0.isNumber })
            guard !pid.isEmpty else { continue }
            let env = captureProcessOutput(
                executable: "/bin/ps",
                arguments: ["eww", "-p", String(pid)]
            )
            if prefixes.contains(where: { env.contains("WINEPREFIX=\($0)") }) {
                return true
            }
            if env.contains(uuid) { return true }
            let files = captureProcessOutput(
                executable: "/usr/sbin/lsof",
                arguments: ["-p", String(pid), "-Fn"]
            )
            if files.contains(uuid) { return true }
        }
        return false
    }

    public static func launch(_ item: InstalledPlatform) async throws {
        let bottle = item.bottle()
        switch item.kind {
        case .steam:
            // Game-host when Libraries/ is FOSS winecx + GPTK; else frankea (SteamLauncher gate).
            // Detach after spawn — without this the library overlay waits until steam.exe
            // exits, so Wyn keeps spinning after the header already says Logged On.
            var options = Wine.LaunchOptions()
            options.wineTree = .game
            options.preferGPTKSteam = true
            options.detachAfterStart = true
            try await SteamLauncher.launchSteam(in: bottle, options: options)
        case .ubisoft:
            try await ConnectLauncher.launch(in: bottle)
        case .rockstar:
            try await RockstarLauncher.launch(in: bottle)
        case .epic, .gog:
            try await HeroicLauncher.ensureAndOpen()
        case .ea, .battlenet:
            try await StorefrontLauncher.launch(kind: item.kind, in: bottle)
        }
    }

    /// Clone + other prefixes under `Bottles/`. Does not write BottleVM.plist.
    static func unregisteredBottleURLs(excluding steamURL: URL?) -> [URL] {
        let fm = FileManager.default
        let root = BottleData.defaultBottleDir
        var urls: [URL] = []
        let known = root.appending(path: knownRockstarBottleUUID)
        if fm.fileExists(atPath: known.path(percentEncoded: false)) {
            urls.append(known)
        }

        let steamResolved = steamURL?.resolvingSymlinksInPath().path(percentEncoded: false)
        let children = (try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for child in children {
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            if child.lastPathComponent == knownRockstarBottleUUID { continue }
            let resolved = child.resolvingSymlinksInPath().path(percentEncoded: false)
            if let steamResolved, resolved == steamResolved { continue }
            urls.append(child)
        }
        return urls
    }

    static func repoRootFromSource() -> URL {
        // Launchers/PlatformCatalog.swift → WynKit/Sources/WynKit → WynKit pkg → repo
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Where the native present/rtld helpers live.
    ///
    /// The app bundle's Resources come first, so an installed Wyn.app does not
    /// depend on a source checkout still being there. The source-relative and
    /// cwd paths follow for `swift run` out of a checkout.
    ///
    /// The old `~/Desktop/wyn` fallback is gone: CONTRIBUTING says not to
    /// require it, and it only ever worked on a machine whose checkout happened
    /// to be in that exact place.
    static func toolsBinURL() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []

        if let resources = Bundle.main.resourceURL {
            candidates.append(resources)
        }
        candidates.append(repoRootFromSource().appending(path: "Tools").appending(path: "bin"))
        candidates.append(
            URL(fileURLWithPath: fm.currentDirectoryPath)
                .appending(path: "Tools").appending(path: "bin")
        )

        // A directory only counts when it actually holds a helper — Resources
        // always exists, so testing the directory alone would match an app
        // bundle that ships none and stop the real search.
        return candidates.first { dir in
            fm.fileExists(
                atPath: dir.appending(path: "winemac_rtld_global.dylib").path(percentEncoded: false)
            )
        }
    }

    /// FLY4 epi + Cocoa inject. Same pair Connect and EA Play load.
    static func presentDylibs() -> (epi: URL, inject: URL)? {
        guard let bin = toolsBinURL() else { return nil }
        let fm = FileManager.default
        let epiCandidates = [
            bin.appending(path: "fly_stretch_epi_bridge.fast.dylib"),
            bin.appending(path: "fly_stretch_epi_bridge.optionb.dylib"),
            bin.appending(path: "fly_stretch_epi_bridge.dylib")
        ]
        let inject = bin.appending(path: "present_force_inject.dylib")
        guard let epi = epiCandidates.first(where: {
            fm.fileExists(atPath: $0.path(percentEncoded: false))
        }) else { return nil }
        guard fm.fileExists(atPath: inject.path(percentEncoded: false)) else { return nil }
        return (epi, inject)
    }

    /// 3Shain/dxmt#170: promote frankea `winemac.so` `macdrv_functions` to
    /// RTLD_GLOBAL so DXMT `dlsym(RTLD_DEFAULT)` can create a Metal view.
    /// Battle.net Play only — not inserted into EA / Connect.
    static func winemacRtldGlobalDylib() -> URL? {
        guard let bin = toolsBinURL() else { return nil }
        let url = bin.appending(path: "winemac_rtld_global.dylib")
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return nil
        }
        return url
    }

    static func captureProcessOutput(executable: String, arguments: [String]) -> String {
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
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func lineLooksLike(_ kind: PlatformKind, _ line: String) -> Bool {
        let lower = line.lowercased()
        switch kind {
        case .steam:
            if lower.contains("steamwebhelper") { return false }
            return lower.contains("\\steam\\steam.exe") || lower.contains("/steam/steam.exe")
        case .ubisoft:
            if lower.contains("uplaywebcore") { return false }
            return lower.contains("upc.exe")
        case .rockstar:
            return lower.contains("rockstar games") && lower.contains("launcher.exe")
        case .epic:
            // The Windows service starts a headless
            // `-Commandlet=selfupdateinstall -RanAsService` instance. That is
            // not the store UI — Play must still spawn EpicGamesLauncher.
            if lower.contains("commandlet=") || lower.contains("ranasservice") {
                return false
            }
            // Self-update extras stub (`UpdateInstall\Portal\Extras\Win64`)
            // also contains "portal" and R6025s — not the store.
            if lower.contains("updateinstall") { return false }
            if lower.contains("/extras/") || lower.contains("\\extras\\") {
                return false
            }
            // Program Files Portal\Binaries (or staged Update/Install\Portal\Binaries).
            return lower.contains("epicgameslauncher.exe")
                && lower.contains("portal")
                && lower.contains("binaries")
        case .ea:
            return lower.contains("eadesktop.exe") || lower.contains("\\origin\\origin.exe")
        case .battlenet:
            return lineLooksLikeBattleNetClient(line)
        case .gog:
            return lineLooksLikeGOGClient(line)
        }
    }
}
