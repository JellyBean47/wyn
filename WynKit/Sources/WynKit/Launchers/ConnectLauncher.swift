//
//  ConnectLauncher.swift
//  WynKit
//
//  This file is part of Wyn.
//
//  Wyn is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Wyn is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Wyn.
//  If not, see https://www.gnu.org/licenses/.
//
//  Ubisoft Connect CEF paints on Libraries.steam (Wine 11.0 / dxmt-wine11.0)
//  via FLY4 StretchBlt replay. FLY_COCOA_FAST is EA-titled only and is not
//  this path.
//
//  Odyssey (and any `requiresUbisoftConnect` title) also needs `upc.exe` on
//  the *game-host* wineserver for D3DMetal play. That UI may be transparent
//  (no FLY4); the process + a new StartView line still count. Do not
//  wineserver -k a Logged-On session to start Connect.
//

import Darwin
import Foundation

public enum ConnectLauncher {
    private static let connectDllOverrides =
        "winemenubuilder.exe=d;dwrite=b;d2d1,d3d10core=d;d3d11,dxgi=b;d3dcompiler_47=n"

    // Same flags as Tools/present-parent-native-run.sh. `--disable-gpu` makes
    // CEF spawn a gpu-process with `--use-gl=disabled`, ANGLE then fails
    // MoltenVK (no VK_KHR_win32_surface), StretchBlt never fires, FLY4 stays
    // empty, and the HWND is transparent. `--in-process-gpu` + SwiftShader is
    // the path that produced FAST blit/s≈100 on 9 Sep.
    static let cefArgs = [
        "--no-sandbox",
        "--in-process-gpu",
        "--disable-gpu-compositing",
        "--use-gl=angle",
        "--use-angle=swiftshader-webgl"
    ]

    private static let attempts = 6
    // CEF can take over a minute to reach StartView on a fresh cache.
    static let startViewTimeoutSeconds = 120

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
        if PlatformCatalog.isRunning(.ubisoft) {
            return
        }

        // Same prefix as Logged-On Steam on game-host Wine. Do not drain
        // the bottle — wineserver -k would kill Steam.
        if SteamLauncher.isBottleWineserverFromTree(in: bottle, tree: .game) {
            guard WynWineInstaller.isWineInstalled(for: .game) else {
                throw PlatformLaunchError.wineTreeMissing(.game)
            }
            LaunchProgress.emit(
                "Ubisoft Connect: attaching upc.exe to the game-host wineserver (UI may be transparent)."
            )
            try prepareConnectFiles(in: bottle)
            let (logURL, offset) = launcherLogPosition(in: bottle)
            try spawnConnect(in: bottle, wineTree: .game, injectPresent: false)
            try await waitForWindow(logURL: logURL, offset: offset, requirePaintedFrame: false)
            return
        }

        guard WynWineInstaller.isWineInstalled(for: .steam) else {
            throw PlatformLaunchError.wineTreeMissing(.steam)
        }
        guard presentDylibs() != nil else {
            throw PlatformLaunchError.presentDylibsMissing
        }

        let frankeaUp = SteamLauncher.isBottleWineserverFromTree(in: bottle, tree: .steam)
        if frankeaUp {
            try prepareConnectFiles(in: bottle)
            unlinkFLY4()
            let (logURL, offset) = launcherLogPosition(in: bottle)
            try spawnConnect(in: bottle, wineTree: .steam, injectPresent: true)
            try await waitForWindow(logURL: logURL, offset: offset, requirePaintedFrame: true)
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
                LaunchProgress.emit("Ubisoft Connect: waiting for the window to paint…")
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
        let (logURL, offset) = launcherLogPosition(in: bottle)
        try spawnConnect(in: bottle, wineTree: .steam, injectPresent: true)
        try await waitForWindow(logURL: logURL, offset: offset, requirePaintedFrame: true)
    }

    private static func launcherLogPosition(in bottle: Bottle) -> (URL, Int) {
        let logURL = installDirectory(in: bottle)
            .appending(path: "logs")
            .appending(path: "launcher_log.txt")
        let offset = (try? FileManager.default.attributesOfItem(
            atPath: logURL.path(percentEncoded: false)
        )[.size] as? NSNumber)?.intValue ?? 0

        return (logURL, offset)
    }

    private static func spawnConnect(
        in bottle: Bottle,
        wineTree: WineTree,
        injectPresent: Bool
    ) throws {
        let dylibs: (epi: URL, inject: URL)?
        if injectPresent {
            guard let present = presentDylibs() else {
                throw PlatformLaunchError.presentDylibsMissing
            }
            dylibs = present
        } else {
            dylibs = nil
        }
        let wine = Wine.wineBinary(for: wineTree).path(percentEncoded: false)
        let prefix = bottle.url.path(percentEncoded: false)
        let uc = installDirectory(in: bottle)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let outDir = Wine.logsFolder.appending(path: "present-connect-\(stamp)")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let logURL = outDir.appending(path: "wine.log")
        FileManager.default.createFile(atPath: logURL.path(percentEncoded: false), contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        defer { try? logHandle.close() }

        let bridgeFile = bottle.url
            .appending(path: "drive_c")
            .appending(path: "windows")
            .appending(path: "temp")
            .appending(path: "fly-stretch-bridge.bgra")
        try FileManager.default.createDirectory(
            at: bridgeFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var assignments = [
            "WINEPREFIX=\(prefix)",
            "WINEESYNC=1",
            "WINEMSYNC=1",
            "WINE_SIMULATE_WRITECOPY=1",
            "WINEDLLOVERRIDES=\(connectDllOverrides)",
            "WINEDEBUG=-all"
        ]
        if let dylibs {
            assignments.append(contentsOf: [
                "DYLD_INSERT_LIBRARIES=\(dylibs.epi.path(percentEncoded: false)):\(dylibs.inject.path(percentEncoded: false))",
                "FLY_FAST_PRESENT=1",
                "FLY_PARENT_PRESENT=1",
                "FLY_BRIDGE_SHM=0",
                "FLY_BRIDGE_FILE=1",
                "FLY_OPTION_B=0",
                "FLY_SURFACE_MAP=0",
                "PRESENT_FORCE_LOGIN_BRIDGE=1",
                "PRESENT_BRIDGE_BGRA=\(bridgeFile.path(percentEncoded: false))",
                // Default in present_force_inject is opaque=1. Setting 0 is what
                // leaves a see-through HWND when CEF has not StretchBlt'd yet.
                "PRESENT_FORCE_OPAQUE=1",
                "PRESENT_FORCE_LOGIN_FILL=0",
                "PRESENT_FORCE_LOGIN_SYNC=1",
                "FLY_STRETCH_DUMP=1",
                "STRETCHBLT_SPY_LOG=\(outDir.appending(path: "spy.log").path(percentEncoded: false))",
                "PRESENT_FORCE_LOG=\(outDir.appending(path: "inject.log").path(percentEncoded: false))"
            ])
        }
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

    private static let fly4ShmName = "/fly-upc-stretch-bridge4"
    private static let fly4Magic: UInt32 = 0x34594C46
    private static let fly4HeaderSize = 64
    private static let fly4MaxWidth = 2048
    private static let fly4MaxHeight = 1200

    private static func waitForWindow(
        logURL: URL,
        offset: Int,
        requirePaintedFrame: Bool
    ) async throws {
        for second in 1...startViewTimeoutSeconds {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let chunk = logTail(logURL, offset: offset)
            let running = PlatformCatalog.isRunning(.ubisoft)
            let status: StartupStatus
            if requirePaintedFrame {
                status = startupStatus(
                    log: chunk,
                    elapsedSeconds: second,
                    isRunning: running,
                    hasFrame: hasFreshFLY4Frame()
                )
            } else {
                status = gameHostStartupStatus(
                    log: chunk,
                    elapsedSeconds: second,
                    isRunning: running
                )
            }
            switch status {
            case .ready: return
            case .waiting: continue
            case .failed: throw PlatformLaunchError.connectWedged
            }
        }
        throw PlatformLaunchError.connectWedged
    }

    enum StartupStatus { case waiting, ready, failed }

    /// A CEF initialization line is progress, not a deadline. Only the new
    /// launch's log tail is considered; old StartView entries cannot pass it.
    static func startupStatus(log: String, elapsedSeconds: Int, isRunning: Bool, hasFrame: Bool) -> StartupStatus {
        if !isRunning && elapsedSeconds > 3 { return .failed }
        if log.contains("StartView.cpp") && hasFrame { return .ready }
        return elapsedSeconds >= startViewTimeoutSeconds ? .failed : .waiting
    }

    /// Only a signed-in client writes this line. Reaching `StartView.cpp` does
    /// not imply it: that is just the shell, and it appears whatever the shell
    /// went on to render.
    static let signedInMarker = "AccountStartupUser.cpp"

    /// Game-host Connect has no FLY4 paint, so the log is the only evidence
    /// there is — and `StartView.cpp` is the wrong line to read it from.
    ///
    /// A client parked on Ubisoft's bot-check page ("Access is temporarily
    /// restricted") reaches StartView and sits there indefinitely. On 10 Sep
    /// that made this function report `.ready` for three consecutive launches
    /// of a Connect that could not authenticate anything, and Odyssey was
    /// handed it each time. The window looked broken; nothing was broken.
    ///
    /// `AccountStartupUser.cpp` is emitted only once an account is actually
    /// resolved, which is the property callers care about. Requiring it costs
    /// nothing on the game-host path — that UI is transparent, so interactive
    /// sign-in is impossible there and a saved token is mandatory regardless.
    static func gameHostStartupStatus(log: String, elapsedSeconds: Int, isRunning: Bool) -> StartupStatus {
        if !isRunning && elapsedSeconds > 15 { return .failed }
        if isRunning && log.contains(signedInMarker) { return .ready }
        return elapsedSeconds >= startViewTimeoutSeconds ? .failed : .waiting
    }

    /// FLY4 header + pixels. Empty or hwnd-less surfaces are not a painted window.
    static func fly4SurfaceLooksPainted(_ bytes: Data) -> Bool {
        guard bytes.count >= fly4HeaderSize else { return false }
        func uint32(_ offset: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
        }
        func uint64(_ offset: Int) -> UInt64 {
            (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[offset + $1]) << (8 * $1) }
        }
        let width = Int(Int32(bitPattern: uint32(4)))
        let height = Int(Int32(bitPattern: uint32(8)))
        guard uint32(0) == fly4Magic,
              width >= 8, height >= 8,
              width <= fly4MaxWidth, height <= fly4MaxHeight,
              uint64(16) != 0 else { return false }
        let pixelBytes = width * height * 4
        guard bytes.count >= fly4HeaderSize + pixelBytes else { return false }
        var i = fly4HeaderSize
        let end = fly4HeaderSize + pixelBytes
        let step = max(4, ((end - i) / 4096) & ~3)
        while i + 4 <= end {
            if uint32(i) & 0x00FF_FFFF != 0 { return true }
            i += step
        }
        return false
    }

    static func hasFreshFLY4Frame() -> Bool {
        let fd = fly4ShmName.withCString { fly_shm_open($0, O_RDONLY, 0) }
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        let mapLen = fly4HeaderSize + fly4MaxWidth * fly4MaxHeight * 4
        guard let raw = mmap(nil, mapLen, PROT_READ, MAP_SHARED, fd, 0),
              raw != MAP_FAILED else { return false }
        defer { munmap(raw, mapLen) }
        let header = Data(bytes: raw, count: fly4HeaderSize)
        func uint32(_ offset: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(header[offset + $1]) << (8 * $1) }
        }
        let width = Int(Int32(bitPattern: uint32(4)))
        let height = Int(Int32(bitPattern: uint32(8)))
        guard width >= 8, height >= 8,
              width <= fly4MaxWidth, height <= fly4MaxHeight else { return false }
        let total = fly4HeaderSize + width * height * 4
        let bytes = Data(bytes: raw, count: total)
        return fly4SurfaceLooksPainted(bytes)
    }

    static func logTail(_ url: URL, offset: Int) -> String {
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

    /// Clear Connect, and *only* Connect.
    ///
    /// This used to open with `wineserver -k`, which does not drain Connect —
    /// it drains the prefix. On 10 Sep a Connect crash on the cold path
    /// therefore took the whole session down with it: the retry loop calls this
    /// before every attempt, so one crash became "everything closed". Steam
    /// survived only because it happened to be on the other tree that morning.
    ///
    /// Killing the three Connect processes is sufficient — the wineserver exits
    /// on its own once nothing is left in the prefix. This is the same rule the
    /// project already follows for Steam, and it is a guardrail, not a
    /// preference: **never `wineserver -k`.**
    private static func drainConnect(in bottle: Bottle) async {
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

    private static let connectProfileLeaf = "Ubisoft Game Launcher"

    /// Connect keeps its credentials per *Windows* user, and Wyn's two Wine
    /// trees do not agree on who that is: winecx 11.15 runs as `crossover`,
    /// wine 11.0 as the macOS user. A sign-in performed on one tree is
    /// therefore invisible to the other.
    ///
    /// The game-host path is where that bites. Its UI is transparent, so nobody
    /// can sign in interactively, and the missing token does not surface as a
    /// sign-in prompt — it surfaces as Ubisoft's bot-check page, because a
    /// cookie-less CEF running SwiftShader under `--no-sandbox` is exactly what
    /// their check is looking for. It reads as a broken window. It is not one.
    ///
    /// So point every Windows user's Connect directory at whichever one holds a
    /// token: a sign-in on either tree then serves both, and they cannot drift
    /// apart again. Idempotent, and a no-op before the first sign-in.
    static func shareConnectProfileAcrossWineUsers(in bottle: Bottle) {
        let fm = FileManager.default
        let usersRoot = bottle.url.appending(path: "drive_c").appending(path: "users")
        guard let users = try? fm.contentsOfDirectory(
            at: usersRoot, includingPropertiesForKeys: nil
        ) else { return }
        let candidates = users.filter { $0.lastPathComponent != "Public" }

        func profileDir(_ user: URL) -> URL {
            user.appending(path: "AppData").appending(path: "Local")
                .appending(path: connectProfileLeaf)
        }
        func tokenDate(_ dir: URL) -> Date? {
            let token = dir.appending(path: "ConnectSecureStorage.dat")
            let attrs = try? fm.attributesOfItem(atPath: token.path(percentEncoded: false))
            return attrs?[.modificationDate] as? Date
        }

        // Canonical = the real directory holding the newest token. A symlink is
        // never canonical, or two links could point at each other.
        var canonical: (dir: URL, user: String, date: Date)?
        for user in candidates {
            let dir = profileDir(user)
            let path = dir.path(percentEncoded: false)
            guard (try? fm.destinationOfSymbolicLink(atPath: path)) == nil else { continue }
            guard let date = tokenDate(dir) else { continue }
            if canonical == nil || date > canonical!.date {
                canonical = (dir, user.lastPathComponent, date)
            }
        }
        guard let target = canonical else { return }

        // Relative, so the link survives the bottle being moved or archived.
        let relative = "../../../\(target.user)/AppData/Local/\(connectProfileLeaf)"

        for user in candidates where user.lastPathComponent != target.user {
            let dir = profileDir(user)
            let path = dir.path(percentEncoded: false)

            if let existing = try? fm.destinationOfSymbolicLink(atPath: path) {
                if existing == relative { continue }
                try? fm.removeItem(atPath: path)  // a link holds no data
            } else if fm.fileExists(atPath: path) {
                // Never delete a profile directory: it may hold the only copy
                // of a token. Park it beside itself and say where it went.
                let stamp = ISO8601DateFormatter().string(from: Date())
                    .replacingOccurrences(of: ":", with: "")
                let parked = dir.deletingLastPathComponent()
                    .appending(path: "\(connectProfileLeaf).superseded-\(stamp)")
                guard (try? fm.moveItem(at: dir, to: parked)) != nil else { continue }
                LaunchProgress.emit(
                    "Ubisoft Connect: \(user.lastPathComponent) had no saved sign-in; "
                        + "parked it as \(parked.lastPathComponent) and pointed it at \(target.user)."
                )
            }
            try? fm.createSymbolicLink(atPath: path, withDestinationPath: relative)
        }
    }

    private static func prepareConnectFiles(in bottle: Bottle) throws {
        let fm = FileManager.default
        let uc = installDirectory(in: bottle)

        // Before anything else: make sure the Windows user this launch will
        // resolve to can see the account we are already signed in as.
        shareConnectProfileAcrossWineUsers(in: bottle)
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

        // ANGLE/SwiftShader LoadLibrary(d3dcompiler_47) fails with 126 on the
        // 190 KB Wine stub in system32. Steam ships the real 4.7 MB compiler.
        let compiler = uc.appending(path: "d3dcompiler_47.dll")
        if !fm.fileExists(atPath: compiler.path(percentEncoded: false)) {
            let steamCompiler = bottle.url
                .appending(path: "drive_c")
                .appending(path: "Program Files (x86)")
                .appending(path: "Steam")
                .appending(path: "bin")
                .appending(path: "cef")
                .appending(path: "cef.win64")
                .appending(path: "d3dcompiler_47.dll")
            if fm.fileExists(atPath: steamCompiler.path(percentEncoded: false)) {
                try fm.copyItem(at: steamCompiler, to: compiler)
            }
        }
    }

    private static func unlinkFLY4() {
        _ = fly4ShmName.withCString { shm_unlink($0) }
    }

    // Let Connect create and maintain its own CEF cache. Developer snapshots
    // are neither required on first launch nor safe to restore over user data.

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
        let prefixes = ["WINE", "CX_", "DYLD_", "VK_", "D3DM_", "STEAM", "MVK_", "FLY_", "PRESENT_", "STRETCHBLT_"]
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

@_silgen_name("shm_open")
private func fly_shm_open(_ name: UnsafePointer<CChar>, _ oflag: Int32, _ mode: mode_t) -> Int32

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
