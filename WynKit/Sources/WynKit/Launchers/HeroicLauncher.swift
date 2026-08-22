//
//  HeroicLauncher.swift
//  WynKit
//
//  Official EGL (16:19) and GOG Galaxy (17:04) in Wine are parked.
//  Epic + GOG auth/library is native Heroic. Do not spawn Portal Win64,
//  EpicOnlineServicesInstaller, or GalaxyClient.exe from this type.
//

import AppKit
import Foundation

public enum HeroicLaunchError: LocalizedError, Sendable {
    case brewMissing
    case installFailed(String)
    case notInstalled

    public var errorDescription: String? {
        switch self {
        case .brewMissing:
            return "Homebrew is required to install Heroic. Install brew, or install Heroic from https://heroicgameslauncher.com"
        case .installFailed(let detail):
            return "Could not install Heroic. \(detail)"
        case .notInstalled:
            return """
            Heroic is not installed. Install it from https://heroicgameslauncher.com \
            or run: brew install --cask heroic
            Wyn will not run brew unless you set WYN_ALLOW_BREW_HEROIC=1.
            """
        }
    }
}

public enum HeroicLauncher {
    public static let bundleIdentifier = "com.heroicgameslauncher.hgl"

    /// Native Heroic.app — never Wine EGL or GalaxyClient.exe.
    public static func appURL() -> URL? {
        let fm = FileManager.default
        let homes = [
            URL(fileURLWithPath: "/Applications/Heroic.app"),
            fm.homeDirectoryForCurrentUser.appending(path: "Applications/Heroic.app")
        ]
        for url in homes where fm.fileExists(atPath: url.path(percentEncoded: false)) {
            return url
        }
        return nil
    }

    public static func isInstalled() -> Bool {
        appURL() != nil
    }

    public static func isRunning() -> Bool {
        // NSWorkspace only — never Process/ps. waitUntilExit on the SwiftUI
        // main thread during layout aborted Wyn (16:39 AG::precondition_failure).
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundleIdentifier
        }
    }

    /// Open native Heroic. Never EGL/Galaxy. Never silent `brew install`.
    /// Set `WYN_ALLOW_BREW_HEROIC=1` to opt in to Homebrew for this process.
    public static func ensureAndOpen() async throws {
        if appURL() == nil {
            let allowBrew = ProcessInfo.processInfo.environment["WYN_ALLOW_BREW_HEROIC"] == "1"
            if allowBrew {
                LaunchProgress.emit("Heroic: installing via Homebrew (WYN_ALLOW_BREW_HEROIC=1)…")
                try installHeroicCask()
            } else {
                throw HeroicLaunchError.notInstalled
            }
        }
        guard let app = appURL() else {
            throw HeroicLaunchError.notInstalled
        }
        LaunchProgress.emit("Opening Heroic…")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", app.path(percentEncoded: false)]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private static func brewURL() -> URL? {
        let fm = FileManager.default
        for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if fm.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private static func installHeroicCask() throws {
        guard let brew = brewURL() else {
            throw HeroicLaunchError.brewMissing
        }
        let process = Process()
        process.executableURL = brew
        process.arguments = ["install", "--cask", "heroic"]
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0 { return }
        let log = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let tail = log.split(whereSeparator: \.isNewline).suffix(8).joined(separator: "\n")
        throw HeroicLaunchError.installFailed(tail.isEmpty ? "brew exit \(process.terminationStatus)" : tail)
    }
}
