//
//  LaunchDiagnostics.swift
//  WynKit
//

import Foundation
import CryptoKit

/// Preflight / postflight diagnostics for graphics backend failures.
public enum LaunchDiagnostics {
    public struct DLLProbe: Sendable {
        public let name: String
        public let path: String
        public let exists: Bool
        public let size: Int?
        public let sha256Prefix: String?
        public let peKind: String
        public let matchesRuntimeDXMT: Bool?
        public let matchesRuntimeDXVK: Bool?

        public var summaryLine: String {
            guard exists, let size else {
                return "  ❌ \(name) — MISSING at \(path)"
            }
            var tags: [String] = [peKind, "\(size) bytes"]
            if let matchesRuntimeDXMT {
                tags.append(matchesRuntimeDXMT ? "matches-DXMT" : "≠DXMT")
            }
            if let matchesRuntimeDXVK {
                tags.append(matchesRuntimeDXVK ? "matches-DXVK" : "≠DXVK")
            }
            if let sha256Prefix {
                tags.append("sha256=\(sha256Prefix)…")
            }
            return "  \(exists ? "✅" : "❌") \(name) — \(tags.joined(separator: ", "))"
        }
    }

    public struct Report: Sendable {
        public let lines: [String]

        public var rendered: String {
            lines.joined(separator: "\n")
        }
    }

    public static let graphicsDLLNames = [
        "d3d11.dll", "dxgi.dll", "d3d10core.dll", "d3d9.dll", "winemetal.dll",
        "nvapi64.dll", "nvngx.dll"
    ]

    /// Declared layer from bottle settings only (legacy `dxvk=true` sticky flag included).
    /// Does not read unix `d3d*.so` pointers.
    public static func requestedLayer(for bottle: Bottle) -> (layer: TranslationLayer, reason: String) {
        if bottle.settings.dxvk && bottle.settings.translationLayer != .dxvk {
            return (.dxvk, "legacy dxvk=true sticky flag overrides translationLayer=\(bottle.settings.translationLayer.rawValue)")
        }
        if bottle.settings.translationLayer == .dxvk || bottle.settings.dxvk {
            return (.dxvk, "translationLayer=dxvk or dxvk=true")
        }
        return (bottle.settings.translationLayer, "translationLayer=\(bottle.settings.translationLayer.rawValue)")
    }

    /// Resolve the graphics layer Wyn will actually activate for this bottle.
    /// Compares declared settings with the shared Libraries unix wiring; the
    /// filesystem wins when they disagree.
    public static func effectiveLayer(for bottle: Bottle) -> (layer: TranslationLayer, reason: String) {
        let requested = requestedLayer(for: bottle)
        // Sticky DXVK flag stays settings-only — do not reinterpret via unix modules.
        if bottle.settings.dxvk && bottle.settings.translationLayer != .dxvk {
            return requested
        }
        if bottle.settings.translationLayer == .dxvk || bottle.settings.dxvk {
            return requested
        }
        return resolveEffectiveLayer(
            declared: requested.layer,
            snapshot: RendererWiring.inspect(),
            gptkInstalled: GPTKInstaller.isInstalled()
        )
    }

    static func resolveEffectiveLayer(
        declared: TranslationLayer,
        snapshot: RendererWiring.Snapshot,
        gptkInstalled: Bool
    ) -> (layer: TranslationLayer, reason: String) {
        let settingsReason = "translationLayer=\(declared.rawValue)"
        switch declared {
        case .dxvk:
            return (.dxvk, settingsReason)
        case .dxmt:
            if snapshot.backend == .d3dMetal,
               let mismatch = RendererWiring.mismatchReason(declared: .dxmt, snapshot: snapshot) {
                return (.d3dMetal, mismatch)
            }
            if snapshot.backend == .mixed,
               let mismatch = RendererWiring.mismatchReason(declared: .dxmt, snapshot: snapshot) {
                return (.dxmt, mismatch)
            }
            return (.dxmt, settingsReason)
        case .d3dMetal:
            if snapshot.backend == .d3dMetal {
                return (.d3dMetal, settingsReason)
            }
            if !gptkInstalled {
                return (.d3dMetal, settingsReason)
            }
            if let mismatch = RendererWiring.mismatchReason(declared: .d3dMetal, snapshot: snapshot) {
                let wired: TranslationLayer = snapshot.backend == .wineNative ? .dxmt : declared
                return (wired, mismatch)
            }
            return (.d3dMetal, settingsReason)
        }
    }

    public static func inspect(
        bottle: Bottle,
        profile: GameProfile? = nil,
        executable: URL? = nil,
        environment: [String: String] = [:],
        phase: String = "preflight"
    ) -> Report {
        var lines: [String] = []
        lines.append("════════════════════════════════════════════════════════════")
        lines.append("FLY LAUNCH DIAGNOSTICS — \(phase)")
        lines.append("════════════════════════════════════════════════════════════")
        lines.append("Time: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")

        // Runtime
        lines.append("── Runtime ──")
        let runtimeInstalled = WynWineInstaller.isWynWineInstalled()
        lines.append("  Installed: \(runtimeInstalled ? "yes" : "NO")")
        if let version = WynWineInstaller.wynWineVersion() {
            lines.append("  Version:   \(version.major).\(version.minor).\(version.patch)")
        }
        lines.append("  Source:    \(RuntimeManager.activeSource.displayName)")
        lines.append("  Libraries: \(WynWineInstaller.libraryFolder.path)")
        lines.append("  wine64:    \(Wine.wineBinary.path) (\(exists(Wine.wineBinary) ? "present" : "MISSING"))")
        let steamWine = Wine.wineBinary(for: .steam)
        lines.append("  Steam Wine:\(WynWineInstaller.steamLibraryFolder.path)")
        lines.append("  steam64:  \(steamWine.path) (\(exists(steamWine) ? "present" : "MISSING"))")

        let dxmtRoot = WynWineInstaller.libraryFolder.appending(path: "DXMT")
        let dxvkRoot = WynWineInstaller.libraryFolder.appending(path: "DXVK")
        lines.append("  DXMT dir:  \(exists(dxmtRoot) ? "present" : "MISSING") — native payload: \(Wine.isDXMTRuntimeNative() ? "yes" : "NO")")
        lines.append("  DXVK dir:  \(exists(dxvkRoot) ? "present" : "MISSING")")
        lines.append("")

        // Bottle
        lines.append("── Bottle ──")
        lines.append("  Name:              \(bottle.settings.name)")
        lines.append("  Path:              \(bottle.url.path)")
        lines.append("  Windows:           \(bottle.settings.windowsVersion.rawValue)")
        lines.append("  Sync:              \(bottle.settings.enhancedSync.rawValue)")
        lines.append("  AVX:               \(bottle.settings.avxEnabled)")
        lines.append("  translationLayer:  \(bottle.settings.translationLayer.rawValue) (\(bottle.settings.translationLayer.displayName))")
        lines.append("  dxvk flag:         \(bottle.settings.dxvk)")
        let declared = bottle.settings.translationLayer
        let renderer = RendererWiring.inspect()
        let effective = effectiveLayer(for: bottle)
        lines.append("  EFFECTIVE layer:   \(effective.layer.rawValue) — \(effective.reason)")
        lines.append("── Renderer (shared unix modules) ──")
        for line in renderer.statusLines {
            lines.append("  \(line)")
        }
        if declared == .d3dMetal || effective.layer == .d3dMetal {
            if GPTKInstaller.isInstalled() {
                lines.append("  GPTK/D3DMetal files: \(GPTKInstaller.externalFolder.path(percentEncoded: false))")
            } else {
                lines.append("  ⚠️  D3DMetal selected but GPTK is not installed. Run: wyn gptk install")
                lines.append("     Without GPTK, Wine falls back to wined3d / broken D3D11.")
            }
        }
        if (declared == .dxmt || declared == .dxvk), renderer.backend == .d3dMetal {
            lines.append("  ⚠️  \(declared.rawValue) declared but Libraries d3d11.so -> libd3dshared (D3DMetal).")
            lines.append("     run: wyn renderer set \(declared.rawValue)")
        }
        if declared == .d3dMetal, renderer.backend != .d3dMetal, GPTKInstaller.isInstalled() {
            lines.append("  ⚠️  D3DMetal declared but unix modules are not libd3dshared.")
            lines.append("     run: wyn renderer set d3dmetal")
        }
        lines.append("")

        // Profile
        if let profile {
            lines.append("── Profile ──")
            lines.append("  ID:        \(profile.id)")
            lines.append("  Name:      \(profile.name)")
            lines.append("  Steam ID:  \(profile.steamAppId.map(String.init) ?? "—")")
            lines.append("  Layer:     \(profile.bottle?.translationLayer?.rawValue ?? "—")")
            lines.append("  Winetricks:\(profile.winetricks.isEmpty ? " (none)" : " \(profile.winetricks.joined(separator: ", "))")")
            if !profile.environment.isEmpty {
                lines.append("  Env:")
                for key in profile.environment.keys.sorted() {
                    lines.append("    \(key)=\(profile.environment[key] ?? "")")
                }
            }
            lines.append("")
        }

        // Executable
        if let executable {
            lines.append("── Executable ──")
            lines.append("  Path:   \(executable.path(percentEncoded: false))")
            lines.append("  Exists: \(exists(executable) ? "yes" : "NO")")
            if exists(executable), let attrs = try? FileManager.default.attributesOfItem(atPath: executable.path),
               let size = attrs[.size] as? NSNumber {
                lines.append("  Size:   \(size.intValue) bytes")
            }
            lines.append("")
        }

        // Bottle system32 / syswow64 graphics DLLs
        let system32 = bottle.url
            .appending(path: "drive_c")
            .appending(path: "windows")
            .appending(path: "system32")
        lines.append("── Bottle system32 graphics DLLs ──")
        for name in graphicsDLLNames {
            let probe = probeDLL(
                name: name,
                at: system32.appending(path: name),
                dxmtRoot: dxmtRoot.appending(path: "x64"),
                dxvkRoot: dxvkRoot.appending(path: "x64")
            )
            lines.append(probe.summaryLine)
        }
        lines.append("")

        // What deploy should do
        lines.append("── Deploy plan ──")
        switch effective.layer {
        case .dxmt:
            lines.append("  Will call enableDXMT() → copy DXMT/{x64,x32}/{d3d11,dxgi,d3d10core,winemetal}.dll")
            if !Wine.isDXMTRuntimeNative() {
                lines.append("  ❌ DXMT payload missing/non-native — enableDXMT will THROW")
            }
        case .dxvk:
            lines.append("  Will call enableDXVK() → replace system DLLs from DXVK/{x64,x32}")
            if !exists(dxvkRoot.appending(path: "x64")) {
                lines.append("  ❌ DXVK x64 folder missing")
            }
        case .d3dMetal:
            lines.append("  D3DMetal selected — GPTK must be installed locally (not in CDN tarball).")
            let external = GPTKInstaller.d3dMetalFrameworkURL
            let libd3d = GPTKInstaller.libd3dsharedURL
            lines.append("  D3DMetal.framework: \(exists(external) ? "present" : "MISSING")")
            lines.append("  libd3dshared.dylib: \(exists(libd3d) ? "present" : "MISSING")")
            lines.append("  GPTK wired: \(GPTKInstaller.isInstalled() ? "yes" : "NO — run: wyn gptk install")")
            lines.append("  MetalFX/nvngx: \(GPTKInstaller.isMetalFXWired() ? "yes" : "NO — re-run: wyn gptk install")")
            if GPTKInstaller.isMetalFXWired() {
                lines.append("  nvngx.dll: \(GPTKInstaller.nvngxDLLURL.path(percentEncoded: false))")
            }
            if !GPTKInstaller.isInstalled(), let hint = GPTKInstaller.findLocalSource() {
                lines.append("  Auto-source candidate: \(hint.path(percentEncoded: false))")
            }
        }
        lines.append("")

        // Environment
        lines.append("── Launch environment (merged) ──")
        if environment.isEmpty {
            lines.append("  (empty — bottle defaults only)")
        } else {
            for key in environment.keys.sorted() {
                lines.append("  \(key)=\(environment[key] ?? "")")
            }
        }

        var bottleEnv: [String: String] = [:]
        bottle.settings.environmentVariables(wineEnv: &bottleEnv)
        lines.append("")
        lines.append("── Bottle settings → env overrides ──")
        for key in bottleEnv.keys.sorted() {
            lines.append("  \(key)=\(bottleEnv[key] ?? "")")
        }

        let finalOverrides = environment["WINEDLLOVERRIDES"]
            ?? bottleEnv["WINEDLLOVERRIDES"]
            ?? "(none)"
        lines.append("")
        lines.append("── Verdict ──")
        lines.append("  WINEDLLOVERRIDES (launch wins over bottle): \(finalOverrides)")
        lines.append("  Expected for \(effective.layer.rawValue): \(effective.layer.environmentOverrides().values.first ?? "(none)")")

        if effective.layer == .dxmt || effective.layer == .dxvk {
            let d3d11 = probeDLL(
                name: "d3d11.dll",
                at: system32.appending(path: "d3d11.dll"),
                dxmtRoot: dxmtRoot.appending(path: "x64"),
                dxvkRoot: dxvkRoot.appending(path: "x64")
            )
            if effective.layer == .dxmt, d3d11.matchesRuntimeDXMT != true {
                lines.append("  ❌ system32/d3d11.dll does NOT match DXMT payload — D3D11 will fail or use wrong backend")
            }
            if effective.layer == .dxvk, d3d11.matchesRuntimeDXVK != true {
                lines.append("  ❌ system32/d3d11.dll does NOT match DXVK payload yet (deploy should fix this)")
            }
            if d3d11.matchesRuntimeDXMT == true && d3d11.matchesRuntimeDXVK == true {
                lines.append("  ⚠️  Ambiguous: d3d11 matches both? check sizes")
            }
        }

        lines.append("════════════════════════════════════════════════════════════")
        return Report(lines: lines)
    }

    public static func probeDLL(
        name: String,
        at url: URL,
        dxmtRoot: URL,
        dxvkRoot: URL
    ) -> DLLProbe {
        let path = url.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else {
            return DLLProbe(
                name: name, path: path, exists: false, size: nil,
                sha256Prefix: nil, peKind: "missing",
                matchesRuntimeDXMT: nil, matchesRuntimeDXVK: nil
            )
        }

        let data = (try? Data(contentsOf: url)) ?? Data()
        let size = data.count
        let peKind = peKindDescription(data)
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let prefix = String(hex.prefix(12))

        let dxmtURL = dxmtRoot.appending(path: name)
        let dxvkURL = dxvkRoot.appending(path: name)
        let matchesDXMT = fileExists(dxmtURL) ? filesEqual(url, dxmtURL) : nil
        let matchesDXVK = fileExists(dxvkURL) ? filesEqual(url, dxvkURL) : nil

        return DLLProbe(
            name: name, path: path, exists: true, size: size,
            sha256Prefix: prefix, peKind: peKind,
            matchesRuntimeDXMT: matchesDXMT, matchesRuntimeDXVK: matchesDXVK
        )
    }

    public static func debugEnvironmentOverrides() -> [String: String] {
        [
            // Useful without drowning chat: DLL loads + real errors.
            // Avoid warn+all / +seh — UE probes missing optional .ini files and Wine
            // dumps thousands of NtQueryAttributesFile "not found" lines.
            // Do not force MTL_HUD here — it can interfere with UE/DXMT and floods output.
            "WINEDEBUG": "+loaddll,err+all,fixme-all",
            "DXVK_LOG_LEVEL": "info",
            "DXMT_DEBUG": "1",
            "GST_DEBUG": "1"
        ]
    }

    // MARK: - Auth / launch signal (always-on; not MoltenVK spam)

    /// Compact pre/post launch report for SteamAPI→EOS debugging.
    /// Prints wineserver tree, Logged On + SteamID, FactoryGame.log path/mtime,
    /// and SteamAPI/RHI one-liners — never MoltenVK extension dumps.
    public static func authSignalReport(
        bottle: Bottle,
        profile: GameProfile? = nil,
        wineTree: WineTree? = nil,
        layer: TranslationLayer? = nil,
        wineExitStatus: Int32? = nil,
        phase: String = "preflight"
    ) -> Report {
        var lines: [String] = []
        lines.append("── fly auth-signal (\(phase)) ──")

        // Wineserver tree
        lines.append(contentsOf: wineserverTreeLines(bottle: bottle))

        // Steam Logged On + SteamID
        let login = steamLoginSnapshot(bottle: bottle)
        lines.append("Steam: \(login.summary)")
        if SteamLauncher.isSteamClientRunning(in: bottle) {
            let tree: String
            if SteamLauncher.isBottleWineserverFromTree(in: bottle, tree: .steam) {
                tree = "frankea (~930)"
            } else if SteamLauncher.isBottleWineserverFromTree(in: bottle, tree: .game) {
                tree = "GPTK (~1809)"
            } else {
                tree = "unknown tree"
            }
            lines.append("Steam wineserver: \(tree)")
        } else {
            lines.append("Steam wineserver: (no steam.exe for this bottle)")
        }

        if let wineTree {
            lines.append("Launch Wine tree: \(wineTree.displayName)")
        }
        if let layer {
            lines.append("Graphics layer: \(layer.displayName)")
        }
        if let wineExitStatus {
            lines.append("wine start exit: \(wineExitStatus)\(wineExitStatus == 0 ? "" : " ← non-zero")")
        }

        // FactoryGame.log path + mtime + SteamAPI/RHI greps
        let logHits = factoryGameLogHits(bottle: bottle, projectHint: profile?.unrealProject)
        lines.append(contentsOf: logHits)

        lines.append("────────────────────────────")
        return Report(lines: lines)
    }

    public static func printAuthSignal(
        bottle: Bottle,
        profile: GameProfile? = nil,
        wineTree: WineTree? = nil,
        layer: TranslationLayer? = nil,
        wineExitStatus: Int32? = nil,
        phase: String = "preflight"
    ) {
        let report = authSignalReport(
            bottle: bottle,
            profile: profile,
            wineTree: wineTree,
            layer: layer,
            wineExitStatus: wineExitStatus,
            phase: phase
        )
        print(report.rendered)
        fflush(stdout)
    }

    /// Last Steam connection-log login state line + parsed SteamID.
    /// When `baseline` is set, Logged On only counts if the last state line changed
    /// (avoids stale frankea `[Logged On]` after wineserver kill/migrate).
    public static func steamLoginSnapshot(
        bottle: Bottle,
        baseline: SteamLauncher.ConnectionLogFingerprint? = nil
    ) -> (loggedOn: Bool, steamID: String?, summary: String) {
        let log = bottle.url
            .appending(path: "drive_c")
            .appending(path: "Program Files (x86)")
            .appending(path: "Steam")
            .appending(path: "logs")
            .appending(path: "connection_log.txt")
        guard let text = try? String(contentsOf: log, encoding: .utf8), !text.isEmpty else {
            return (false, nil, "connection_log missing → treat as Logged Off")
        }
        var lastState: String?
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            if line.contains("[Logged On") || line.contains("[Logged Off")
                || line.contains("[Logging On") || line.contains("[Connecting")
            {
                lastState = line
            }
        }
        guard let state = lastState else {
            return (false, nil, "no Logged On/Off line in connection_log")
        }
        let idMatch = state.range(of: #"\[U:1:[0-9]+\]"#, options: .regularExpression)
        let steamID = idMatch.map { String(state[$0]) }
        let contentLoggedOn = state.contains("[Logged On")
            && (steamID.map { !$0.contains("[U:1:0]") } ?? false)
        let short = state.trimmingCharacters(in: .whitespaces)
        let clipped = short.count > 120 ? String(short.prefix(117)) + "…" : short

        if let baseline {
            let freshLine = baseline.lastStateLine.map { $0 != state } ?? true
            if contentLoggedOn, !freshLine {
                return (false, steamID, "STALE Logged On (pre-restart line) \(steamID ?? "")")
            }
            if contentLoggedOn, freshLine {
                return (true, steamID, "Logged On \(steamID ?? "") (fresh)")
            }
            return (false, steamID, "NOT Logged On — \(clipped)")
        }

        if contentLoggedOn {
            return (true, steamID, "Logged On \(steamID ?? "")")
        }
        return (false, steamID, "NOT Logged On — \(clipped)")
    }

    private static func wineserverTreeLines(bottle: Bottle) -> [String] {
        var out = ["Wineserver:"]
        let prefixes = bottleWINEPREFIXCandidates(for: bottle)
        let pidsText = runCapture("/usr/bin/pgrep", ["-x", "wineserver"])
        let pids = pidsText.split(whereSeparator: \.isNewline).compactMap {
            Int($0.trimmingCharacters(in: .whitespaces))
        }
        if pids.isEmpty {
            out.append("  (none running)")
            return out
        }

        var matched = 0
        for pid in pids {
            let envLine = runCapture("/bin/ps", ["eww", "-p", "\(pid)"])
            let forBottle = prefixes.contains { envLine.contains("WINEPREFIX=\($0)") || envLine.contains($0) }
            let cmd = runCapture("/bin/ps", ["-p", "\(pid)", "-o", "command="])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let treeLabel = classifyWineserverCommand(cmd)
            let mark = forBottle ? "★ bottle" : "  other "
            if forBottle { matched += 1 }
            let shortCmd: String
            if let range = cmd.range(of: "wineserver", options: [.caseInsensitive, .backwards]) {
                let path = String(cmd[..<range.upperBound])
                shortCmd = path.count > 90 ? "…" + String(path.suffix(87)) : path
            } else {
                shortCmd = String(cmd.prefix(90))
            }
            out.append("  \(mark) pid=\(pid) \(treeLabel)  \(shortCmd)")
        }
        if matched == 0 {
            out.append("  ⚠️ no wineserver matched this bottle's WINEPREFIX")
        }
        return out
    }

    private static func classifyWineserverCommand(_ cmd: String) -> String {
        let lower = cmd.lowercased()
        if lower.contains("/libraries.steam/") || lower.contains("/libraries.pre-gptk") {
            return "frankea(~930)"
        }
        if lower.contains("/com.fly.gaming/libraries/") || lower.contains("/libraries/wine/") {
            return "GPTK(~1809)"
        }
        if lower.contains("crossover") {
            return "other-wine-app"
        }
        return "unknown"
    }

    private static func bottleWINEPREFIXCandidates(for bottle: Bottle) -> [String] {
        var out: [String] = [bottle.url.path]
        let resolved = bottle.url.resolvingSymlinksInPath().path
        if resolved != bottle.url.path { out.append(resolved) }
        // ps eww may truncate; match on unique bottle UUID fragment when present.
        let name = bottle.url.lastPathComponent
        if name.count >= 8 { out.append(name) }
        return out
    }

    private static func factoryGameLogHits(bottle: Bottle, projectHint: String?) -> [String] {
        var out: [String] = []
        let project = projectHint ?? "FactoryGame"
        let usersRoot = bottle.url.appending(path: "drive_c").appending(path: "users")
        let fm = FileManager.default
        var candidates: [URL] = []
        if let users = try? fm.contentsOfDirectory(
            at: usersRoot, includingPropertiesForKeys: nil
        ) {
            for user in users {
                let log = user
                    .appending(path: "AppData")
                    .appending(path: "Local")
                    .appending(path: project)
                    .appending(path: "Saved")
                    .appending(path: "Logs")
                    .appending(path: "\(project).log")
                if fm.fileExists(atPath: log.path(percentEncoded: false)) {
                    candidates.append(log)
                }
            }
        }

        if candidates.isEmpty {
            out.append("FactoryGame.log: (not found under users/*/AppData/Local/\(project)/Saved/Logs/)")
            return out
        }

        let sorted = candidates.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            return da > db
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.timeZone = TimeZone.current

        for url in sorted.prefix(2) {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            let mtimeStr = mtime.map { formatter.string(from: $0) } ?? "?"
            let user: String
            if let idx = url.pathComponents.firstIndex(of: "users"),
               idx + 1 < url.pathComponents.count {
                user = url.pathComponents[idx + 1]
            } else {
                user = "?"
            }
            out.append("FactoryGame.log: users/\(user) mtime=\(mtimeStr)")
            out.append("  \(url.path(percentEncoded: false))")
            out.append(contentsOf: grepAuthRHILines(in: url).map { "  · \($0)" })
        }
        return out
    }

    /// One-liners that matter for SteamAPI / RHI — never MoltenVK extension lists.
    private static func grepAuthRHILines(in log: URL) -> [String] {
        guard let text = try? String(contentsOf: log, encoding: .utf8), !text.isEmpty else {
            return ["(empty log)"]
        }
        let needles = [
            "SteamAPI",
            "SteamAPI_Init",
            "failed to initialize",
            "Login Timeout",
            "Not Connected to Platform",
            "OnlineSubsystem",
            "GetAuthTicket",
            "EOS",
            "LogRHI:",
            "Forced RHI",
            "Critical error",
            "Fatal error",
            "EXCEPTION_ACCESS",
            "GetSelectedDynamicRHIModuleName",
            "NGXVulkanRHIPreInit",
            "SafeCreateDXGIFactory",
            "gameoverlayrenderer",
            "No adapters",
            "Feature Level",
            "D3D11-compatible GPU",
            "Shader Model 5",
            "GeForce 6800",
            "D3DM",
            "dxgi.dll",
            "Apple M4",
            "DXVK:",
        ]
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        var hits: [String] = []
        var seen = Set<String>()
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard needles.contains(where: { trimmed.contains($0) }) else { continue }
            // Dedupe near-identical callstack spam — keep first of each unique prefix.
            let key = String(trimmed.prefix(90))
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            let clipped = trimmed.count > 140 ? String(trimmed.prefix(137)) + "…" : trimmed
            // DXVK-macOS may advertise GeForce 6800 while still offering FL11/SM5 — not the FL11 dialog.
            let annotated: String
            if trimmed.contains("GeForce 6800"),
               !trimmed.localizedCaseInsensitiveContains("required to run"),
               !trimmed.localizedCaseInsensitiveContains("not supported on your system")
            {
                annotated = clipped + "  ← name only; OK if SM5/FL11 chosen"
            } else if trimmed.localizedCaseInsensitiveContains("D3D11-compatible GPU")
                || trimmed.localizedCaseInsensitiveContains("required to run the engine")
            {
                annotated = clipped + "  ← real FL11 failure (wined3d)"
            } else {
                annotated = clipped
            }
            hits.append(annotated)
            if hits.count >= 10 { break }
        }
        if hits.isEmpty {
            return ["(no SteamAPI/RHI/fatal lines yet)"]
        }
        return hits.reversed()
    }

    private static func runCapture(_ executable: String, _ arguments: [String]) -> String {
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

    /// Drop known-noise Wine lines so `--debug` output stays shareable.
    public static func shouldEchoWineLine(_ line: String) -> Bool {
        let noise: [String] = [
            "NtQueryAttributesFile",
            "not found (c000003a)",
            "RtlCaptureStackBackTrace",
            "trace:seh:",
            "fixme:appbar:",
            "fixme:dwmapi:",
            "SHAppBarMessage",
            "attribute 14 not implemented",
            "[mvk-info]",
            "VK_KHR_",
            "VK_EXT_",
            "VK_AMD_",
            "VK_MVK_",
            "VK_NV_",
            "VK_GOOGLE_",
            "VK_IMG_",
            "VK_INTEL_",
            "The following ",
            "Vulkan extensions",
        ]
        if noise.contains(where: { line.contains($0) }) {
            return false
        }

        // loaddll: only keep graphics / game / Steam lines (skip kernel32 spam).
        if line.contains("trace:loaddll:") {
            let interesting = [
                "d3d11", "d3d10", "d3d12", "d3d9", "dxgi", "winemetal",
                "steam", "Ride", "FactoryGame", "vulkan", "dxvk", "dxmt",
                "wined3d", "opengl32",
                ": native", ": builtin",
            ]
            return interesting.contains { line.localizedCaseInsensitiveContains($0) }
        }

        // Always keep DXVK/Steam UI / D3DMetal failure lines even if other filters expand later.
        let keepAlways = [
            "Failed to initialize DXVK",
            "No adapters found",
            "geometryShader",
            "GPU process exited",
            "WaitingForCredentials",
            "D3DM",
            "libd3dshared",
            "D3DMetal",
            "Feature Level 11",
            "CX_APPLEGPTK",
            "version mismatch",
            "wine client error",
            "wrong wineserver",
        ]
        if keepAlways.contains(where: { line.contains($0) }) {
            return true
        }

        return true
    }

    // MARK: - Private

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    private static func fileExists(_ url: URL) -> Bool { exists(url) }

    private static func filesEqual(_ a: URL, _ b: URL) -> Bool {
        guard let da = try? Data(contentsOf: a), let db = try? Data(contentsOf: b) else { return false }
        return da == db
    }

    private static func peKindDescription(_ data: Data) -> String {
        guard data.count > 0x50 else { return "too-small" }
        let marker = data.subdata(in: 0x40 ..< 0x50)
        if marker == Data("Wine builtin DLL".utf8) {
            return "Wine-builtin"
        }
        return "native-PE"
    }
}
