//
//  ConnectLauncher.swift
//  WynKit
//
//  Ubisoft Connect on frankea Wine + FLY4 present. Never GPTK — that is the
//  transparent window. Do not wineserver -k a Logged-On GPTK Steam session.
//

import Darwin
import Foundation

public enum ConnectLauncher {
    private static let connectDllOverrides =
        "winemenubuilder.exe=d;dwrite=b;d2d1,d3d10core=d;d3d11,dxgi=b;d3dcompiler_47=n"

    private static let cefArgs = [
        "--no-sandbox",
        "--in-process-gpu",
        "--disable-gpu-compositing",
        "--use-gl=angle",
        "--use-angle=swiftshader-webgl"
    ]

    private static let attempts = 6
    private static let startViewTimeoutSeconds = 40
    private static let startViewGraceSeconds = 10

    private static let spawned = SpawnedProcesses()

    public static func installDirectory(in bottle: Bottle) -> URL {
        bottle.url
            .appending(path: "drive_c")
            .appending(path: "Program Files (x86)")
            .appending(path: "Ubisoft")
            .appending(path: "Ubisoft Game Launcher")
    }

    public static func exeURL(in bottle: Bottle) -> URL {
        installDirectory(in: bottle).appending(path: "upc.exe")
    }

    public static func launch(in bottle: Bottle) async throws {
        let fm = FileManager.default
        let exe = exeURL(in: bottle)
        guard fm.fileExists(atPath: exe.path(percentEncoded: false)) else {
            throw PlatformLaunchError.executableMissing(.ubisoft)
        }
        guard WynWineInstaller.isWineInstalled(for: .steam) else {
            throw PlatformLaunchError.wineTreeMissing(.steam)
        }
        guard presentDylibs() != nil else {
            throw PlatformLaunchError.presentDylibsMissing
        }

        if SteamLauncher.isBottleWineserverFromTree(in: bottle, tree: .game) {
            throw PlatformLaunchError.connectOnGPTK
        }
        if PlatformCatalog.isRunning(.ubisoft) {
            return
        }

        let frankeaUp = SteamLauncher.isBottleWineserverFromTree(in: bottle, tree: .steam)
        if frankeaUp {
            try prepareConnectFiles(in: bottle)
            unlinkFLY4()
            restoreHTTP2(in: bottle)
            try spawnConnect(in: bottle)
            return
        }

        if SteamLauncher.isBottleWineserverRunning(in: bottle) {
            throw PlatformLaunchError.unexpectedWineserver
        }

        var lastError: Error = PlatformLaunchError.connectWedged
        for attempt in 1...attempts {
            try Task.checkCancellation()
            if attempt > 1 {
                LaunchProgress.emit("Ubisoft Connect: retry \(attempt)/\(attempts)…")
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } else {
                LaunchProgress.emit("Ubisoft Connect: waiting for StartView…")
            }
            do {
                try await coldStartAttempt(in: bottle)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                await drainConnect(in: bottle)
            }
        }
        throw lastError
    }

    private static func coldStartAttempt(in bottle: Bottle) async throws {
        await drainConnect(in: bottle)
        try prepareConnectFiles(in: bottle)
        unlinkFLY4()
        restoreHTTP2(in: bottle)

        let logURL = installDirectory(in: bottle)
            .appending(path: "logs")
            .appending(path: "launcher_log.txt")
        let offset = (try? FileManager.default.attributesOfItem(
            atPath: logURL.path(percentEncoded: false)
        )[.size] as? NSNumber)?.intValue ?? 0

        try spawnConnect(in: bottle)
        try await waitForStartView(logURL: logURL, offset: offset)
    }

    private static func spawnConnect(in bottle: Bottle) throws {
        guard let dylibs = presentDylibs() else {
            throw PlatformLaunchError.presentDylibsMissing
        }
        let wine = Wine.wineBinary(for: .steam).path(percentEncoded: false)
        let prefix = bottle.url.path(percentEncoded: false)
        let uc = installDirectory(in: bottle)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let outDir = Wine.logsFolder.appending(path: "present-connect-\(stamp)")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let logURL = outDir.appending(path: "wine.log")
        FileManager.default.createFile(atPath: logURL.path(percentEncoded: false), contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)

        var assignments = [
            "DYLD_INSERT_LIBRARIES=\(dylibs.epi.path(percentEncoded: false)):\(dylibs.inject.path(percentEncoded: false))",
            "WINEPREFIX=\(prefix)",
            "WINEESYNC=1",
            "WINE_SIMULATE_WRITECOPY=1",
            "WINEDLLOVERRIDES=\(connectDllOverrides)",
            "WINEDEBUG=-all",
            "FLY_FAST_PRESENT=1",
            "FLY_PARENT_PRESENT=1",
            "FLY_BRIDGE_SHM=0",
            "FLY_BRIDGE_FILE=0",
            "FLY_OPTION_B=0",
            "FLY_SURFACE_MAP=0",
            "PRESENT_FORCE_LOGIN_BRIDGE=0",
            "PRESENT_FORCE_OPAQUE=0",
            "PRESENT_FORCE_LOGIN_FILL=0",
            "PRESENT_FORCE_LOGIN_SYNC=0",
            "FLY_STRETCH_DUMP=1",
            "STRETCHBLT_SPY_LOG=\(outDir.appending(path: "spy.log").path(percentEncoded: false))",
            "PRESENT_FORCE_LOG=\(outDir.appending(path: "inject.log").path(percentEncoded: false))"
        ]
        assignments.append("PRESENT_BRIDGE_BGRA=\(prefix)/drive_c/windows/temp/fly-stretch-bridge.bgra")

        var args = ["-x86_64", "env"]
        args.append(contentsOf: assignments)
        args.append(wine)
        args.append("upc.exe")
        args.append(contentsOf: cefArgs)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        process.arguments = args
        process.currentDirectoryURL = uc
        process.environment = scrubbedMacEnvironment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.qualityOfService = .userInitiated
        try process.run()
        spawned.retain(process)
    }

    private static func waitForStartView(logURL: URL, offset: Int) async throws {
        var cefAt: Int?
        for second in 1...startViewTimeoutSeconds {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let chunk = logTail(logURL, offset: offset)
            if chunk.contains("StartView.cpp") {
                return
            }
            if cefAt == nil, chunk.contains("Using CEF with native rendering") {
                cefAt = second
            } else if let cefAt, second - cefAt >= startViewGraceSeconds {
                throw PlatformLaunchError.connectWedged
            }
            if !PlatformCatalog.isRunning(.ubisoft) && second > 3 {
                throw PlatformLaunchError.connectWedged
            }
        }
        throw PlatformLaunchError.connectWedged
    }

    private static func logTail(_ url: URL, offset: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let start = UInt64(max(0, offset))
        do {
            try handle.seek(toOffset: start)
            let data = handle.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    private static func drainConnect(in bottle: Bottle) async {
        let wineserver = Process()
        wineserver.executableURL = Wine.wineserverBinary(for: .steam)
        wineserver.arguments = ["-k"]
        wineserver.environment = ["WINEPREFIX": bottle.url.path(percentEncoded: false)]
        wineserver.standardOutput = FileHandle.nullDevice
        wineserver.standardError = FileHandle.nullDevice
        _ = try? wineserver.run()
        wineserver.waitUntilExit()

        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-f", #"upc\.exe|UplayWebCore\.exe|UplayService\.exe"#]
        pkill.standardOutput = FileHandle.nullDevice
        pkill.standardError = FileHandle.nullDevice
        _ = try? pkill.run()
        pkill.waitUntilExit()

        for _ in 0..<40 {
            if !PlatformCatalog.isRunning(.ubisoft) { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        try? await Task.sleep(nanoseconds: 800_000_000)
    }

    private static func prepareConnectFiles(in bottle: Bottle) throws {
        let fm = FileManager.default
        let uc = installDirectory(in: bottle)
        let real = uc.appending(path: "UplayWebCore_real.exe")
        let web = uc.appending(path: "UplayWebCore.exe")
        if fm.fileExists(atPath: real.path(percentEncoded: false)) {
            try? fm.removeItem(at: web)
            try? fm.copyItem(at: real, to: web)
        }
        try? fm.removeItem(at: uc.appending(path: "version.dll"))
        try? fm.removeItem(at: uc.appending(path: "version_wine.dll"))

        let argsText = cefArgs.joined(separator: "\n") + "\n"
        let data = Data(argsText.utf8)
        for name in ["devargs.txt", "testargs.txt", "webcore_args.txt"] {
            try data.write(to: uc.appending(path: name))
        }
    }

    private static func unlinkFLY4() {
        _ = "/fly-upc-stretch-bridge4".withCString { shm_unlink($0) }
    }

    private static func restoreHTTP2(in bottle: Bottle) {
        guard let cache = connectCacheDir(in: bottle) else { return }
        let fm = FileManager.default
        let http2 = cache.appending(path: "http2")
        try? fm.removeItem(at: http2)
        if let snap = http2Snapshot() {
            try? fm.createDirectory(at: cache, withIntermediateDirectories: true)
            try? fm.copyItem(at: snap, to: http2)
            return
        }
        let bak = cache.appending(path: "http2.bak-20260809-2330")
        if fm.fileExists(atPath: bak.path(percentEncoded: false)) {
            try? fm.copyItem(at: bak, to: http2)
        }
    }

    private static func connectCacheDir(in bottle: Bottle) -> URL? {
        let fm = FileManager.default
        let users = bottle.url.appending(path: "drive_c").appending(path: "users")
        var names = [NSUserName(), "ebenoelofse", "crossover"] // crossover: common Wine prefix user
        if let children = try? fm.contentsOfDirectory(at: users, includingPropertiesForKeys: nil) {
            names.append(contentsOf: children.map(\.lastPathComponent))
        }
        var seen = Set<String>()
        for name in names where seen.insert(name).inserted {
            let cache = users
                .appending(path: name)
                .appending(path: "AppData")
                .appending(path: "Local")
                .appending(path: "Ubisoft Game Launcher")
                .appending(path: "cache")
            if fm.fileExists(atPath: cache.path(percentEncoded: false)) {
                return cache
            }
        }
        return users
            .appending(path: NSUserName())
            .appending(path: "AppData")
            .appending(path: "Local")
            .appending(path: "Ubisoft Game Launcher")
            .appending(path: "cache")
    }

    private static func http2Snapshot() -> URL? {
        let fm = FileManager.default
        let scratch = PlatformCatalog.repoRootFromSource().appending(path: ".scratch")
        let relatives = [
            "checkpoint-bridge-working-LATEST/http2/http2",
            "checkpoint-parent-native-LATEST/http2/http2",
            "checkpoint-fast-present-LATEST/http2/http2",
            "checkpoint-bridge-working-20260810-205958/http2/http2",
            "checkpoint-parent-native-20260810-231523/http2/http2",
            "checkpoint-fast-present-20260811-184128/http2/http2"
        ]
        for rel in relatives {
            let url = URL(fileURLWithPath: scratch.path(percentEncoded: false) + "/" + rel)
            if fm.fileExists(atPath: url.path(percentEncoded: false)) {
                return url
            }
        }
        return nil
    }

    private static func presentDylibs() -> (epi: URL, inject: URL)? {
        guard let bin = PlatformCatalog.toolsBinURL() else { return nil }
        let fm = FileManager.default
        let epiCandidates = [
            bin.appending(path: "fly_stretch_epi_bridge.fast.dylib"),
            bin.appending(path: "fly_stretch_epi_bridge.optionb.dylib"),
            bin.appending(path: "fly_stretch_epi_bridge.dylib")
        ]
        let injectCandidates = [
            bin.appending(path: "present_force_inject.dylib")
        ]
        guard let epi = epiCandidates.first(where: {
            fm.fileExists(atPath: $0.path(percentEncoded: false))
        }) else { return nil }
        guard let inject = injectCandidates.first(where: {
            fm.fileExists(atPath: $0.path(percentEncoded: false))
        }) else { return nil }
        return (epi, inject)
    }

    /// Drop inherited Wine/GPTK/Steam vars so Connect cannot pick up the game tree.
    private static func scrubbedMacEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let prefixes = ["WINE", "CX_", "DYLD_", "VK_", "D3DM_", "STEAM", "MVK_", "FLY_"]
        for key in env.keys {
            if prefixes.contains(where: { key.hasPrefix($0) }) {
                env.removeValue(forKey: key)
            }
        }
        env.removeValue(forKey: "WINEDLLOVERRIDES")
        env.removeValue(forKey: "WINEPREFIX")
        env.removeValue(forKey: "WINEMSYNC")
        env.removeValue(forKey: "WINEESYNC")
        env.removeValue(forKey: "VK_ICD_FILENAMES")
        return env
    }
}

private final class SpawnedProcesses: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [Process] = []

    func retain(_ process: Process) {
        lock.lock()
        processes.append(process)
        process.terminationHandler = { [weak self] finished in
            self?.remove(finished)
        }
        lock.unlock()
    }

    private func remove(_ process: Process) {
        lock.lock()
        processes.removeAll { $0 === process }
        lock.unlock()
    }
}
