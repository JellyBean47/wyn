//
//  Wine.swift
//  Whisky
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

import ApplicationServices
import Foundation
import os.log

public class Wine {
    /// URL to the installed `DXVK` folder (GPTK Libraries — often upstream 2.x).
    private static let dxvkFolder: URL = WynWineInstaller.libraryFolder.appending(path: "DXVK")
    /// URL to the installed `DXMT` folder (game-tree). Prefer `resolveDXMTPayload()`.
    private static let dxmtFolder: URL = WynWineInstaller.libraryFolder.appending(path: "DXMT")

    /// Frankea Steam tree ships x64+x32 DXMT (32-bit Battle.net CEF). Game-tree
    /// `Libraries/DXMT` is often missing. Not GPTK / D3DMetal.
    private static func resolveDXMTPayload() -> URL {
        let steam = WynWineInstaller.steamLibraryFolder.appending(path: "DXMT")
        let d3d11 = steam.appending(path: "x64").appending(path: "d3d11.dll")
        if FileManager.default.fileExists(atPath: d3d11.path(percentEncoded: false)) {
            return steam
        }
        return dxmtFolder
    }

    /// Resolve DXVK payload for MoltenVK on Apple Silicon.
    /// Frankea/stock MoltenVK lacks geometryShader — upstream DXVK 2.x then AVs in CreateDXGIFactory.
    /// Prefer DXVK-macOS 1.10.3-async next to Steam Wine (or whisky-wine checkout).
    private static func resolveDXVKPayload(for tree: WineTree) -> URL {
        let fm = FileManager.default
        if tree == .steam {
            let steam = WynWineInstaller.steamLibraryFolder.appending(path: "DXVK")
            let d3d11 = steam.appending(path: "x64").appending(path: "d3d11.dll")
            if fm.fileExists(atPath: d3d11.path(percentEncoded: false)) {
                return steam
            }
        }
        // Prefer macOS-tolerant payload whenever present (even for .game DXVK launches).
        let macOS = WynWineInstaller.steamLibraryFolder.appending(path: "DXVK")
        if fm.fileExists(
            atPath: macOS.appending(path: "x64").appending(path: "d3d11.dll").path(percentEncoded: false)
        ) {
            return macOS
        }
        return dxvkFolder
    }
    /// Default game-tree `wine64` (GPTK-aware Libraries). Prefer `wineBinary(for:)`.
    public static var wineBinary: URL { wineBinary(for: .game) }

    public static func wineBinary(for tree: WineTree) -> URL {
        WynWineInstaller.binFolder(for: tree).appending(path: "wine64")
    }

    public static func wineserverBinary(for tree: WineTree) -> URL {
        WynWineInstaller.binFolder(for: tree).appending(path: "wineserver")
    }

    /// Run a process on a executable file given by the `executableURL`
    private static func runProcess(
        name: String? = nil, args: [String], environment: [String: String], executableURL: URL, directory: URL? = nil,
        fileHandle: FileHandle?
    ) throws -> AsyncStream<ProcessOutput> {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = args
        process.currentDirectoryURL = directory ?? executableURL.deletingLastPathComponent()
        process.environment = environment
        process.qualityOfService = .userInitiated

        return try process.runStream(
            name: name ?? args.joined(separator: " "), fileHandle: fileHandle
        )
    }

    /// Run a `wine` process with the given arguments and environment variables returning a stream of output
    private static func runWineProcess(
        name: String? = nil, args: [String], environment: [String: String] = [:],
        wineTree: WineTree = .game,
        fileHandle: FileHandle?
    ) throws -> AsyncStream<ProcessOutput> {
        return try runProcess(
            name: name, args: args, environment: environment,
            executableURL: wineBinary(for: wineTree),
            fileHandle: fileHandle
        )
    }

    /// Run a `wineserver` process with the given arguments and environment variables returning a stream of output
    private static func runWineserverProcess(
        name: String? = nil, args: [String], environment: [String: String] = [:],
        wineTree: WineTree = .game,
        fileHandle: FileHandle?
    ) throws -> AsyncStream<ProcessOutput> {
        return try runProcess(
            name: name, args: args, environment: environment,
            executableURL: wineserverBinary(for: wineTree),
            fileHandle: fileHandle
        )
    }

    /// Run a `wine` process with the given arguments and environment variables returning a stream of output
    public static func runWineProcess(
        name: String? = nil, args: [String], bottle: Bottle, environment: [String: String] = [:],
        wineTree: WineTree = .game
    ) throws -> AsyncStream<ProcessOutput> {
        let fileHandle = try makeFileHandle()
        fileHandle.writeApplicaitonInfo()
        fileHandle.writeInfo(for: bottle)

        return try runWineProcess(
            name: name, args: args,
            environment: constructWineEnvironment(for: bottle, environment: environment),
            wineTree: wineTree,
            fileHandle: fileHandle
        )
    }

    /// Run a `wineserver` process with the given arguments and environment variables returning a stream of output
    public static func runWineserverProcess(
        name: String? = nil, args: [String], bottle: Bottle, environment: [String: String] = [:],
        wineTree: WineTree = .game
    ) throws -> AsyncStream<ProcessOutput> {
        let fileHandle = try makeFileHandle()
        fileHandle.writeApplicaitonInfo()
        fileHandle.writeInfo(for: bottle)

        return try runWineserverProcess(
            name: name, args: args,
            environment: constructWineServerEnvironment(for: bottle, environment: environment),
            wineTree: wineTree,
            fileHandle: fileHandle
        )
    }

    public struct LaunchOptions: Sendable {
        public var debug: Bool
        public var echoOutput: Bool
        /// Which Wine tree to execute. One-Wine Steam/game → `.game`; emergency frankea Steam → `.steam`.
        public var wineTree: WineTree
        /// When set, bypasses bottle/profile layer selection (e.g. frankea auth launch → DXVK, not DXMT).
        public var translationLayerOverride: TranslationLayer?
        /// Skip DXVK/DXMT/D3DMetal DLL deploy — use Wine builtins (wined3d).
        /// Needed for frankea auth proof: Libraries.steam has no libvulkan, so DXVK crashes in CreateDXGIFactory.
        public var useWineBuiltinD3D: Bool
        /// Force-migrate frankea Steam → game-host Wine for D3DMetal (same as default P0-c path).
        /// Kept for CLI `--d3dmetal` / scripts; migrate already runs unless `preferFrankeaSteam`.
        public var preferD3DMetalAuth: Bool
        /// Rollback Steam UI / auth path: frankea Wine (`Libraries.steam`).
        public var preferFrankeaSteam: Bool
        /// Steam UI on game-host Wine (`Libraries/` — FOSS winecx after P0-c). Default when not frankea.
        public var preferGPTKSteam: Bool
        /// Return after `wine start` has spawned instead of waiting for process exit.
        /// The library overlay uses this so Play is not stuck until the game quits.
        public var detachAfterStart: Bool

        public init(
            debug: Bool = false,
            echoOutput: Bool = false,
            wineTree: WineTree = .game,
            translationLayerOverride: TranslationLayer? = nil,
            useWineBuiltinD3D: Bool = false,
            preferD3DMetalAuth: Bool = false,
            preferFrankeaSteam: Bool = false,
            preferGPTKSteam: Bool = false,
            detachAfterStart: Bool = false
        ) {
            self.debug = debug
            self.echoOutput = echoOutput
            self.wineTree = wineTree
            self.translationLayerOverride = translationLayerOverride
            self.useWineBuiltinD3D = useWineBuiltinD3D
            self.preferD3DMetalAuth = preferD3DMetalAuth
            self.preferFrankeaSteam = preferFrankeaSteam
            self.preferGPTKSteam = preferGPTKSteam
            self.detachAfterStart = detachAfterStart
        }
    }

    /// Promote this process to a foreground app so winemac windows are on-screen.
    /// CLI `wyn` is otherwise `LSBackgroundOnly` / activationPolicy prohibited
    /// when spawned from a non-GUI parent; Wyn.app is already `.regular`.
    /// `TransformProcessType` does not need the main thread (avoids a deadlock if
    /// main is blocked in async CLI).
    public static func allowMacWindows() {
        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kCurrentProcess))
        _ = TransformProcessType(
            &psn,
            ProcessApplicationTransformState(kProcessTransformToForegroundApplication)
        )
    }

    /// Execute a `wine start /unix {url}` command. Returns the wine process exit status.
    @discardableResult
    public static func runProgram(
        at url: URL, args: [String] = [], bottle: Bottle, environment: [String: String] = [:],
        options: LaunchOptions = LaunchOptions()
    ) async throws -> Int32 {
        allowMacWindows()
        let effective = LaunchDiagnostics.effectiveLayer(for: bottle)
        let layer = options.translationLayerOverride ?? effective.layer
        let tree = options.wineTree

        if options.debug {
            print("[wyn:debug] Wine tree: \(tree.displayName)")
            print("[wyn:debug] wine64: \(wineBinary(for: tree).path(percentEncoded: false))")
            if options.useWineBuiltinD3D {
                print("[wyn:debug] Graphics: Wine builtin wined3d (no DXVK/DXMT/D3DMetal deploy)")
            } else {
                let reason = options.translationLayerOverride != nil
                    ? "launch override"
                    : effective.reason
                print("[wyn:debug] Effective graphics layer: \(layer.rawValue) (\(reason))")
                if options.translationLayerOverride == nil,
                   reason.contains("but Libraries") {
                    print("[wyn:debug] Declared vs wired mismatch — filesystem wins. \(reason)")
                }
            }
        }

        // Steam tree is frankea Wine — D3DMetal/GPTK stubs are not available there.
        // DXMT/DXVK still work (payload lives under game Libraries/) *if* Vulkan is loadable.
        // D3DMetal play must use wineTree=.game (Option A); this branch is a safety net only.
        let graphicsLayer: TranslationLayer
        if options.useWineBuiltinD3D {
            graphicsLayer = layer // unused for deploy
        } else if tree == .steam, layer == .d3dMetal, options.translationLayerOverride == nil {
            graphicsLayer = .dxmt
            if options.debug {
                print("[wyn:debug] D3DMetal unavailable on frankea Steam Wine → DXMT (unexpected for play)")
            }
        } else {
            graphicsLayer = layer
        }

        if !options.useWineBuiltinD3D {
            if graphicsLayer == .dxmt {
                if options.debug { print("[wyn:debug] Deploying DXMT DLLs into bottle…") }
                try enableDXMT(bottle: bottle)
                if options.debug { print("[wyn:debug] DXMT deploy OK") }
            }

            if graphicsLayer == .dxvk {
                if options.debug { print("[wyn:debug] Deploying DXVK DLLs into bottle…") }
                try enableDXVK(bottle: bottle, wineTree: tree)
                if options.debug { print("[wyn:debug] DXVK deploy OK (\(resolveDXVKPayload(for: tree).path))") }
            }

            if tree == .game, graphicsLayer == .d3dMetal {
                if options.debug { print("[wyn:debug] Enabling D3DMetal (GPTK)…") }
                try enableD3DMetal(bottle: bottle)
                if options.debug { print("[wyn:debug] D3DMetal enable OK") }
            }
        }

        var launchEnv = environment

        if !options.useWineBuiltinD3D, tree == .game, graphicsLayer == .d3dMetal {
            launchEnv.merge(GPTKInstaller.launchEnvironment(), uniquingKeysWith: { _, new in new })
        }

        if options.debug {
            launchEnv.merge(LaunchDiagnostics.debugEnvironmentOverrides(), uniquingKeysWith: { _, new in new })
            // Keep profile WINEDLLOVERRIDES authoritative if already set.
            if let overrides = environment["WINEDLLOVERRIDES"] {
                launchEnv["WINEDLLOVERRIDES"] = overrides
            }
        }

        let echo = options.debug || options.echoOutput

        // Unreal (and most Windows games) resolve content via GetCurrentDirectory.
        // `wine start /unix` alone leaves CWD as Wine's bin dir → missing .uproject.
        let workDir = url.deletingLastPathComponent()
        let workDirWin = windowsPath(for: workDir, in: bottle)
        var startArgs = ["start", "/d", workDirWin, "/unix", url.path(percentEncoded: false)]
        startArgs.append(contentsOf: args)

        if options.debug {
            print("[wyn:debug] wine start /d \(workDirWin)")
            print("[wyn:debug] exe: \(url.path(percentEncoded: false))")
        }

        let stream = try Self.runWineProcess(
            name: url.lastPathComponent,
            args: startArgs,
            bottle: bottle, environment: launchEnv, wineTree: tree
        )
        let exitStatus = try await consumeWineStart(
            stream,
            echo: echo,
            detachAfterStart: options.detachAfterStart
        )

        if options.debug {
            if let latest = try? FileManager.default.contentsOfDirectory(
                at: logsFolder, includingPropertiesForKeys: [.contentModificationDateKey]
            ).sorted(by: {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }).first {
                print("[wyn:debug] Log file: \(latest.path)")
            }
        }
        return exitStatus
    }

    /// Drain `wine start` output. With `detachAfterStart`, return once the process has spawned
    /// and keep reading logs in the background so the library overlay can dismiss.
    @discardableResult
    private static func consumeWineStart(
        _ stream: AsyncStream<ProcessOutput>,
        echo: Bool,
        detachAfterStart: Bool
    ) async throws -> Int32 {
        if detachAfterStart {
            return try await consumeWineStartDetached(stream, echo: echo)
        }
        var sawOutput = false
        var sawFatal = false
        var exitStatus: Int32 = 0
        for await output in stream {
            applyWineStartOutput(
                output,
                echo: echo,
                sawOutput: &sawOutput,
                sawFatal: &sawFatal,
                exitStatus: &exitStatus
            )
        }
        return exitStatus
    }

    private static func consumeWineStartDetached(
        _ stream: AsyncStream<ProcessOutput>,
        echo: Bool
    ) async throws -> Int32 {
        let gate = WineDetachGate()
        let box = WineStartStreamBox(stream: stream, echo: echo)
        Task.detached(priority: .userInitiated) {
            var sawOutput = false
            var sawFatal = false
            var exitStatus: Int32 = 0
            var started = false
            for await output in box.stream {
                if case .started = output, !started {
                    started = true
                    gate.signalStarted()
                }
                applyWineStartOutput(
                    output,
                    echo: box.echo,
                    sawOutput: &sawOutput,
                    sawFatal: &sawFatal,
                    exitStatus: &exitStatus
                )
            }
            if !started {
                gate.signalStarted()
            }
        }
        try await gate.wait()
        return 0
    }

    private struct WineStartStreamBox: @unchecked Sendable {
        let stream: AsyncStream<ProcessOutput>
        let echo: Bool
    }

    private static func applyWineStartOutput(
        _ output: ProcessOutput,
        echo: Bool,
        sawOutput: inout Bool,
        sawFatal: inout Bool,
        exitStatus: inout Int32
    ) {
        switch output {
        case .started:
            if echo { print("[wyn:debug] wine process started") }
        case .message(let line), .error(let line):
            let fatalWine = line.localizedCaseInsensitiveContains("version mismatch")
                || line.localizedCaseInsensitiveContains("wine client error")
                || line.localizedCaseInsensitiveContains("wrong wineserver")
            if fatalWine {
                sawFatal = true
                sawOutput = true
                fputs("[wine] \(line)", stderr)
                if !line.hasSuffix("\n") { fputs("\n", stderr) }
                fflush(stderr)
                return
            }
            guard echo else { return }
            guard LaunchDiagnostics.shouldEchoWineLine(line) else { return }
            sawOutput = true
            if case .error = output {
                fputs("[wine:err] \(line)", stderr)
                if !line.hasSuffix("\n") { fputs("\n", stderr) }
            } else {
                print("[wine] \(line)", terminator: line.hasSuffix("\n") ? "" : "\n")
            }
        case .terminated(let process):
            exitStatus = process.terminationStatus
            if echo {
                print("[wyn:debug] wine start exited with status \(exitStatus)")
                if !sawOutput {
                    print("[wyn:debug] (no wine stdout/stderr captured — check log file below)")
                }
            } else if sawFatal {
                fputs("Wine failed to start the process (see [wine] lines above).\n", stderr)
                fflush(stderr)
            }
        }
    }

    private final class WineDetachGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var finished = false

        func wait() async throws {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { cont in
                    self.lock.lock()
                    if self.finished {
                        self.lock.unlock()
                        cont.resume()
                        return
                    }
                    self.continuation = cont
                    self.lock.unlock()
                }
            } onCancel: {
                self.finish(error: CancellationError())
            }
        }

        func signalStarted() {
            finish(error: nil)
        }

        private func finish(error: Error?) {
            lock.lock()
            guard !finished else {
                lock.unlock()
                return
            }
            finished = true
            let cont = continuation
            continuation = nil
            lock.unlock()
            if let cont {
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
        }
    }

    public static func generateRunCommand(
        at url: URL, bottle: Bottle, args: String, environment: [String: String]
    ) -> String {
        var wineCmd = "\(wineBinary.esc) start /unix \(url.esc) \(args)"
        let env = constructWineEnvironment(for: bottle, environment: environment)
        for environment in env {
            wineCmd = "\(environment.key)=\"\(environment.value)\" " + wineCmd
        }

        return wineCmd
    }

    public static func generateTerminalEnvironmentCommand(bottle: Bottle) -> String {
        var cmd = """
        export PATH=\"\(WynWineInstaller.binFolder.path):$PATH\"
        export WINE=\"wine64\"
        alias wine=\"wine64\"
        alias winecfg=\"wine64 winecfg\"
        alias msiexec=\"wine64 msiexec\"
        alias regedit=\"wine64 regedit\"
        alias regsvr32=\"wine64 regsvr32\"
        alias wineboot=\"wine64 wineboot\"
        alias wineconsole=\"wine64 wineconsole\"
        alias winedbg=\"wine64 winedbg\"
        alias winefile=\"wine64 winefile\"
        alias winepath=\"wine64 winepath\"
        """

        let env = constructWineEnvironment(for: bottle, environment: constructWineEnvironment(for: bottle))
        for environment in env {
            cmd += "\nexport \(environment.key)=\"\(environment.value)\""
        }

        return cmd
    }

    /// Run a `wineserver` command with the given arguments and return the output result
    private static func runWineserver(
        _ args: [String], bottle: Bottle, wineTree: WineTree = .game
    ) async throws -> String {
        var result: [ProcessOutput] = []

        for await output in try Self.runWineserverProcess(
            args: args, bottle: bottle, environment: [:], wineTree: wineTree
        ) {
            result.append(output)
        }

        return result.compactMap { output -> String? in
            switch output {
            case .started, .terminated:
                return nil
            case .message(let message), .error(let message):
                return message
            }
        }.joined()
    }

    @discardableResult
    /// Run a `wine` command with the given arguments and return the output result
    public static func runWine(
        _ args: [String], bottle: Bottle?, environment: [String: String] = [:]
    ) async throws -> String {
        var result: [String] = []
        let fileHandle = try makeFileHandle()
        fileHandle.writeApplicaitonInfo()
        var environment = environment

        if let bottle = bottle {
            fileHandle.writeInfo(for: bottle)
            environment = constructWineEnvironment(for: bottle, environment: environment)
        }

        for await output in try runWineProcess(args: args, environment: environment, fileHandle: fileHandle) {
            switch output {
            case .started, .terminated:
                break
            case .message(let message), .error(let message):
                result.append(message)
            }
        }

        return result.joined()
    }

    public static func wineVersion() async throws -> String {
        var output = try await runWine(["--version"], bottle: nil)
        output.replace("wine-", with: "")

        // Deal with WineCX version names
        if let index = output.firstIndex(where: { $0.isWhitespace }) {
            return String(output.prefix(upTo: index))
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    public static func runBatchFile(url: URL, bottle: Bottle) async throws -> String {
        return try await runWine(["cmd", "/c", url.path(percentEncoded: false)], bottle: bottle)
    }

    public static func killBottle(bottle: Bottle) throws {
        Task.detached(priority: .userInitiated) {
            try await killBottleAndWait(bottle: bottle)
        }
    }

    /// Synchronously stop all Wine processes for this bottle (Steam, games, etc.).
    /// Kills wineserver from both game and steam trees — either may own the prefix.
    public static func killBottleAndWait(bottle: Bottle) async throws {
        for tree in WineTree.allCases {
            guard WynWineInstaller.isWineInstalled(for: tree) else { continue }
            _ = try? await runWineserver(["-k"], bottle: bottle, wineTree: tree)
        }
        // wineserver -k is async on the Wine side; give processes a moment to die.
        try await Task.sleep(nanoseconds: 800_000_000)
    }

    /// DXMT-only extras that must not remain when switching the bottle to DXVK.
    /// Community DXVK-macOS ships `d3d11`/`d3d10core` only — leftover DXMT `dxgi`
    /// would mix with DXVK and break the RHI.
    private static let dxmtExclusiveDLLs = [
        "winemetal.dll", "nvapi64.dll", "nvapi.dll", "nvngx.dll"
    ]

    public static func enableDXVK(bottle: Bottle, wineTree: WineTree = .game) throws {
        let fm = FileManager.default
        if wineTree == .steam {
            _ = try? WynWineInstaller.ensureFrankeaDXVKPayload()
        }
        let payload = resolveDXVKPayload(for: wineTree)
        let windowsDir = bottle.url.appending(path: "drive_c").appending(path: "windows")
        let system32 = windowsDir.appending(path: "system32")
        let syswow64 = windowsDir.appending(path: "syswow64")

        try fm.replaceDLLs(
            in: system32,
            withContentsIn: payload.appending(path: "x64")
        )
        let x32 = payload.appending(path: "x32")
        if fm.fileExists(atPath: x32.path(percentEncoded: false)) {
            try fm.replaceDLLs(in: syswow64, withContentsIn: x32)
        }

        // Restore Wine DXGI when the DXVK payload does not include it (some DXVK-macOS 1.10.x).
        let wineDllRoot = WynWineInstaller.libraryFolder(for: wineTree)
            .appending(path: "Wine").appending(path: "lib").appending(path: "wine")
        let wine64 = wineDllRoot.appending(path: "x86_64-windows")
        let wine32 = wineDllRoot.appending(path: "i386-windows")
        let dxvkHasDxgi = fm.fileExists(
            atPath: payload.appending(path: "x64").appending(path: "dxgi.dll").path(percentEncoded: false)
        )
        if !dxvkHasDxgi {
            let wineDxgi64 = wine64.appending(path: "dxgi.dll")
            if fm.fileExists(atPath: wineDxgi64.path(percentEncoded: false)) {
                try fm.installFileIfContentDiffers(at: system32.appending(path: "dxgi.dll"), from: wineDxgi64)
            }
            let wineDxgi32 = wine32.appending(path: "dxgi.dll")
            if fm.fileExists(atPath: wineDxgi32.path(percentEncoded: false)),
               fm.fileExists(atPath: syswow64.path(percentEncoded: false)) {
                try fm.installFileIfContentDiffers(at: syswow64.appending(path: "dxgi.dll"), from: wineDxgi32)
            }
        }

        for name in dxmtExclusiveDLLs {
            let x64 = system32.appending(path: name)
            if fm.fileExists(atPath: x64.path(percentEncoded: false)) {
                try fm.removeItem(at: x64)
            }
            let x32dll = syswow64.appending(path: name)
            if fm.fileExists(atPath: x32dll.path(percentEncoded: false)) {
                try fm.removeItem(at: x32dll)
            }
        }

        try ensureDXVKConfig(bottle: bottle)
    }

    /// Write a bottle-local `C:\fly\dxvk.conf` tuned for Apple Silicon / MoltenVK.
    @discardableResult
    public static func ensureDXVKConfig(bottle: Bottle) throws -> URL {
        let dir = bottle.url.appending(path: "drive_c").appending(path: "fly")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let conf = dir.appending(path: "dxvk.conf")
        let body = """
        # Written by Wyn — DXVK-macOS async + present tuning for MoltenVK
        dxvk.enableAsync = True
        dxvk.numCompilerThreads = 0
        dxvk.numAsyncThreads = 0
        dxgi.syncInterval = 0
        dxgi.maxFrameLatency = 2
        dxgi.maxFrameRate = 40
        """
        let existing = (try? String(contentsOf: conf, encoding: .utf8)) ?? ""
        if existing != body {
            try body.write(to: conf, atomically: true, encoding: .utf8)
        }
        return conf
    }

    /// Bottle-local directory for `DXVK_LOG_PATH` (`C:\fly\logs` inside the bottle).
    /// Without that variable DXVK writes `d3d11.log` into the game's working directory,
    /// which on the external game volume has never produced a log we could find.
    @discardableResult
    public static func ensureDXVKLogDirectory(bottle: Bottle) throws -> URL {
        let dir = bottle.url
            .appending(path: "drive_c")
            .appending(path: "fly")
            .appending(path: "logs")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public enum DXMTError: LocalizedError, Equatable {
        case payloadMissing

        public var errorDescription: String? {
            "DXMT is not available in the installed runtime. Reinstall WynWine or switch to DXVK."
        }
    }

    public enum D3DMetalError: LocalizedError, Equatable {
        case gptkMissing
        case wineNotGPTKAware
        case rendererNotSelected
        case dxvkMissingForSteam

        public var errorDescription: String? {
            switch self {
            case .gptkMissing:
                return "GPTK/D3DMetal not installed. Download Game Porting Toolkit 3.0 from Apple into ~/Downloads, then: wyn gptk install"
            case .wineNotGPTKAware:
                return """
                Installed Wine is not the D3DMetal game-host (need FOSS winecx with \
                ntdll CX_APPLEGPTK, not Whisky 11). \
                ./scripts/build-foss-game-host.sh then \
                wyn runtime install --gptk-aware --directory <wine-root> \
                Then: wyn gptk install. \
                translationLayer=d3dmetal does not fall back to frankea DXVK.
                """
            case .rendererNotSelected:
                return """
                D3DMetal is installed but not selected. Shared unix d3d*.so still \
                point at Wine/DXMT, not libd3dshared. Run: wyn renderer set d3dmetal
                """
            case .dxvkMissingForSteam:
                return "DXVK payload missing under Libraries/DXVK (needed for Steam UI with D3DMetal games)."
            }
        }
    }

    /// AppDefaults so the game EXE loads GPTK builtins (`d3d*=b`). Used by Option A
    /// (direct GPTK game launch) without touching Steam CEF isolation.
    public static func applyD3DMetalGameOverrides(
        bottle: Bottle,
        gameExeNames: [String],
        debug: Bool = false
    ) throws {
        let gameGPTK: [String: String] = [
            "d3d11": "b",
            "dxgi": "b",
            "d3d12": "b",
            "d3d10": "b",
            "atidxx64": "b",
            "gameoverlayrenderer64": "d",
            "gameoverlayrenderer": "d"
        ]
        var applied: [String] = []
        for raw in gameExeNames {
            let exe = (raw as NSString).lastPathComponent
            guard exe.lowercased().hasSuffix(".exe") else { continue }
            try setAppDllOverrides(bottle: bottle, exeName: exe, overrides: gameGPTK)
            applied.append(exe)
        }
        try upsertWineRegistryValues(
            bottle: bottle,
            key: #"Software\Wine\WineDbg"#,
            values: ["ShowCrashDialog": ("REG_DWORD", "0")]
        )
        if debug {
            print("[wyn:debug] AppDefaults: game \(applied) → GPTK builtin (d3d*=b)")
        }
    }

    /// Per-exe DLL overrides so Steam CEF stays on Wine builtins (not GPTK D3DMetal stubs),
    /// while the game EXE still gets `d3d11,…=b`.
    ///
    /// Game-host Wine: no CEF shim in this function, no local
    /// pre-GPTK PE deploy beside Steam (those were GPTK Wine 11 workarounds and crash-loop
    /// steamwebhelper on an older host).
    ///
    /// Note `SteamLauncher.swift` still exports `d3d11,dxgi,d3d10core=n,b` as a process-wide
    /// `WINEDLLOVERRIDES` on the frankea `-applaunch` path, which reaches steamwebhelper too.
    /// That is the currently playable path and has not been re-measured, so it is left alone —
    /// but it is the same shape as the bug fixed below and is the first thing to check if
    /// steamwebhelper crash-loops there.
    public static func applyD3DMetalSteamIsolation(
        bottle: Bottle,
        gameExeNames: [String],
        debug: Bool = false
    ) throws {
        // steam.exe -cef-in-process-gpu is not forwarded to steamwebhelper.
        // Without --in-process-gpu, CEF paints (login JS runs) and the HWND stays
        // black — Wine never gets the frames. The shim injects
        // --disable-gpu --in-process-gpu. -cef-disable-gpu on steam.exe still
        // needed so Steam itself does not spawn a crashing GPU helper.
        _ = try SteamCEFShim.install(into: bottle, debug: debug)
        try removeLocalSteamGraphicsDLLs(bottle: bottle, debug: debug)

        // `b`, not `n,b`. These must be builtin, and `n,b` does not mean that — it means
        // *native first*, so it picks up whatever PE happens to be in system32. On the game
        // tree that is DXMT (d3d11.dll 5.3 MB, dxgi.dll 1.9 MB), and loading a game
        // translation layer into Chromium's GPU process makes steamwebhelper die at startup
        // with `crashpad_client_win.cc(144) crash server failed to launch, self-terminating`,
        // respawning every 10 s and never logging on. It looked correct for a long time only
        // because on frankea system32 held Wine's builtin stubs, so `n` resolved to
        // builtin anyway and the intent above held by accident.
        // Measured 12 Aug (`n,b` FAIL 2/2, absent GOOD 4/4, `b` GOOD 2/2).
        // The game-host bottle sets no Steam AppDefaults.
        let steamSafe: [String: String] = [
            "d3d11": "b",
            "dxgi": "b",
            "d3d10core": "b",
            "d3d12": "d",
            "d3d10": "d",
            "atidxx64": "d"
        ]
        let gameGPTK: [String: String] = [
            "d3d11": "b",
            "dxgi": "b",
            "d3d12": "b",
            "d3d10": "b",
            "atidxx64": "b",
            "gameoverlayrenderer64": "d",
            "gameoverlayrenderer": "d"
        ]

        for steamExe in ["steam.exe", "steamwebhelper.exe", "steamwebhelper_real.exe"] {
            try setAppDllOverrides(bottle: bottle, exeName: steamExe, overrides: steamSafe)
        }
        for raw in gameExeNames {
            let exe = (raw as NSString).lastPathComponent
            guard exe.lowercased().hasSuffix(".exe") else { continue }
            try setAppDllOverrides(bottle: bottle, exeName: exe, overrides: gameGPTK)
        }
        try upsertWineRegistryValues(
            bottle: bottle,
            key: #"Software\Wine\WineDbg"#,
            values: ["ShowCrashDialog": ("REG_DWORD", "0")]
        )
        if debug {
            print("[wyn:debug] AppDefaults: Steam/CEF game-host-safe (d3d*=b + cef-shim); game \(gameExeNames) GPTK builtin")
        }
    }

    /// Remove GPTK-era local d3d/dxgi/wined3d PEs dropped next to Steam/CEF.
    private static func removeLocalSteamGraphicsDLLs(bottle: Bottle, debug: Bool = false) throws {
        let fm = FileManager.default
        let localDLLs = ["d3d11.dll", "dxgi.dll", "wined3d.dll", "d3d10core.dll"]
        var removed = 0
        for dir in SteamCEFShim.steamAndCEFDirectories(in: bottle) {
            guard fm.fileExists(atPath: dir.path(percentEncoded: false)) else { continue }
            for name in localDLLs {
                let url = dir.appending(path: name)
                if fm.fileExists(atPath: url.path(percentEncoded: false)) {
                    try fm.removeItem(at: url)
                    removed += 1
                }
            }
        }
        if debug, removed > 0 {
            print("[wyn:debug] Removed \(removed) local Steam/CEF graphics DLL(s)")
        }
    }

    /// Undo GPTK Steam isolation so frankea Wine can run Steam CEF with its own builtins.
    /// Wine 11 pre-GPTK PEs beside Steam are ABI-incompatible with frankea WhiskyWine.
    public static func prepareFrankeaSteamClient(bottle: Bottle, debug: Bool = false) throws {
        let fm = FileManager.default
        let localDLLs = ["d3d11.dll", "dxgi.dll", "wined3d.dll", "d3d10core.dll"]
        var removed = 0
        for dir in SteamCEFShim.steamAndCEFDirectories(in: bottle) {
            guard fm.fileExists(atPath: dir.path(percentEncoded: false)) else { continue }
            for name in localDLLs {
                let url = dir.appending(path: name)
                if fm.fileExists(atPath: url.path(percentEncoded: false)) {
                    try fm.removeItem(at: url)
                    removed += 1
                }
            }
        }

        // Prefer frankea builtins over bottle system32 GPTK stubs.
        let frankeaSafe: [String: String] = [
            "d3d11": "b",
            "dxgi": "b",
            "wined3d": "b",
            "d3d12": "d",
            "d3d10": "d",
            "d3d10core": "b",
            "atidxx64": "d"
        ]
        for steamExe in ["steam.exe", "steamwebhelper.exe", "steamwebhelper_real.exe"] {
            try setAppDllOverrides(bottle: bottle, exeName: steamExe, overrides: frankeaSafe)
        }

        try SteamCEFShim.uninstall(from: bottle, debug: debug)
        if debug {
            print("[wyn:debug] Frankea Steam prep: removed \(removed) local graphics DLLs; AppDefaults → builtin")
        }
    }

    /// Prefer pre-GPTK Wine PE (wined3d). Fall back to DXVK if backups are missing.
    @discardableResult
    private static func deploySteamClientGraphicsDLLs(bottle: Bottle) throws -> String {
        let fm = FileManager.default
        let peDir = GPTKInstaller.wineLibFolder
            .appending(path: "wine")
            .appending(path: "x86_64-windows")

        let steamDirs = SteamCEFShim.steamAndCEFDirectories(in: bottle)

        // GPTK wire replaces d3d11/dxgi PE with stubs; originals live as *.fly-pre-gptk.
        // Those PEs call wined3d.dll (not GPTK unixlib) — also ship wined3d beside Steam/CEF
        // so LoadLibrary finds a matching native before system32.
        let wineNames = ["d3d11.dll", "dxgi.dll"]
        var wineSources: [String: URL] = [:]
        for name in wineNames {
            let backup = peDir.appending(path: "\(name).fly-pre-gptk")
            if fm.fileExists(atPath: backup.path(percentEncoded: false)) {
                wineSources[name] = backup
            }
        }
        let wined3dSrc = peDir.appending(path: "wined3d.dll")
        let haveWined3d = fm.fileExists(atPath: wined3dSrc.path(percentEncoded: false))

        if wineSources.count == wineNames.count {
            for dir in steamDirs {
                guard fm.fileExists(atPath: dir.path(percentEncoded: false)) else { continue }
                for (name, src) in wineSources {
                    try fm.installFileIfContentDiffers(at: dir.appending(path: name), from: src)
                }
                if haveWined3d {
                    try fm.installFileIfContentDiffers(
                        at: dir.appending(path: "wined3d.dll"),
                        from: wined3dSrc
                    )
                }
                // Optional: remove leftover DXVK d3d10core so CEF doesn't mix stacks.
                let leftover = dir.appending(path: "d3d10core.dll")
                if fm.fileExists(atPath: leftover.path(percentEncoded: false)) {
                    try? fm.removeItem(at: leftover)
                }
            }
            return haveWined3d ? "wined3d(pre-gptk+local)" : "wined3d(pre-gptk)"
        }

        // Fallback: DXVK (may fail MoltenVK feature checks on this Wine).
        let x64 = dxvkFolder.appending(path: "x64")
        let dxvkNames = ["d3d11.dll", "dxgi.dll", "d3d10core.dll"]
        for name in dxvkNames {
            let src = x64.appending(path: name)
            guard fm.fileExists(atPath: src.path(percentEncoded: false)) else {
                throw D3DMetalError.dxvkMissingForSteam
            }
        }
        for dir in steamDirs {
            guard fm.fileExists(atPath: dir.path(percentEncoded: false)) else { continue }
            for name in dxvkNames {
                try fm.installFileIfContentDiffers(
                    at: dir.appending(path: name),
                    from: x64.appending(path: name)
                )
            }
        }
        return "DXVK(fallback)"
    }

    /// Upsert `HKCU\Software\Wine\AppDefaults\<exe>\DllOverrides` in `user.reg`.
    public static func setAppDllOverrides(
        bottle: Bottle,
        exeName: String,
        overrides: [String: String]
    ) throws {
        let key = "Software\\Wine\\AppDefaults\\\(exeName)\\DllOverrides"
        let values = Dictionary(uniqueKeysWithValues: overrides.map { ($0.key, ("REG_SZ", $0.value)) })
        try upsertWineRegistryValues(bottle: bottle, key: key, values: values)
    }

    /// Patch `user.reg` (or `system.reg` when `machine` is true) while wineserver
    /// is stopped. `key` uses Windows single-backslash form.
    public static func upsertWineRegistryValues(
        bottle: Bottle,
        key: String,
        values: [String: (String, String)],
        machine: Bool = false
    ) throws {
        let file = bottle.url.appending(path: machine ? "system.reg" : "user.reg")
        var text = try String(contentsOf: file, encoding: .utf8)
        let wineKey = key.split(separator: "\\").joined(separator: "\\\\")
        let header = "[\(wineKey)]"

        var body = "\(header) \(Int(Date().timeIntervalSince1970))\n"
        for (name, pair) in values.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            let (type, data) = pair
            if type == "REG_DWORD" {
                let n = UInt32(data) ?? 0
                body += "\"\(name)\"=dword:\(String(format: "%08x", n))\n"
            } else {
                body += "\"\(name)\"=\"\(data)\"\n"
            }
        }
        body += "\n"

        if let range = wineRegistrySectionRange(in: text, header: header) {
            text.replaceSubrange(range, with: body)
        } else {
            if !text.hasSuffix("\n") { text += "\n" }
            text += body
        }
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    /// Overlay values onto an existing registry key without dropping other names.
    public static func mergeWineRegistryValues(
        bottle: Bottle,
        key: String,
        values: [String: (String, String)],
        machine: Bool = false
    ) throws {
        let file = bottle.url.appending(path: machine ? "system.reg" : "user.reg")
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let wineKey = key.split(separator: "\\").joined(separator: "\\\\")
        let header = "[\(wineKey)]"
        var merged: [String: (String, String)] = [:]
        if let range = wineRegistrySectionRange(in: text, header: header) {
            let section = String(text[range])
            for rawLine in section.components(separatedBy: "\n").dropFirst() {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard line.first == "\"" else { continue }
                guard let close = line.dropFirst().firstIndex(of: "\"") else { continue }
                let name = String(line[line.index(after: line.startIndex)..<close])
                let afterName = line[line.index(after: close)...]
                    .trimmingCharacters(in: .whitespaces)
                guard afterName.hasPrefix("=") else { continue }
                let rhs = String(afterName.dropFirst())
                if rhs.hasPrefix("dword:") {
                    let hex = String(rhs.dropFirst(6))
                    let n = UInt32(hex, radix: 16) ?? 0
                    merged[name] = ("REG_DWORD", "\(n)")
                } else if rhs.hasPrefix("\""), rhs.hasSuffix("\""), rhs.count >= 2 {
                    merged[name] = ("REG_SZ", String(rhs.dropFirst().dropLast()))
                }
            }
        }
        for (name, pair) in values {
            merged[name] = pair
        }
        try upsertWineRegistryValues(bottle: bottle, key: key, values: merged, machine: machine)
    }

    private static func wineRegistrySectionRange(in text: String, header: String) -> Range<String.Index>? {
        guard let start = text.range(of: header)?.lowerBound else { return nil }
        let rest = text[start...].dropFirst(header.count)
        if let next = rest.range(of: "\n[") {
            return start..<next.lowerBound
        }
        return start..<text.endIndex
    }

    /// Put GPTK PE stubs in the bottle. Requires D3DMetal already selected
    /// (`wyn renderer set d3dmetal`); does not repoint shared unix modules.
    public static func enableD3DMetal(bottle: Bottle) throws {
        if !GPTKInstaller.isInstalled() {
            throw D3DMetalError.gptkMissing
        }
        guard GPTKInstaller.shouldWireWineModules else {
            throw D3DMetalError.wineNotGPTKAware
        }
        let wired = RendererWiring.inspect()
        guard wired.backend == .d3dMetal else {
            throw D3DMetalError.rendererNotSelected
        }
        try RendererWiring.verify(.d3dMetal)

        let fm = FileManager.default
        let peDir = GPTKInstaller.wineLibFolder
            .appending(path: "wine")
            .appending(path: "x86_64-windows")
        let system32 = bottle.url
            .appending(path: "drive_c")
            .appending(path: "windows")
            .appending(path: "system32")
        let syswow64 = bottle.url
            .appending(path: "drive_c")
            .appending(path: "windows")
            .appending(path: "syswow64")

        // Core GPTK D3D stubs + MetalFX complement (nvngx / nvapi64).
        let peNames = [
            "d3d11.dll", "dxgi.dll", "d3d12.dll", "d3d10.dll", "atidxx64.dll",
            "nvapi64.dll", "nvngx.dll"
        ]
        for name in peNames {
            let src = peDir.appending(path: name)
            guard fm.fileExists(atPath: src.path(percentEncoded: false)) else { continue }
            try fm.installFileIfContentDiffers(at: system32.appending(path: name), from: src)
        }

        for name in dxmtExclusiveDLLs + ["d3d10core.dll"] {
            let x64 = system32.appending(path: name)
            if fm.fileExists(atPath: x64.path(percentEncoded: false)) {
                let winePE = peDir.appending(path: name)
                if fm.fileExists(atPath: winePE.path(percentEncoded: false)) {
                    try fm.installFileIfContentDiffers(at: x64, from: winePE)
                } else if name != "d3d10core.dll" {
                    try fm.removeItem(at: x64)
                } else {
                    let stock = WynWineInstaller.libraryFolder
                        .appending(path: "Wine")
                        .appending(path: "lib")
                        .appending(path: "wine")
                        .appending(path: "x86_64-windows")
                        .appending(path: "d3d10core.dll")
                    if fm.fileExists(atPath: stock.path(percentEncoded: false)) {
                        try fm.installFileIfContentDiffers(at: x64, from: stock)
                    }
                }
            }
            let x32 = syswow64.appending(path: name)
            if name != "d3d10core.dll", fm.fileExists(atPath: x32.path(percentEncoded: false)) {
                try? fm.removeItem(at: x32)
            }
        }
        for dir in [system32, syswow64] {
            let wm = dir.appending(path: "winemetal.dll")
            if fm.fileExists(atPath: wm.path(percentEncoded: false)) {
                try? fm.removeItem(at: wm)
            }
        }
    }

    private static let dxmtNativeTrio = ["d3d11.dll", "dxgi.dll", "d3d10core.dll"]
    private static let dxmtPrefixDLLs = dxmtNativeTrio + ["winemetal.dll"]

    public static func isDXMTRuntimeNative() -> Bool {
        let d3d11 = resolveDXMTPayload().appending(path: "x64").appending(path: "d3d11.dll")
        guard FileManager.default.fileExists(atPath: d3d11.path(percentEncoded: false)) else { return false }
        return (try? isNativePE(d3d11)) ?? false
    }

    private static func isNativePE(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0x40)
        guard let marker = try handle.read(upToCount: 16), marker.count == 16 else { return false }
        return marker != Data("Wine builtin DLL".utf8)
    }

    public static func enableDXMT(bottle: Bottle) throws {
        let fileManager = FileManager.default
        let payload = resolveDXMTPayload()
        let x64Payload = payload.appending(path: "x64")
        let x32Payload = payload.appending(path: "x32")
        let windowsDir = bottle.url.appending(path: "drive_c").appending(path: "windows")
        let system32 = windowsDir.appending(path: "system32")
        let syswow64 = windowsDir.appending(path: "syswow64")
        let deploy32Bit = fileManager.fileExists(atPath: syswow64.path(percentEncoded: false))

        var sources = dxmtPrefixDLLs.map { x64Payload.appending(path: $0) }
        if deploy32Bit {
            sources += dxmtPrefixDLLs.map { x32Payload.appending(path: $0) }
        }

        let allPresent = sources.allSatisfy { fileManager.fileExists(atPath: $0.path(percentEncoded: false)) }
        let trioIsNative = dxmtNativeTrio.allSatisfy {
            (try? isNativePE(x64Payload.appending(path: $0))) == true
        }
        guard allPresent, trioIsNative else {
            throw DXMTError.payloadMissing
        }

        for name in dxmtPrefixDLLs {
            try fileManager.installFileIfContentDiffers(
                at: system32.appending(path: name),
                from: x64Payload.appending(path: name)
            )
        }

        if deploy32Bit {
            for name in dxmtPrefixDLLs {
                try fileManager.installFileIfContentDiffers(
                    at: syswow64.appending(path: name),
                    from: x32Payload.appending(path: name)
                )
            }
        }
    }

    /// Construct an environment merging the bottle values with the given values
    /// Map a host path to a Wine Windows path for this bottle (`C:\…` or `Z:\…`).
    public static func windowsPath(for url: URL, in bottle: Bottle) -> String {
        let path = url.resolvingSymlinksInPath().path(percentEncoded: false)
        let driveC = bottle.url
            .appending(path: "drive_c")
            .resolvingSymlinksInPath()
            .path(percentEncoded: false)

        if path == driveC || path.hasPrefix(driveC + "/") {
            let rest = path.dropFirst(driveC.count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if rest.isEmpty { return #"C:\"# }
            return #"C:\"# + rest.replacingOccurrences(of: "/", with: #"\"#)
        }

        // Default: z: → / (Wyn bottles link dosdevices/z: to root).
        if path.hasPrefix("/") {
            return "Z:" + path.replacingOccurrences(of: "/", with: #"\"#)
        }
        return path.replacingOccurrences(of: "/", with: #"\"#)
    }

    private static func constructWineEnvironment(
        for bottle: Bottle, environment: [String: String] = [:]
    ) -> [String: String] {
        var result: [String: String] = [
            "WINEPREFIX": bottle.url.path,
            "WINEDEBUG": "fixme-all",
            "GST_DEBUG": "1"
        ]
        bottle.settings.environmentVariables(wineEnv: &result)
        guard !environment.isEmpty else { return result }
        result.merge(environment, uniquingKeysWith: { $1 })
        return result
    }

    /// Construct an environment merging the bottle values with the given values
    private static func constructWineServerEnvironment(
        for bottle: Bottle, environment: [String: String] = [:]
    ) -> [String: String] {
        var result: [String: String] = [
            "WINEPREFIX": bottle.url.path,
            "WINEDEBUG": "fixme-all",
            "GST_DEBUG": "1"
        ]
        guard !environment.isEmpty else { return result }
        result.merge(environment, uniquingKeysWith: { $1 })
        return result
    }
}

enum WineInterfaceError: Error {
    case invalidResponce
}

enum RegistryType: String {
    case binary = "REG_BINARY"
    case dword = "REG_DWORD"
    case qword = "REG_QWORD"
    case string = "REG_SZ"
}

extension Wine {
    public static let logsFolder = FileManager.default.urls(
        for: .libraryDirectory, in: .userDomainMask
    )[0].appending(path: "Logs").appending(path: Bundle.wynSupportIdentifier)

    public static func makeFileHandle() throws -> FileHandle {
        if !FileManager.default.fileExists(atPath: Self.logsFolder.path) {
            try FileManager.default.createDirectory(at: Self.logsFolder, withIntermediateDirectories: true)
        }

        let dateString = Date.now.ISO8601Format()
        let fileURL = Self.logsFolder.appending(path: dateString).appendingPathExtension("log")
        try "".write(to: fileURL, atomically: true, encoding: .utf8)
        return try FileHandle(forWritingTo: fileURL)
    }
}

extension Wine {
    private enum RegistryKey: String {
        case currentVersion = #"HKLM\Software\Microsoft\Windows NT\CurrentVersion"#
        case macDriver = #"HKCU\Software\Wine\Mac Driver"#
        case desktop = #"HKCU\Control Panel\Desktop"#
    }

    private static func addRegistryKey(
        bottle: Bottle, key: String, name: String, data: String, type: RegistryType
    ) async throws {
        try await runWine(
            ["reg", "add", key, "-v", name, "-t", type.rawValue, "-d", data, "-f"],
            bottle: bottle
        )
    }

    private static func queryRegistryKey(
        bottle: Bottle, key: String, name: String, type: RegistryType
    ) async throws -> String? {
        let output = try await runWine(["reg", "query", key, "-v", name], bottle: bottle)
        let lines = output.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)

        guard let line = lines.first(where: { $0.contains(type.rawValue) }) else { return nil }
        let array = line.split(omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        guard let value = array.last else { return nil }
        return String(value)
    }

    public static func changeBuildVersion(bottle: Bottle, version: Int) async throws {
        try await addRegistryKey(bottle: bottle, key: RegistryKey.currentVersion.rawValue,
                                name: "CurrentBuild", data: "\(version)", type: .string)
        try await addRegistryKey(bottle: bottle, key: RegistryKey.currentVersion.rawValue,
                                name: "CurrentBuildNumber", data: "\(version)", type: .string)
    }

    public static func winVersion(bottle: Bottle) async throws -> WinVersion {
        let output = try await Wine.runWine(["winecfg", "-v"], bottle: bottle)
        let lines = output.split(whereSeparator: \.isNewline)

        if let lastLine = lines.last {
            let winString = String(lastLine)

            if let version = WinVersion(rawValue: winString) {
                return version
            }
        }

        throw WineInterfaceError.invalidResponce
    }

    public static func buildVersion(bottle: Bottle) async throws -> String? {
        return try await Wine.queryRegistryKey(
            bottle: bottle, key: RegistryKey.currentVersion.rawValue,
            name: "CurrentBuild", type: .string
        )
    }

    public static func retinaMode(bottle: Bottle) async throws -> Bool {
        let values: Set<String> = ["y", "n"]
        guard let output = try await Wine.queryRegistryKey(
            bottle: bottle, key: RegistryKey.macDriver.rawValue, name: "RetinaMode", type: .string
        ), values.contains(output) else {
            try await changeRetinaMode(bottle: bottle, retinaMode: false)
            return false
        }
        return output == "y"
    }

    public static func changeRetinaMode(bottle: Bottle, retinaMode: Bool) async throws {
        try await Wine.addRegistryKey(
            bottle: bottle, key: RegistryKey.macDriver.rawValue, name: "RetinaMode", data: retinaMode ? "y" : "n",
            type: .string
        )
    }

    public static func dpiResolution(bottle: Bottle) async throws -> Int? {
        guard let output = try await Wine.queryRegistryKey(bottle: bottle, key: RegistryKey.desktop.rawValue,
                                                     name: "LogPixels", type: .dword
        ) else { return nil }

        let noPrefix = output.replacingOccurrences(of: "0x", with: "")
        let int = Int(noPrefix, radix: 16)
        guard let int = int else { return nil }
        return int
    }

    public static func changeDpiResolution(bottle: Bottle, dpi: Int) async throws {
        try await Wine.addRegistryKey(
            bottle: bottle, key: RegistryKey.desktop.rawValue, name: "LogPixels", data: String(dpi),
            type: .dword
        )
    }

    @discardableResult
    public static func control(bottle: Bottle) async throws -> String {
        return try await Wine.runWine(["control"], bottle: bottle)
    }

    @discardableResult
    public static func regedit(bottle: Bottle) async throws -> String {
        return try await Wine.runWine(["regedit"], bottle: bottle)
    }

    @discardableResult
    public static func cfg(bottle: Bottle) async throws -> String {
        return try await Wine.runWine(["winecfg"], bottle: bottle)
    }

    @discardableResult
    public static func changeWinVersion(bottle: Bottle, win: WinVersion) async throws -> String {
        return try await Wine.runWine(["winecfg", "-v", win.rawValue], bottle: bottle)
    }
}
