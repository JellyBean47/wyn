//
//  StorefrontLauncher.swift
//  WynKit
//
//  Frankea spawn for Epic / EA / Battle.net / GOG. Installers stay thin
//  (no graphics DLLs) except EA, Battle.net, and GOG — those Setup exes launch
//  the store at the end, so the child must already have DXVK + winedbg.exe=d.
//  Play deploys DXVK-macOS so Unreal/CEF/Qt get a real D3D11 device — Wine's
//  default GeForce 6800 wined3d fails CreateDevice (or GL context activate)
//  and Epic then dies in CrashReportClient + winedbg. Epic's Slate splash
//  can still hang after that: CEF ANGLE's GPU process dies and login never
//  paints — Play forces r.CEFGPUAcceleration=0 (software CEF).
//
//  Never run ProgramData `UpdateInstall\Portal\Extras\Win64\EpicGamesLauncher.exe`
//  (self-update extras stub) as the store — that binary R6025s (pure virtual)
//  under Wine. Play the committed `Portal\Binaries\Win64` copy (EOSSDK beside
//  it). `-noselfupdate` stops the portal from spawning that extras helper.
//  Keep that flag: RESTART AND INSTALL is Epic's EOS self-update flow, which
//  otherwise exits the UI and tries to apply via UpdateInstall extras.
//  Satisfy EOS by staging `Epic Online Services` + HKLM MainService Version
//  (the quiet installer crashes in a .NET telemetry custom action). GUID + a
//  named Job Object (`Global\{EOS_SESSION_GUID}`) keep UserHelper listening;
//  Host SCM does not create that job under Wine (exit 91, then 52).
//
//  EA App: software Qt Quick + Connect CEF flags still left an opaque navy
//  login (12:15). Play injects Connect's FLY4 present (same x86_64 epi dylib;
//  Unix win32u.so is shared by PE32 Connect and PE32+ EA). 13:15 cocoa-fast
//  hid WineMetalView from updateLayer and collapsed the HWND to 0×0 (dock
//  ghost). Play relaunches if that window is missing. Never `--disable-gpu`.
//  Never wineserver -k the Steam bottle. Connect launcher is unchanged.
//
//  Battle.net: Qt chrome (logo) paints via D3D11. Login is CEF. Wyn runs
//  the official client (Wine 11 + Auto/DXVK/DXMT). 13:45/14:05 CEF flag
//  guesses failed. Round 1 stock ANGLE died SwANGLE. Round 2 DXMT D3D11 works
//  then `CreateSwapChain: cross-process swapchain not supported`. Round 3
//  `--in-process-gpu` stopped the swapchain error but blanked the Qt logo and
//  the renderer still aborted (`0x80000003` at 6DD700E1). Play keeps DXMT +
//  Connect FLY4 (`FLY_COCOA_FAST=0`) and NOPs DXMT's cross-process
//  CreateSwapChain JNE (quoted 7556caa check). Round 5 then hit
//  `Failed to create metal view… no exported symbols needed by DXMT`.
//  3Shain/dxmt#170: Wine 11 dlopen(RTLD_NOW) hides `macdrv_functions` from
//  `dlsym(RTLD_DEFAULT)`. Play inserts `winemac_rtld_global.dylib` so
//  frankea's already-exported macdrv_functions table is visible. Round 7: that table's
//  get_win_data is process-local; the dylib shims #166 GET_SURFACE
//  (`macdrv_client_surface_create`) for a foreign HWND. No extra Chromium flags.
//  Not GPTK / D3DMetal / SwiftShader.
//

import CoreGraphics
import Darwin
import Foundation

public enum StorefrontLauncher {
    /// Native DXVK + no Wine debugger. `n,b` matches the frankea ACO path.
    /// `d3d12=d` is correct for Epic/EA/Battle.net. GOG's Qt6Gui.dll *imports*
    /// d3d12.dll — disabled means GalaxyClient exits c0000135 in ~5s.
    private static let storefrontDllOverrides =
        "winemenubuilder.exe=d;winedbg.exe=d;d3d11,dxgi,d3d10core=n,b;d3d12=d"

    /// Same as storefront, but Wine builtin d3d12 so Qt6Gui can load.
    private static let gogDllOverrides =
        "winemenubuilder.exe=d;winedbg.exe=d;d3d11,dxgi,d3d10core=n,b;d3d12=b"

    /// Connect's proven CEF recipe, applied to EADesktop.exe.
    /// `--disable-gpu-compositing` avoids D3D NT shared textures.
    /// `--in-process-gpu` keeps ANGLE in-process. SwiftShader is the
    /// raster path. Do **not** pass `--disable-gpu` (Connect: alpha-0;
    /// EA already self-fell-back to `--use-gl=disabled` and stayed blank).
    private static let eaCefSoftwarePaintArgs = [
        "--disable-gpu-compositing",
        "--in-process-gpu",
        "--use-gl=angle",
        "--use-angle=swiftshader-webgl"
    ]

    public static func launch(kind: PlatformKind, in bottle: Bottle) async throws {
        guard PlatformKind.installableStorefronts.contains(kind) else {
            throw PlatformLaunchError.notWired(kind)
        }
        // Official EGL (16:19) and Galaxy (17:04) are parked. Both are Heroic.
        if kind == .epic || kind == .gog {
            try await HeroicLauncher.ensureAndOpen()
            return
        }
        guard let exe = PlatformCatalog.exeURL(kind: kind, in: bottle) else {
            throw PlatformLaunchError.executableMissing(kind)
        }
        guard WynWineInstaller.isWineInstalled(for: .steam) else {
            throw PlatformLaunchError.wineTreeMissing(.steam)
        }
        if kind == .ea {
            try await launchEAPresent(in: bottle, exe: exe)
            return
        }
        if kind == .battlenet {
            try await launchBattleNetPresent(in: bottle, exe: exe)
            return
        }
        let epicAlreadyUp = kind == .epic && PlatformCatalog.isRunning(kind)
        let eosMissing = kind == .epic && !epicOnlineServicesLooksInstalled(in: bottle)
        let eosPromptUp = kind == .epic && epicLogShowsEOSInstallPrompt(in: bottle)
        let epicNeedsRelaunch = kind == .epic && (
            epicPrefixNeedsReset()
                || eosMissing
                || (epicAlreadyUp && eosPromptUp)
                || (epicAlreadyUp && epicCEFGPUProcessFailed(in: bottle))
        )
        let battlenetNeedsRelaunch = kind == .battlenet && (
            PlatformCatalog.battleNetPrefixNeedsReset(in: bottle)
                || (PlatformCatalog.isRunning(kind) && battleNetCEFGPUProcessFailed(in: bottle))
        )
        let gogNeedsRelaunch = kind == .gog
            && PlatformCatalog.gogPrefixNeedsReset(in: bottle)
        if PlatformCatalog.isRunning(kind)
            && !epicNeedsRelaunch
            && !battlenetNeedsRelaunch
            && !gogNeedsRelaunch {
            return
        }

        // Leftover CrashReportClient / winedbg / extras R6025 hold this prefix.
        // Steam is a different bottle. We no longer use Epic's Windows service,
        // so a dirty prefix (orphan EpicWebHelper, UpdateInstall extras stub)
        // must die before Play — otherwise `wine start` attaches to the old
        // wineserver and the portal's self-update spawns Extras\Win64, which
        // aborts with msvcrt R6025.
        // Battle.net: installer-spawned Battle.net.exe (no DXVK) or winedbg
        // keeps isRunning true — kill this bottle only, then Play with DXVK.
        if kind != .epic || epicNeedsRelaunch {
            if (eosMissing || eosPromptUp) && epicAlreadyUp {
                LaunchProgress.emit("Epic Games Store: installing online services…")
            } else if epicNeedsRelaunch && epicAlreadyUp {
                LaunchProgress.emit("Epic Games Store: splash stuck, restarting…")
            } else if epicNeedsRelaunch {
                LaunchProgress.emit("Epic Games Store: leftover updater, restarting…")
            } else if battlenetNeedsRelaunch {
                if battleNetCEFGPUProcessFailed(in: bottle) {
                    LaunchProgress.emit("Battle.net: splash stuck, restarting…")
                } else {
                    LaunchProgress.emit("Battle.net: leftover crash, restarting…")
                }
            } else if gogNeedsRelaunch {
                LaunchProgress.emit("GOG Galaxy: leftover crash, restarting…")
            }
            try await Wine.killBottleAndWait(bottle: bottle)
        }
        if kind == .battlenet {
            try prepareDXMT(in: bottle)
        } else {
            try prepareDXVK(in: bottle)
        }
        if kind == .gog {
            // prepareDXVK writes prefix-wide d3d12=disabled. Qt6Gui hard-imports
            // d3d12.dll — restore Wine builtin for this bottle only.
            try? Wine.mergeWineRegistryValues(
                bottle: bottle,
                key: #"Software\Wine\DllOverrides"#,
                values: ["d3d12": ("REG_SZ", "builtin")]
            )
        }

        var exeToRun = exe
        if kind == .epic {
            try commitStagedEpicPortalIfNeeded(catalogExe: exe, in: bottle)
            try ensureEpicOnlineServices(in: bottle)
            await startEpicOnlineServicesHost(in: bottle)
            pinEpicCEFSoftwarePaint(in: bottle)
            resetEpicCEFLog(in: bottle)
            exeToRun = epicStoreUIExecutable(catalogExe: exe)
            LaunchProgress.emit("Epic Games Store: opening launcher…")
        }
        if kind == .battlenet {
            resetBattleNetCEFLog(in: bottle)
            LaunchProgress.emit("Battle.net: opening launcher…")
        }
        if kind == .gog {
            prepareGOGFirstRun(in: bottle)
            LaunchProgress.emit("GOG Galaxy: opening launcher…")
        }

        var arguments: [String]
        if kind == .epic {
            // Direct wine path (not `start /unix`): wine's start.exe can
            // create the process via wineserver without this client's env.
            // EGL needs EOS_SESSION_GUID to send x-eos-session-guid /
            // x-epic-machine-secret on POST /installation/reset (14:33 401).
            arguments = [exeToRun.path(percentEncoded: false)]
            arguments.append(contentsOf: [
                "-SkipBuildPatchPrereq",
                "-SaveToUserDir",
                "-Messaging",
                "-epicenv=Prod",
                "-AllowSoftwareRendering",
                "-nocefaccelpaint",
                "-r.CEFGPUAcceleration=0",
                "-noselfupdate"
            ])
        } else {
            arguments = ["start", "/unix", exeToRun.path(percentEncoded: false)]
        }
        var extraEnv = launchEnvironment(kind: kind)
        if kind == .epic {
            let guid = epicEOSSessionGUID(in: bottle)
            extraEnv["EOS_SESSION_GUID"] = guid
            extraEnv["EOSH_REGISTERED_CLIENTS"] = guid
            extraEnv["EOS_CLIENT_DIR"] = #"C:\Program Files\Epic Games\Epic Online Services"#
            extraEnv["USERPROFILE"] = #"C:\users\#(FileManager.default.homeDirectoryForCurrentUser.lastPathComponent)"#
        }
        try spawn(
            wineTree: .steam,
            bottle: bottle,
            arguments: arguments,
            directory: exeToRun.deletingLastPathComponent(),
            extraEnv: extraEnv,
            wait: false
        )
    }

    /// Connect-style FLY4 present on the dedicated EA bottle only.
    /// Direct `wine64 EADesktop.exe` (not `start /unix`) so DYLD lands on the
    /// HWND parent the way Connect launches `upc.exe`.
    private static func launchEAPresent(in bottle: Bottle, exe: URL) async throws {
        guard PlatformCatalog.presentDylibs() != nil else {
            throw PlatformLaunchError.presentDylibsMissing
        }
        let alreadyUp = PlatformCatalog.isRunning(.ea)
        let windowMissing = alreadyUp && !eaHasOnscreenWindow()
        let needsRelaunch = alreadyUp && (
            eaLaunchedWithoutSoftwareCEF() || !eaPresentHookLoaded() || windowMissing
        )
        if alreadyUp && !needsRelaunch {
            return
        }
        if alreadyUp {
            LaunchProgress.emit(windowMissing
                ? "EA App: no window — restarting…"
                : "EA App: applying Connect present…")
            try await Wine.killBottleAndWait(bottle: bottle)
        }
        try prepareDXVK(in: bottle)
        unlinkEAFLY4()
        LaunchProgress.emit("EA App: opening with present…")
        try spawnEAPresent(in: bottle, exe: exe)
    }

    private static let eaFLY4Name = "/fly-ea-stretch-bridge4"

    private static func unlinkEAFLY4() {
        _ = eaFLY4Name.withCString { shm_unlink($0) }
    }

    private static func spawnEAPresent(in bottle: Bottle, exe: URL) throws {
        guard let dylibs = PlatformCatalog.presentDylibs() else {
            throw PlatformLaunchError.presentDylibsMissing
        }
        let wine = Wine.wineBinary(for: .steam).path(percentEncoded: false)
        let prefix = bottle.url.path(percentEncoded: false)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let outDir = Wine.logsFolder.appending(path: "present-ea-\(stamp)")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let logURL = outDir.appending(path: "wine.log")
        FileManager.default.createFile(atPath: logURL.path(percentEncoded: false), contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)

        var env = launchEnvironment(kind: .ea)
        env["DYLD_INSERT_LIBRARIES"] =
            "\(dylibs.epi.path(percentEncoded: false)):\(dylibs.inject.path(percentEncoded: false))"
        env["WINEDEBUG"] = "-all"
        env["WINE_SIMULATE_WRITECOPY"] = "1"
        env["FLY_FAST_PRESENT"] = "1"
        env["FLY_PARENT_PRESENT"] = "1"
        env["FLY_BRIDGE_SHM"] = "0"
        env["FLY_BRIDGE_FILE"] = "0"
        env["FLY_OPTION_B"] = "0"
        env["FLY_SURFACE_MAP"] = "0"
        env["FLY_BRIDGE_SHM4_NAME"] = eaFLY4Name
        env["FLY_COCOA_FAST"] = "1"
        env["PRESENT_FORCE_LOGIN_BRIDGE"] = "0"
        env["PRESENT_FORCE_OPAQUE"] = "0"
        env["PRESENT_FORCE_LOGIN_FILL"] = "0"
        env["PRESENT_FORCE_LOGIN_SYNC"] = "0"
        env["FLY_STRETCH_DUMP"] = "1"
        env["STRETCHBLT_SPY_LOG"] = outDir.appending(path: "spy.log").path(percentEncoded: false)
        env["PRESENT_FORCE_LOG"] = outDir.appending(path: "inject.log").path(percentEncoded: false)
        env["PRESENT_BRIDGE_BGRA"] = "\(prefix)/drive_c/windows/temp/fly-stretch-bridge.bgra"

        var argv = [
            "-x86_64", "env",
            "WINEPREFIX=\(prefix)",
            "WINEESYNC=1"
        ]
        for (key, value) in env.sorted(by: { $0.key < $1.key }) {
            argv.append("\(key)=\(value)")
        }
        argv.append(wine)
        argv.append(exe.lastPathComponent)
        argv.append(contentsOf: eaCefSoftwarePaintArgs)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        process.arguments = argv
        process.currentDirectoryURL = exe.deletingLastPathComponent()
        process.environment = scrubbedMacEnvironment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.qualityOfService = .userInitiated
        try process.run()
        eaSpawned.retain(process)
    }

    /// Connect-style FLY4 present on the dedicated Battle.net bottle only.
    /// Direct `wine64 Battle.net.exe` (not `start /unix`) so DYLD lands on the
    /// HWND parent. `FLY_COCOA_FAST=0` — EA cocoa-fast 0×0 is a different bug.
    /// Keep DXMT. Do not copy `eaCefSoftwarePaintArgs` (Round 3
    /// `--in-process-gpu` blanked the Qt logo).
    private static func launchBattleNetPresent(in bottle: Bottle, exe: URL) async throws {
        guard PlatformCatalog.presentDylibs() != nil,
              PlatformCatalog.winemacRtldGlobalDylib() != nil else {
            throw PlatformLaunchError.presentDylibsMissing
        }
        let alreadyUp = PlatformCatalog.battleNetClientIsUp()
        let needsRelaunch = alreadyUp && (
            PlatformCatalog.battleNetPrefixNeedsReset(in: bottle)
                || battleNetCEFGPUProcessFailed(in: bottle)
        )
        if alreadyUp && !needsRelaunch {
            return
        }
        if alreadyUp {
            LaunchProgress.emit(
                battleNetCEFGPUProcessFailed(in: bottle)
                    ? "Battle.net: splash stuck, restarting…"
                    : "Battle.net: leftover crash, restarting…"
            )
            try await Wine.killBottleAndWait(bottle: bottle)
        }
        try prepareDXMT(in: bottle)
        unlinkBattleNetFLY4()
        resetBattleNetCEFLog(in: bottle)
        LaunchProgress.emit("Battle.net: opening with present…")
        try spawnBattleNetPresent(in: bottle, exe: exe)
    }

    private static let battleNetFLY4Name = "/fly-bnet-stretch-bridge4"

    private static func unlinkBattleNetFLY4() {
        _ = battleNetFLY4Name.withCString { shm_unlink($0) }
    }

    private static func spawnBattleNetPresent(in bottle: Bottle, exe: URL) throws {
        guard let dylibs = PlatformCatalog.presentDylibs(),
              let macdrvExport = PlatformCatalog.winemacRtldGlobalDylib() else {
            throw PlatformLaunchError.presentDylibsMissing
        }
        let wine = Wine.wineBinary(for: .steam).path(percentEncoded: false)
        let prefix = bottle.url.path(percentEncoded: false)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        let outDir = Wine.logsFolder.appending(path: "present-bnet-\(stamp)")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let logHandle = try Wine.makeFileHandle()
        logHandle.writeInfo(for: bottle)

        var env = launchEnvironment(kind: .battlenet)
        env["DYLD_INSERT_LIBRARIES"] =
            "\(macdrvExport.path(percentEncoded: false)):\(dylibs.epi.path(percentEncoded: false)):\(dylibs.inject.path(percentEncoded: false))"
        env["WINEMAC_RTLD_GLOBAL_LOG"] =
            outDir.appending(path: "winemac-rtld-global.log").path(percentEncoded: false)
        env["WINE_SIMULATE_WRITECOPY"] = "1"
        env["FLY_FAST_PRESENT"] = "1"
        env["FLY_PARENT_PRESENT"] = "1"
        env["FLY_BRIDGE_SHM"] = "0"
        env["FLY_BRIDGE_FILE"] = "0"
        env["FLY_OPTION_B"] = "0"
        env["FLY_SURFACE_MAP"] = "0"
        env["FLY_BRIDGE_SHM4_NAME"] = battleNetFLY4Name
        env["FLY_COCOA_FAST"] = "0"
        env["PRESENT_FORCE_LOGIN_BRIDGE"] = "0"
        env["PRESENT_FORCE_OPAQUE"] = "0"
        env["PRESENT_FORCE_LOGIN_FILL"] = "0"
        env["PRESENT_FORCE_LOGIN_SYNC"] = "0"
        env["FLY_STRETCH_DUMP"] = "1"
        env["STRETCHBLT_SPY_LOG"] = outDir.appending(path: "spy.log").path(percentEncoded: false)
        env["PRESENT_FORCE_LOG"] = outDir.appending(path: "inject.log").path(percentEncoded: false)
        env["PRESENT_BRIDGE_BGRA"] = "\(prefix)/drive_c/windows/temp/fly-stretch-bridge.bgra"

        var argv = [
            "-x86_64", "env",
            "WINEPREFIX=\(prefix)",
            "WINEESYNC=1",
            "WINEDEBUG=fixme-all,+loaddll,+seh"
        ]
        for (key, value) in env.sorted(by: { $0.key < $1.key }) {
            argv.append("\(key)=\(value)")
        }
        argv.append(wine)
        argv.append(exe.lastPathComponent)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        process.arguments = argv
        process.currentDirectoryURL = exe.deletingLastPathComponent()
        process.environment = scrubbedMacEnvironment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.qualityOfService = .userInitiated
        try process.run()
        battleNetSpawned.retain(process)
    }

    /// Drop inherited Wine/GPTK/Steam/Connect vars so EA cannot pick up the Steam bottle.
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

    /// Wine dock icon can stay up while the “EA” HWND is 0×0 / off-screen
    /// (cocoa-fast hid WineMetalView in an updateLayer loop). Play must not
    /// treat that as a healthy session.
    private static func eaHasOnscreenWindow() -> Bool {
        let opts = CGWindowListOption(arrayLiteral: .optionAll)
        guard let wins = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for w in wins {
            let owner = (w[kCGWindowOwnerName as String] as? String ?? "").lowercased()
            guard owner.contains("wine") else { continue }
            let title = (w[kCGWindowName as String] as? String ?? "").lowercased()
            let bounds = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
            let width = bounds["Width"] ?? 0
            let height = bounds["Height"] ?? 0
            let onscreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false
            let loginSized = width >= 400 && width <= 900 && height >= 500 && height <= 1100
            let titledEA = title == "ea" && width >= 200 && height >= 400
            if (loginSized || titledEA) && (onscreen || width * height >= 80_000) {
                return true
            }
        }
        return false
    }

    /// True when the FLY4 dylib is mapped into EADesktop (not EACefSubProcess).
    private static func eaPresentHookLoaded() -> Bool {
        let ps = PlatformCatalog.captureProcessOutput(
            executable: "/bin/ps",
            arguments: ["-axo", "pid=,command="]
        )
        for raw in ps.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            let lower = line.lowercased()
            guard lower.contains("eadesktop.exe"), !lower.contains("eacefsubprocess") else {
                continue
            }
            let pid = line.trimmingCharacters(in: .whitespaces).prefix(while: { $0.isNumber })
            guard !pid.isEmpty else { continue }
            let lsof = PlatformCatalog.captureProcessOutput(
                executable: "/usr/sbin/lsof",
                arguments: ["-p", String(pid), "-Fn"]
            )
            if lsof.contains("fly_stretch_epi") {
                return true
            }
        }
        return false
    }

    /// `wine64 <unix path>` or `wine64 msiexec /i <msi>` — waits for the installer process.
    public static func runInstaller(
        at installer: URL,
        in bottle: Bottle,
        extraEnv: [String: String] = [:]
    ) throws {
        guard WynWineInstaller.isWineInstalled(for: .steam) else {
            throw PlatformLaunchError.wineTreeMissing(.steam)
        }
        let path = installer.path(percentEncoded: false)
        let args: [String]
        if installer.pathExtension.lowercased() == "msi" {
            args = ["msiexec", "/i", path]
        } else {
            args = [path]
        }
        try spawn(
            wineTree: .steam,
            bottle: bottle,
            arguments: args,
            directory: installer.deletingLastPathComponent(),
            extraEnv: extraEnv,
            wait: true
        )
    }

    public static func prepareStoreGraphics(in bottle: Bottle) throws {
        try prepareDXVK(in: bottle)
    }

    public static func wineboot(in bottle: Bottle) throws {
        guard WynWineInstaller.isWineInstalled(for: .steam) else {
            throw PlatformLaunchError.wineTreeMissing(.steam)
        }
        try spawn(
            wineTree: .steam,
            bottle: bottle,
            arguments: ["wineboot", "-u"],
            directory: nil,
            wait: true
        )
    }

    /// MSI / bootstrap leaves `EpicGamesBootstrapLauncher` at Program Files.
    /// After verify, the real store UI is staged under ProgramData — the Windows
    /// service is supposed to copy it over and CreateProcess it. We skip that
    /// handoff: merge the staged tree into Program Files (no `--delete`, so
    /// MSI-only ICU data stays), then run the portal binary.
    private static func commitStagedEpicPortalIfNeeded(catalogExe: URL, in bottle: Bottle) throws {
        let fm = FileManager.default
        let stagedRoot = bottle.url
            .appending(path: "drive_c")
            .appending(path: "ProgramData")
            .appending(path: "Epic")
            .appending(path: "EpicGamesLauncher")
            .appending(path: "Data")
            .appending(path: "Update")
            .appending(path: "Install")
        let stagedExe = stagedRoot
            .appending(path: "Portal")
            .appending(path: "Binaries")
            .appending(path: "Win64")
            .appending(path: "EpicGamesLauncher.exe")
        guard fm.fileExists(atPath: stagedExe.path(percentEncoded: false)) else { return }

        // EOS lives next to the Win64 UI, not the Win32 stub catalog used to prefer.
        let committedWin64 = epicCommittedWin64Portal(from: catalogExe)
        let committedEOS = committedWin64.deletingLastPathComponent()
            .appending(path: "EOSSDK-Win64-Shipping.dll")
        if fm.fileExists(atPath: committedEOS.path(percentEncoded: false)) {
            return
        }

        // Portal/Binaries/Win64/EpicGamesLauncher.exe → Launcher/
        let launcherRoot = committedWin64
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        LaunchProgress.emit("Epic Games Store: applying staged launcher…")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        process.arguments = [
            "-a",
            stagedRoot.path(percentEncoded: false) + "/",
            launcherRoot.path(percentEncoded: false) + "/"
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw PlatformLaunchError.executableMissing(.epic)
        }
    }

    /// Real store UI only: `Portal/Binaries/Win64` with EOSSDK beside it.
    /// Never Extras, never `UpdateInstall` (one word), never Engine bootstrap.
    /// Staged `Update/Install/Portal/Binaries` in place R6025s (no ICU) — rsync
    /// first via `commitStagedEpicPortalIfNeeded`, then run Program Files.
    private static func epicStoreUIExecutable(catalogExe: URL) -> URL {
        let committed = epicCommittedWin64Portal(from: catalogExe)
        if isEpicPortalBinariesUI(committed) {
            return committed
        }
        if isEpicPortalBinariesUI(catalogExe) {
            return catalogExe
        }
        return committed
    }

    /// Catalog used to return `Portal/Binaries/Win32`. The 52 MB UI + EOSSDK
    /// are always in the sibling `Win64` folder after a successful rsync.
    private static func epicCommittedWin64Portal(from catalogExe: URL) -> URL {
        let dir = catalogExe.deletingLastPathComponent()
        if dir.lastPathComponent.lowercased() == "win64" {
            return catalogExe
        }
        return dir.deletingLastPathComponent()
            .appending(path: "Win64")
            .appending(path: "EpicGamesLauncher.exe")
    }

    private static func isEpicPortalBinariesUI(_ exe: URL) -> Bool {
        let path = exe.path(percentEncoded: false).lowercased()
        if path.contains("updateinstall") { return false }
        if path.contains("/extras/") || path.contains("\\extras\\") { return false }
        let win64Portal =
            path.contains("/portal/binaries/win64/")
            || path.contains("\\portal\\binaries\\win64\\")
        guard win64Portal else { return false }
        let eos = exe.deletingLastPathComponent()
            .appending(path: "EOSSDK-Win64-Shipping.dll")
        return FileManager.default.fileExists(atPath: eos.path(percentEncoded: false))
    }

    /// EOSH 5.5.0 from `Portal/Extras/EOS`. The quiet bundle crashes in a
    /// wine-mono telemetry custom action; Play stages the admin-extracted
    /// tree and pins HKLM MainService Version (≥ `EoshMinimumVersion` 5.3.0).
    /// Version alone is not enough: the store then POSTs
    /// `http://localhost:<eosh-port>/api/v1/installation/reset`. No Host →
    /// empty port → localhost:80 → `ResetFailed` → InstallEOS prompt.
    private static let epicEOSHVersion = "5.5.0-56007593+++UE5+Release-EOSH-5.5-55e314"
    private static let epicEOSProductCode = "{D01707D2-55CA-4525-A8A8-5E53AC9C7B06}"

    private static func epicOnlineServicesRoot(in bottle: Bottle) -> URL {
        bottle.url
            .appending(path: "drive_c")
            .appending(path: "Program Files")
            .appending(path: "Epic Games")
            .appending(path: "Epic Online Services")
    }

    private static func epicEOSHostURL(in bottle: Bottle) -> URL {
        epicOnlineServicesRoot(in: bottle)
            .appending(path: "service")
            .appending(path: "EpicOnlineServicesHost.exe")
    }

    private static func epicStagedEOSRoot(in bottle: Bottle) -> URL {
        bottle.url
            .appending(path: "drive_c")
            .appending(path: "fly")
            .appending(path: "eos-admin")
            .appending(path: "PFiles")
            .appending(path: "Epic Games")
            .appending(path: "Epic Online Services")
    }

    private static func epicOnlineServicesLooksInstalled(in bottle: Bottle) -> Bool {
        let host = epicEOSHostURL(in: bottle).path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: host) else { return false }
        let systemReg = (try? String(
            contentsOf: bottle.url.appending(path: "system.reg"),
            encoding: .utf8
        )) ?? ""
        return systemReg.contains("Epic Games\\\\EOS\\\\MainService")
            && systemReg.contains("\"Version\"=\"5.")
    }

    /// Current portal session still thinks EOSH is missing (started before
    /// install) or disabled itself after `ResetFailed` (Host not listening).
    private static func epicLogShowsEOSInstallPrompt(in bottle: Bottle) -> Bool {
        for logs in epicSavedConfigDirs(in: bottle, leaf: "Logs") {
            let log = logs.appending(path: "EpicGamesLauncher.log")
            guard let text = try? String(contentsOf: log, encoding: .utf8) else { continue }
            let prompted = text.contains("Showing InstallEOS prompt")
                || text.contains("EoshDisabledReason = ResetFailed")
                || text.contains("Machine secret header is missing or invalid")
            if prompted, !text.contains("GetInstallations is up to date") {
                return true
            }
        }
        return false
    }

    /// Stage EOSH into Program Files and pin the version + Wine SCM key.
    /// Do this while the Epic wineserver is down so `system.reg` sticks.
    private static func ensureEpicOnlineServices(in bottle: Bottle) throws {
        try stageEpicOnlineServicesFiles(in: bottle)
        try pinEpicOnlineServicesRegistry(in: bottle)
        try runEpicOnlineServicesInstallerIfNeeded(in: bottle)
    }

    private static func stageEpicOnlineServicesFiles(in bottle: Bottle) throws {
        let fm = FileManager.default
        let dest = epicOnlineServicesRoot(in: bottle)
        let destHost = epicEOSHostURL(in: bottle)
        if fm.fileExists(atPath: destHost.path(percentEncoded: false)) {
            return
        }
        let staged = epicStagedEOSRoot(in: bottle)
        let stagedHost = staged
            .appending(path: "service")
            .appending(path: "EpicOnlineServicesHost.exe")
        guard fm.fileExists(atPath: stagedHost.path(percentEncoded: false)) else {
            return
        }
        LaunchProgress.emit("Epic Games Store: installing online services…")
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        process.arguments = [
            "-a",
            staged.path(percentEncoded: false) + "/",
            dest.path(percentEncoded: false) + "/"
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw PlatformLaunchError.executableMissing(.epic)
        }
    }

    private static func pinEpicOnlineServicesRegistry(in bottle: Bottle) throws {
        let hostPath = "C:/Program Files/Epic Games/Epic Online Services/service/EpicOnlineServicesHost.exe"
        let values: [String: (String, String)] = [
            "Version": ("REG_SZ", epicEOSHVersion),
            "ProductVersion": ("REG_SZ", "5.5.0"),
            "InstallDir": ("REG_SZ", "C:/Program Files/Epic Games/Epic Online Services"),
            "ImagePath": ("REG_SZ", hostPath),
            "Port": ("REG_DWORD", "35783")
        ]
        try Wine.upsertWineRegistryValues(
            bottle: bottle,
            key: #"Software\Epic Games\EOS\MainService"#,
            values: values,
            machine: true
        )
        try Wine.upsertWineRegistryValues(
            bottle: bottle,
            key: #"Software\Wow6432Node\Epic Games\EOS\MainService"#,
            values: values,
            machine: true
        )
        try Wine.upsertWineRegistryValues(
            bottle: bottle,
            key: #"Software\Epic Games\EOS\RegisteredProducts\EpicGamesLauncher"#,
            values: ["Version": ("REG_SZ", "5.5.0")],
            machine: true
        )
        try Wine.upsertWineRegistryValues(
            bottle: bottle,
            key: #"Software\Wow6432Node\Epic Games\EOS\RegisteredProducts\EpicGamesLauncher"#,
            values: ["Version": ("REG_SZ", "5.5.0")],
            machine: true
        )
        let uninstall: [String: (String, String)] = [
            "DisplayName": ("REG_SZ", "Epic Online Services"),
            "DisplayVersion": ("REG_SZ", "5.5.0"),
            "Publisher": ("REG_SZ", "Epic Games, Inc."),
            "InstallLocation": ("REG_SZ", "C:/Program Files/Epic Games/Epic Online Services")
        ]
        try Wine.upsertWineRegistryValues(
            bottle: bottle,
            key: #"Software\Microsoft\Windows\CurrentVersion\Uninstall\#(epicEOSProductCode)"#,
            values: uninstall,
            machine: true
        )
        try Wine.upsertWineRegistryValues(
            bottle: bottle,
            key: #"Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\#(epicEOSProductCode)"#,
            values: uninstall,
            machine: true
        )
        try Wine.upsertWineRegistryValues(
            bottle: bottle,
            key: #"Software\Epic Games\EOS\UserHelper"#,
            values: [
                "Path": ("REG_SZ", "C:/Program Files/Epic Games/Epic Online Services/EpicOnlineServicesUserHelper.exe")
            ],
            machine: true
        )
        try Wine.upsertWineRegistryValues(
            bottle: bottle,
            key: #"Software\Wow6432Node\Epic Games\EOS\UserHelper"#,
            values: [
                "Path": ("REG_SZ", "C:/Program Files/Epic Games/Epic Online Services/EpicOnlineServicesUserHelper.exe")
            ],
            machine: true
        )
        // Same SCM shape as EpicGamesUpdater. Host.exe `install` CreateService
        // name is `EpicOnlineServices`. Wine often fails StartService; Play
        // still tries `net start` then falls back to UserHelper.exe.
        try Wine.upsertWineRegistryValues(
            bottle: bottle,
            key: #"System\ControlSet001\Services\EpicOnlineServices"#,
            values: [
                "Description": ("REG_SZ", "Runs background processes for applications using Epic Games services"),
                "DisplayName": ("REG_SZ", "Epic Online Services"),
                "ErrorControl": ("REG_DWORD", "1"),
                "ImagePath": ("REG_SZ", hostPath),
                "ObjectName": ("REG_SZ", "LocalSystem"),
                "Start": ("REG_DWORD", "3"),
                "Type": ("REG_DWORD", "16")
            ],
            machine: true
        )
    }

    /// 13:55: UserHelper exit 91 without `EOS_SESSION_GUID` → empty Port → :80.
    /// 14:03: GUID passed, API up on 35783, then MainService exit 52:
    /// `OpenJobObject: [ErrorCode=2] File not found` for `Global\{guid}`.
    /// 14:33/15:51: job object OK; EGL POST reset 401 without x-epic-machine-secret.
    /// 16:02: reset can succeed; keep-alive/pipelined GET /installations then
    /// 401 because the proxy injected only the first request on the socket.
    /// Occupy 35783 with a header-injecting proxy so EOSH binds 35784+.
    private static let epicEOSHListenPorts = 35783...35791
    private static let epicEOSHProxyPort = 35783
    private static let epicEOSHUpstreamPorts = 35784...35791

    private static func startEpicOnlineServicesHost(in bottle: Bottle) async {
        let helper = epicOnlineServicesRoot(in: bottle)
            .appending(path: "EpicOnlineServicesUserHelper.exe")
        guard FileManager.default.fileExists(atPath: helper.path(percentEncoded: false)) else {
            return
        }
        ensureEpicMachineSecret(in: bottle)
        if epicUserHelperIsRunning() {
            if epicEOSHUpstreamPort() != nil {
                pinEpicEOSHPort(epicEOSHProxyPort, in: bottle)
                return
            }
            if let port = epicEOSHListeningPort() {
                pinEpicEOSHPort(port, in: bottle)
                return
            }
        }
        LaunchProgress.emit("Epic Games Store: starting online services…")
        let guid = epicEOSSessionGUID(in: bottle)
        var env = launchEnvironment(kind: .epic)
        env["EOS_SESSION_GUID"] = guid
        env["EOSH_REGISTERED_CLIENTS"] = guid
        env["EOS_CLIENT_DIR"] = #"C:\Program Files\Epic Games\Epic Online Services"#
        env["USERPROFILE"] = #"C:\users\#(FileManager.default.homeDirectoryForCurrentUser.lastPathComponent)"#
        startEpicSecretProxy(in: bottle)
        try? await Task.sleep(for: .milliseconds(250))
        await ensureEpicJobObject(in: bottle, env: env)
        _ = try? spawn(
            wineTree: .steam,
            bottle: bottle,
            arguments: [helper.path(percentEncoded: false)],
            directory: helper.deletingLastPathComponent(),
            extraEnv: env,
            wait: false
        )
        for _ in 0..<60 {
            if epicEOSHUpstreamPort() != nil {
                try? await Task.sleep(for: .milliseconds(800))
                if epicEOSHUpstreamPort() != nil {
                    pinEpicEOSHPort(epicEOSHProxyPort, in: bottle)
                    try? await Task.sleep(for: .milliseconds(1500))
                    pinEpicEOSHPort(epicEOSHProxyPort, in: bottle)
                    return
                }
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        if let port = epicEOSHListeningPort() {
            pinEpicEOSHPort(port, in: bottle)
        }
    }

    private static func epicUserHelperIsRunning() -> Bool {
        epicProcessCommandLines().contains {
            $0.lowercased().contains("epiconlineservicesuserhelper")
        }
    }

    private static func epicEOSHUpstreamPort() -> Int? {
        for port in epicEOSHUpstreamPorts where epicTCPPortOpen(port) {
            return port
        }
        return nil
    }

    private static func stopEpicSecretProxy() {
        let out = PlatformCatalog.captureProcessOutput(
            executable: "/usr/bin/pgrep",
            arguments: ["-f", "eos-secret-proxy.py"]
        )
        for line in out.split(whereSeparator: \.isNewline) {
            let pid = Int32(line.trimmingCharacters(in: .whitespaces)) ?? 0
            if pid > 1 {
                kill(pid, SIGTERM)
            }
        }
    }

    /// EGL POSTs reset without `x-epic-machine-secret` (401). Bind 35783 on the
    /// Mac so EOSH takes 35784+, inject the header on every keep-alive request.
    private static func startEpicSecretProxy(in bottle: Bottle) {
        stopEpicSecretProxy()
        let script = epicRepoRoot().appending(path: "Tools/eos-secret-proxy.py")
        guard FileManager.default.fileExists(atPath: script.path(percentEncoded: false)) else {
            return
        }
        let secret = epicOnlineServicesRoot(in: bottle).appending(path: "machine-secret")
        let guidFile = bottle.url
            .appending(path: "drive_c")
            .appending(path: "fly")
            .appending(path: "eos-session-guid")
        let logURL = URL(fileURLWithPath: "/tmp/eos-proxy.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try? FileHandle(forWritingTo: logURL)
        try? logHandle?.seekToEnd()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            script.path(percentEncoded: false),
            "--listen", "\(epicEOSHProxyPort)",
            "--upstream-first", "\(epicEOSHUpstreamPorts.lowerBound)",
            "--upstream-last", "\(epicEOSHUpstreamPorts.upperBound)",
            "--secret-file", secret.path(percentEncoded: false),
            "--guid-file", guidFile.path(percentEncoded: false)
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = logHandle ?? FileHandle.nullDevice
        process.standardError = logHandle ?? FileHandle.nullDevice
        process.qualityOfService = .userInitiated
        try? process.run()
    }

    /// UserHelper OpenJobObject `Global\{EOS_SESSION_GUID}`. Missing object →
    /// exit 52. A tiny PE creates the job and stays assigned so EOSH's
    /// 10s InitialWaitForClients does not see an empty process group.
    private static func ensureEpicJobObject(
        in bottle: Bottle,
        env: [String: String]
    ) async {
        guard let holder = installEpicJobHolder(in: bottle) else { return }
        let fly = bottle.url.appending(path: "drive_c").appending(path: "fly")
        let ready = fly.appending(path: "eos-job-ready")
        try? FileManager.default.removeItem(at: ready)
        _ = try? spawn(
            wineTree: .steam,
            bottle: bottle,
            arguments: [holder.path(percentEncoded: false)],
            directory: fly,
            extraEnv: env,
            wait: false
        )
        for _ in 0..<25 {
            if FileManager.default.fileExists(atPath: ready.path(percentEncoded: false)) {
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private static func installEpicJobHolder(in bottle: Bottle) -> URL? {
        let dest = bottle.url
            .appending(path: "drive_c")
            .appending(path: "fly")
            .appending(path: "eos-job-hold.exe")
        let destPath = dest.path(percentEncoded: false)
        try? FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let bundled = epicJobHolderSourceExe(),
           FileManager.default.fileExists(atPath: bundled.path(percentEncoded: false)) {
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: bundled, to: dest)
        } else if !FileManager.default.fileExists(atPath: destPath) {
            compileEpicJobHolder(to: dest)
        }
        guard FileManager.default.fileExists(atPath: destPath) else { return nil }
        return dest
    }

    private static func epicRepoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func epicJobHolderSourceExe() -> URL? {
        let url = epicRepoRoot().appending(path: "Tools/bin/eos-job-hold.exe")
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
            ? url : nil
    }

    private static func compileEpicJobHolder(to dest: URL) {
        let src = epicRepoRoot().appending(path: "Tools/eos-job-hold.c")
        guard FileManager.default.fileExists(atPath: src.path(percentEncoded: false)) else {
            return
        }
        let gcc = "/opt/homebrew/bin/x86_64-w64-mingw32-gcc"
        guard FileManager.default.isExecutableFile(atPath: gcc) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gcc)
        process.arguments = [
            "-O2", "-mwindows",
            "-o", dest.path(percentEncoded: false),
            src.path(percentEncoded: false)
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private static func epicEOSSessionGUID(in bottle: Bottle) -> String {
        let file = bottle.url
            .appending(path: "drive_c")
            .appending(path: "fly")
            .appending(path: "eos-session-guid")
        if let existing = try? String(contentsOf: file, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let guid = UUID().uuidString
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? guid.write(to: file, atomically: true, encoding: .utf8)
        return guid
    }

    private static func ensureEpicMachineSecret(in bottle: Bottle) {
        let file = epicOnlineServicesRoot(in: bottle).appending(path: "machine-secret")
        let hex: String
        if let existing = try? String(contentsOf: file, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            hex = trimmed.isEmpty
                ? (UUID().uuidString + UUID().uuidString)
                    .replacingOccurrences(of: "-", with: "")
                    .lowercased()
                : trimmed
            if trimmed.isEmpty {
                try? hex.write(to: file, atomically: true, encoding: .utf8)
            }
        } else {
            hex = (UUID().uuidString + UUID().uuidString)
                .replacingOccurrences(of: "-", with: "")
                .lowercased()
            try? hex.write(to: file, atomically: true, encoding: .utf8)
        }
        // EGL looks for `%USERPROFILE%\.eosh\machine-secret` (Node EOSH)
        // and `Epic Online Services\machine-secret` (Unreal). Copy both.
        let users = bottle.url.appending(path: "drive_c").appending(path: "users")
        let names = (try? FileManager.default.contentsOfDirectory(
            at: users,
            includingPropertiesForKeys: nil
        )) ?? []
        for userDir in names {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: userDir.path(percentEncoded: false),
                isDirectory: &isDir
            ), isDir.boolValue else { continue }
            let leaf = userDir.lastPathComponent.lowercased()
            if leaf == "public" || leaf == "default" || leaf.hasPrefix("default ") {
                continue
            }
            for hidden in [".eosh", ".eos"] {
                let dir = userDir.appending(path: hidden)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? hex.write(
                    to: dir.appending(path: "machine-secret"),
                    atomically: true,
                    encoding: .utf8
                )
            }
        }
    }

    private static func epicEOSHListeningPort() -> Int? {
        for port in epicEOSHListenPorts where epicTCPPortOpen(port) {
            return port
        }
        return nil
    }

    private static func epicTCPPortOpen(_ port: Int) -> Bool {
        epicTCP4PortOpen(port) || epicTCP6PortOpen(port)
    }

    private static func epicTCP4PortOpen(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                connect(fd, pointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// EOSH Node `listen` bound `::1:35783` (14:03). IPv4-only wait can miss it.
    private static func epicTCP6PortOpen(_ port: Int) -> Bool {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = in_port_t(UInt16(port).bigEndian)
        addr.sin6_addr = in6addr_loopback
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                connect(fd, pointer, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        return result == 0
    }

    /// Live wineserver is up (UserHelper started it). `reg add` so the
    /// launcher reads Port before reset; file-edit of system.reg would lose.
    /// EOSH itself writes HKCU; Play also pins HKLM (13:56 empty HKLM → :80).
    private static func pinEpicEOSHPort(_ port: Int, in bottle: Bottle) {
        let env = launchEnvironment(kind: .epic)
        for key in [
            #"HKLM\Software\Epic Games\EOS\MainService"#,
            #"HKLM\Software\Wow6432Node\Epic Games\EOS\MainService"#,
            #"HKCU\Software\Epic Games\EOS\MainService"#
        ] {
            _ = try? spawn(
                wineTree: .steam,
                bottle: bottle,
                arguments: [
                    "reg", "add", key,
                    "/v", "Port", "/t", "REG_DWORD", "/d", "\(port)", "/f"
                ],
                directory: bottle.url,
                extraEnv: env,
                wait: true
            )
        }
    }

    /// Official bundle: `/install productid=EpicGamesLauncher /quiet`.
    /// Only when Host.exe is still missing. wine-mono often dies in
    /// TelemetrySendStart — files + Version + a running Host are what
    /// the banner actually needs (not the MSI wrapper).
    private static func runEpicOnlineServicesInstallerIfNeeded(in bottle: Bottle) throws {
        let marker = bottle.url
            .appending(path: "drive_c")
            .appending(path: "fly")
            .appending(path: "eos-installed")
        if FileManager.default.fileExists(atPath: epicEOSHostURL(in: bottle).path(percentEncoded: false)) {
            try? "staged".write(to: marker, atomically: true, encoding: .utf8)
            return
        }
        if FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)) {
            return
        }
        let installer = bottle.url
            .appending(path: "drive_c")
            .appending(path: "Program Files")
            .appending(path: "Epic Games")
            .appending(path: "Launcher")
            .appending(path: "Portal")
            .appending(path: "Extras")
            .appending(path: "EOS")
            .appending(path: "EpicOnlineServicesInstaller.exe")
        guard FileManager.default.fileExists(atPath: installer.path(percentEncoded: false)) else {
            try? "missing-installer".write(to: marker, atomically: true, encoding: .utf8)
            return
        }
        LaunchProgress.emit("Epic Games Store: installing online services…")
        _ = try spawn(
            wineTree: .steam,
            bottle: bottle,
            arguments: [
                installer.path(percentEncoded: false),
                "/install",
                "productid=EpicGamesLauncher",
                "/quiet"
            ],
            directory: installer.deletingLastPathComponent(),
            extraEnv: launchEnvironment(kind: .epic),
            wait: true
        )
        try? "attempted".write(to: marker, atomically: true, encoding: .utf8)
    }

    /// CrashReportClient / winedbg, extras R6025 stub, or CEF helper with no portal UI.
    private static func epicPrefixNeedsReset() -> Bool {
        let lowers = epicProcessCommandLines().map { $0.lowercased() }
        if lowers.contains(where: {
            $0.contains("crashreportclient") || $0.contains("winedbg")
        }) {
            return true
        }
        // Wine C++ Runtime Library R6025 on the self-update extras binary.
        // Cancel on that dialog attaches winedbg — treat the extras path itself
        // as stuck so Play kills this prefix (never Steam) without the user
        // pressing Cancel.
        if lowers.contains(where: { epicLineLooksLikeExtrasStub($0) }) {
            return true
        }
        let storeUp = lowers.contains(where: { epicLineLooksLikeStoreUI($0) })
        let orphanHelper = lowers.contains(where: { $0.contains("epicwebhelper.exe") })
        return orphanHelper && !storeUp
    }

    private static func epicProcessCommandLines() -> [String] {
        PlatformCatalog.captureProcessOutput(
            executable: "/bin/ps",
            arguments: ["-ax", "-o", "command="]
        )
        .split(whereSeparator: \.isNewline)
        .map { String($0) }
    }

    private static func epicLineLooksLikeExtrasStub(_ lower: String) -> Bool {
        guard lower.contains("epicgameslauncher.exe") else { return false }
        if lower.contains("updateinstall") { return true }
        return lower.contains("/extras/") || lower.contains("\\extras\\")
    }

    private static func epicLineLooksLikeStoreUI(_ lower: String) -> Bool {
        guard lower.contains("epicgameslauncher.exe") else { return false }
        if lower.contains("commandlet=") || lower.contains("ranasservice") {
            return false
        }
        if epicLineLooksLikeExtrasStub(lower) { return false }
        return lower.contains("portal") && lower.contains("binaries")
    }

    /// Installer / previous Play started EADesktop without software CEF
    /// compositing. Play must restart the EA prefix (never Steam).
    private static func eaLaunchedWithoutSoftwareCEF() -> Bool {
        let commands = PlatformCatalog.captureProcessOutput(
            executable: "/bin/ps",
            arguments: ["-ax", "-o", "command="]
        )
        let desktop = commands.split(whereSeparator: \.isNewline).filter { line in
            let lower = String(line).lowercased()
            return lower.contains("eadesktop.exe") && !lower.contains("eacefsubprocess")
        }
        guard !desktop.isEmpty else { return false }
        return desktop.contains { !String($0).contains("--disable-gpu-compositing") }
    }

    /// Battle.net login CEF GPU process died. Qt logo stays; login fields never
    /// paint. libcef: `Exiting GPU process due to errors during initialization`.
    private static func battleNetCEFGPUProcessFailed(in bottle: Bottle) -> Bool {
        guard let latest = latestBattleNetLog(in: bottle, prefix: "libcef-") else {
            return false
        }
        guard let text = try? String(contentsOf: latest, encoding: .utf8) else {
            return false
        }
        return text.contains("Exiting GPU process due to errors")
            || text.contains("Failed to launch GPU process")
            || text.contains("eglInitialize SwANGLE failed")
            || text.contains("SharedImageStub: unable to create context")
    }

    /// Drop last session's GPU-process death so Play does not loop-kill after
    /// a healthy software-CEF start (libcef-*.log is per-session).
    private static func resetBattleNetCEFLog(in bottle: Bottle) {
        for url in battleNetLogFiles(in: bottle, prefix: "libcef-") {
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func latestBattleNetLog(in bottle: Bottle, prefix: String) -> URL? {
        battleNetLogFiles(in: bottle, prefix: prefix)
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                return da < db
            }
    }

    private static func battleNetLogFiles(in bottle: Bottle, prefix: String) -> [URL] {
        battleNetLocalLogsDirs(in: bottle).flatMap { dir in
            (try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ))?.filter { $0.lastPathComponent.hasPrefix(prefix) } ?? []
        }
    }

    private static func battleNetLocalLogsDirs(in bottle: Bottle) -> [URL] {
        let usersRoot = bottle.url.appending(path: "drive_c").appending(path: "users")
        let skipped: Set<String> = ["Public", "Default", "Default User", "All Users"]
        let users = (try? FileManager.default.contentsOfDirectory(
            at: usersRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return users.compactMap { user in
            let isDir = (try? user.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir, !skipped.contains(user.lastPathComponent) else { return nil }
            let logs = user
                .appending(path: "AppData")
                .appending(path: "Local")
                .appending(path: "Battle.net")
                .appending(path: "Logs")
            var isLogs = ObjCBool(false)
            guard FileManager.default.fileExists(
                atPath: logs.path(percentEncoded: false),
                isDirectory: &isLogs
            ), isLogs.boolValue else {
                return nil
            }
            return logs
        }
    }

    /// Chromium GPU process died (ANGLE DXGI driver-version query). Splash
    /// progress fills, store login never paints, EpicWebHelper renderer spins.
    private static func epicCEFGPUProcessFailed(in bottle: Bottle) -> Bool {
        for logs in epicSavedConfigDirs(in: bottle, leaf: "Logs") {
            let cef = logs.appending(path: "cef3.log")
            guard let text = try? String(contentsOf: cef, encoding: .utf8) else { continue }
            if text.contains("Exiting GPU process due to errors")
                || text.contains("Failed to launch GPU process") {
                return true
            }
        }
        return false
    }

    /// Drop last session's GPU-process death so Play does not loop-kill after
    /// a healthy software-CEF start (cef3.log appends).
    private static func resetEpicCEFLog(in bottle: Bottle) {
        for logs in epicSavedConfigDirs(in: bottle, leaf: "Logs") {
            let cef = logs.appending(path: "cef3.log")
            guard FileManager.default.fileExists(atPath: cef.path(percentEncoded: false)) else {
                continue
            }
            try? "".write(to: cef, atomically: true, encoding: .utf8)
        }
    }

    /// Unreal reads `[ConsoleVariables]` before CEF init. `0` makes
    /// FCEFBrowserApp append `disable-gpu` / `disable-gpu-compositing`
    /// instead of `enable-gpu` (log line "CEF GPU acceleration disabled").
    private static func pinEpicCEFSoftwarePaint(in bottle: Bottle) {
        for dir in epicSavedConfigDirs(in: bottle, leaf: "Config") {
            for platform in ["WindowsEditor", "Windows"] {
                let configDir = dir.appending(path: platform)
                let ini = configDir.appending(path: "Engine.ini")
                try? FileManager.default.createDirectory(
                    at: configDir,
                    withIntermediateDirectories: true
                )
                upsertIniKey(
                    file: ini,
                    section: "[ConsoleVariables]",
                    key: "r.CEFGPUAcceleration",
                    value: "0"
                )
            }
        }
    }

    private static func epicSavedConfigDirs(in bottle: Bottle, leaf: String) -> [URL] {
        let usersRoot = bottle.url.appending(path: "drive_c").appending(path: "users")
        let skipped: Set<String> = ["Public", "Default", "Default User", "All Users"]
        let users = (try? FileManager.default.contentsOfDirectory(
            at: usersRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return users.compactMap { userDir in
            guard !skipped.contains(userDir.lastPathComponent) else { return nil }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: userDir.path(percentEncoded: false),
                isDirectory: &isDir
            ), isDir.boolValue else { return nil }
            return userDir
                .appending(path: "AppData")
                .appending(path: "Local")
                .appending(path: "EpicGamesLauncher")
                .appending(path: "Saved")
                .appending(path: leaf)
        }
    }

    private static func upsertIniKey(file: URL, section: String, key: String, value: String) {
        var lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "")
            .components(separatedBy: "\n")
        let assignment = "\(key)=\(value)"
        var inSection = false
        var sectionStart: Int?
        var keyLine: Int?
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                if inSection { break }
                if trimmed == section {
                    inSection = true
                    sectionStart = index
                }
            } else if inSection, trimmed.lowercased().hasPrefix(key.lowercased() + "=") {
                keyLine = index
            }
        }
        if let keyLine {
            lines[keyLine] = assignment
        } else if let sectionStart {
            lines.insert(assignment, at: sectionStart + 1)
        } else {
            if let last = lines.last, !last.isEmpty {
                lines.append("")
            }
            lines.append(contentsOf: ["; Written by Wyn", section, assignment, ""])
        }
        try? lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    @discardableResult
    public static func spawn(
        wineTree: WineTree,
        bottle: Bottle,
        arguments: [String],
        directory: URL?,
        extraEnv: [String: String] = [:],
        wait: Bool
    ) throws -> Int32 {
        let wine = Wine.wineBinary(for: wineTree).path(percentEncoded: false)
        let prefix = bottle.url.path(percentEncoded: false)
        let logHandle = try Wine.makeFileHandle()
        logHandle.writeInfo(for: bottle)

        var env = ProcessInfo.processInfo.environment
        for key in env.keys {
            let upper = key.uppercased()
            if upper.hasPrefix("WINE") || upper.hasPrefix("CX_") || upper.hasPrefix("STEAM")
                || upper.hasPrefix("VK_") || upper.hasPrefix("D3DM_") || upper.hasPrefix("DYLD_")
                || upper.hasPrefix("FLY_") {
                env.removeValue(forKey: key)
            }
        }

        var argv = [
            "-x86_64", "env",
            "WINEPREFIX=\(prefix)",
            "WINEDEBUG=fixme-all",
            "WINEESYNC=1"
        ]
        for (key, value) in extraEnv.sorted(by: { $0.key < $1.key }) {
            argv.append("\(key)=\(value)")
        }
        argv.append(wine)
        argv.append(contentsOf: arguments)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        process.arguments = argv
        process.currentDirectoryURL = directory ?? bottle.url
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.qualityOfService = .userInitiated
        try process.run()
        if wait {
            process.waitUntilExit()
            return process.terminationStatus
        }
        return 0
    }

    private static func prepareDXVK(in bottle: Bottle) throws {
        try? Wine.upsertWineRegistryValues(
            bottle: bottle,
            key: #"Software\Wine\WineDbg"#,
            values: ["ShowCrashDialog": ("REG_DWORD", "0")]
        )
        // Prefix-wide so installer-spawned children (no WINEDLLOVERRIDES) still
        // skip winedbg and load DXVK from system32. Merge — do not wipe other names.
        try? Wine.mergeWineRegistryValues(
            bottle: bottle,
            key: #"Software\Wine\DllOverrides"#,
            values: [
                "winedbg.exe": ("REG_SZ", "disabled"),
                "winemenubuilder.exe": ("REG_SZ", "disabled"),
                "d3d11": ("REG_SZ", "native,builtin"),
                "dxgi": ("REG_SZ", "native,builtin"),
                "d3d10core": ("REG_SZ", "native,builtin"),
                "d3d12": ("REG_SZ", "disabled")
            ]
        )
        try Wine.enableDXVK(bottle: bottle, wineTree: .steam)
        try Wine.ensureDXVKLogDirectory(bottle: bottle)
        bottle.settings.translationLayer = .dxvk
        bottle.settings.dxvk = true
    }

    /// Wine 11 includes DXMT; 32-bit Battle.net CEF is the documented Mac use.
    /// Copies frankea Steam `DXMT/x32` (winemetal + d3d11/dxgi). Not D3DMetal.
    private static func prepareDXMT(in bottle: Bottle) throws {
        try? Wine.upsertWineRegistryValues(
            bottle: bottle,
            key: #"Software\Wine\WineDbg"#,
            values: ["ShowCrashDialog": ("REG_DWORD", "0")]
        )
        try? Wine.mergeWineRegistryValues(
            bottle: bottle,
            key: #"Software\Wine\DllOverrides"#,
            values: [
                "winedbg.exe": ("REG_SZ", "disabled"),
                "winemenubuilder.exe": ("REG_SZ", "disabled"),
                "d3d11": ("REG_SZ", "native,builtin"),
                "dxgi": ("REG_SZ", "native,builtin"),
                "d3d10core": ("REG_SZ", "native,builtin"),
                "d3d12": ("REG_SZ", "disabled")
            ]
        )
        try Wine.enableDXMT(bottle: bottle)
        try allowDXMTCrossProcessSwapchain(in: bottle)
        bottle.settings.translationLayer = .dxmt
        bottle.settings.dxvk = false
    }

    /// DXMT `7556caa` (`src/d3d11/d3d11_swapchain.cpp`) bails before present:
    /// ```
    /// GetWindowThreadProcessId(hWnd, &window_process_id);
    /// if (GetProcessId(GetCurrentProcess()) != window_process_id) {
    ///   ERR("CreateSwapChain: cross-process swapchain not supported yet");
    ///   return E_FAIL;
    /// }
    /// ```
    /// Battle.net CEF GPU is a different PID from the Qt HWND owner. Wine
    /// HWND is still this prefix's wineserver object. NOP the i386 JNE
    /// (`0f 85 67 01 00 00` @ file 0x23cdb in frankea x32 `d3d11.dll`) so
    /// CreateSwapChain continues. Not `--in-process-gpu`, not SwiftShader,
    /// not GPTK. Shared Steam DXMT payload is not mutated.
    private static func allowDXMTCrossProcessSwapchain(in bottle: Bottle) throws {
        let dll = bottle.url
            .appending(path: "drive_c")
            .appending(path: "windows")
            .appending(path: "syswow64")
            .appending(path: "d3d11.dll")
        var data = try Data(contentsOf: dll)
        let offset = 0x23cdb
        let jne = Data([0x0F, 0x85, 0x67, 0x01, 0x00, 0x00])
        let nops = Data(repeating: 0x90, count: 6)
        guard data.count >= offset + 6 else { return }
        let slice = data.subdata(in: offset..<(offset + 6))
        if slice == nops { return }
        guard slice == jne else { return }
        data.replaceSubrange(offset..<(offset + 6), with: nops)
        try data.write(to: dll, options: .atomic)
    }

    public static func launchEnvironment(kind: PlatformKind = .epic) -> [String: String] {
        var env = [
            "WINEDLLOVERRIDES": storefrontDllOverrides,
            "DXVK_ASYNC": "1",
            "DXVK_LOG_LEVEL": "info",
            "DXVK_LOG_PATH": "C:/fly/logs"
        ]
        env.merge(
            TranslationLayer.dxvk.environmentOverrides(),
            uniquingKeysWith: { current, _ in current }
        )
        if kind == .ea {
            // Qt 5 QSurfaceFormat 2.0 — Wine WGL has no usable GL 2 context.
            // EA already ships libEGL.dll / libGLESv2.dll; point Qt at ANGLE+D3D11.
            env["QT_OPENGL"] = "angle"
            env["QT_ANGLE_PLATFORM"] = "d3d11"
            // ANGLE+DXVK presents a cleared 520×867 swapchain (navy fill) but
            // QML/CEF frames sit on D3D shared textures. Software Quick paints
            // CaptionBar / SpaWebView via QPainter. Keep ANGLE so a leftover
            // GL widget does not regress to the OpenGL 2.0 dialog.
            env["QT_QUICK_BACKEND"] = "software"
            env["QSG_RENDER_LOOP"] = "basic"
        }
        if kind == .battlenet {
            // Battle.net Qt lists renderers d3d11,warp,desktop. ANGLE+D3D11 so
            // chrome uses the same D3D11 device as login CEF (now DXMT).
            env.merge(
                TranslationLayer.dxmt.environmentOverrides(),
                uniquingKeysWith: { current, _ in current }
            )
            env["QT_OPENGL"] = "angle"
            env["QT_ANGLE_PLATFORM"] = "d3d11"
            env["QT_QUICK_BACKEND"] = "software"
            env["QSG_RENDER_LOOP"] = "basic"
        }
        if kind == .gog {
            // Galaxy 2.1 is Qt6 + Qt WebEngine. Same ANGLE+D3D11 as Battle.net
            // so first-run is not wined3d's GeForce 6800.
            // Must not inherit storefront `d3d12=d` — Qt6Gui.dll imports d3d12.
            env["WINEDLLOVERRIDES"] = gogDllOverrides
            env["QT_OPENGL"] = "angle"
            env["QT_ANGLE_PLATFORM"] = "d3d11"
            env["QT_D3D_NO_FLIP"] = "1"
        }
        return env
    }

    /// Galaxy first-run fatals if it tries to *remove* `campaignParamsForLogIn`
    /// from a config that never had the key (installer `/campaign=""`). Also
    /// creates the ProgramData dirs the service failed to set up (error 1053).
    private static func prepareGOGFirstRun(in bottle: Bottle) {
        let fm = FileManager.default
        let driveC = bottle.url.appending(path: "drive_c")
        let dirLists: [[String]] = [
            ["Program Files", "GOG Galaxy", "Games"],
            ["ProgramData", "GOG.com", "Galaxy", "storage"],
            ["ProgramData", "GOG.com", "Galaxy", "support"],
            ["ProgramData", "GOG.com", "Galaxy", "prefetch"],
            ["ProgramData", "GOG.com", "Galaxy", "lock-files"]
        ]
        for components in dirLists {
            let url = components.reduce(driveC) { $0.appending(path: $1) }
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }

        let users = driveC.appending(path: "users")
        let children = (try? fm.contentsOfDirectory(
            at: users,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for userDir in children {
            let isDir = (try? userDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            let name = userDir.lastPathComponent.lowercased()
            if name == "public" || name == "default" || name.hasPrefix("default ") { continue }
            let configDir = userDir
                .appending(path: "AppData")
                .appending(path: "Local")
                .appending(path: "GOG.com")
                .appending(path: "Galaxy")
                .appending(path: "Configuration")
            try? fm.createDirectory(at: configDir, withIntermediateDirectories: true)
            seedGOGCampaignParams(at: configDir.appending(path: "config.json"))
        }
    }

    private static func seedGOGCampaignParams(at config: URL) {
        var object: [String: Any] = [:]
        if let data = try? Data(contentsOf: config),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = parsed
        }
        if object["campaignParamsForLogIn"] != nil { return }
        object["campaignParamsForLogIn"] = [String: Any]()
        guard let out = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? out.write(to: config, options: .atomic)
    }

    private static let eaSpawned = EASpawnedProcesses()
    private static let battleNetSpawned = EASpawnedProcesses()
}

private final class EASpawnedProcesses: @unchecked Sendable {
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
