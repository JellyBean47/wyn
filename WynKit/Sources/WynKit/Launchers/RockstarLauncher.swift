//
//  RockstarLauncher.swift
//  WynKit
//
//  Rockstar Games Launcher in the RDR2 clone bottle on Libraries.rgl.
//  Does not deploy graphics DLLs, does not set SteamAppId, does not kill
//  the Steam bottle, and does not run play-rdr2.sh (that is the game).
//

import Foundation

public enum RockstarLauncher {
    public static func exeURL(in bottle: Bottle) -> URL {
        bottle.url
            .appending(path: "drive_c")
            .appending(path: "Program Files")
            .appending(path: "Rockstar Games")
            .appending(path: "Launcher")
            .appending(path: "Launcher.exe")
    }

    public static func launch(in bottle: Bottle) async throws {
        let fm = FileManager.default
        let exe = exeURL(in: bottle)
        guard fm.fileExists(atPath: exe.path(percentEncoded: false)) else {
            throw PlatformLaunchError.executableMissing(.rockstar)
        }
        guard WynWineInstaller.isWineInstalled(for: .rgl) else {
            throw PlatformLaunchError.wineTreeMissing(.rgl)
        }
        if PlatformCatalog.isRunning(.rockstar) {
            return
        }

        let wine = Wine.wineBinary(for: .rgl).path(percentEncoded: false)
        let prefix = bottle.url.path(percentEncoded: false)
        let logHandle = try Wine.makeFileHandle()

        var env = ProcessInfo.processInfo.environment
        for key in env.keys {
            let upper = key.uppercased()
            if upper.hasPrefix("WINE") || upper.hasPrefix("CX_") || upper.hasPrefix("STEAM")
                || upper.hasPrefix("VK_") || upper.hasPrefix("D3DM_") || upper.hasPrefix("DYLD_") {
                env.removeValue(forKey: key)
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        process.arguments = [
            "-x86_64", "env",
            "WINEPREFIX=\(prefix)",
            "WINEDEBUG=fixme-all",
            wine,
            "start", "/unix", exe.path(percentEncoded: false)
        ]
        process.currentDirectoryURL = exe.deletingLastPathComponent()
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.qualityOfService = .userInitiated
        try process.run()
        process.waitUntilExit()
    }
}
