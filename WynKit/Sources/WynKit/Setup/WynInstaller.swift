//
//  WynInstaller.swift
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

import Foundation
import SemanticVersion

public struct WynInstallResult: Sendable {
    public let runtimeInstalled: Bool
    public let bottleCreated: Bool
    public let steamInstallerPath: URL?
    public let bottle: Bottle

    public init(runtimeInstalled: Bool, bottleCreated: Bool, steamInstallerPath: URL?, bottle: Bottle) {
        self.runtimeInstalled = runtimeInstalled
        self.bottleCreated = bottleCreated
        self.steamInstallerPath = steamInstallerPath
        self.bottle = bottle
    }
}

public enum WynInstaller {
    /// One-shot setup: WynWine runtime + Steam bottle + Steam installer download.
    public static func setup(installSteamClient: Bool = true) async throws -> WynInstallResult {
        // Before anything is downloaded. Wine's unix half is x86_64, so without
        // Rosetta nothing that follows can run — and the failure would arrive
        // after a ~317 MB download, as an opaque exec error from a launch.
        //
        // check-environment.sh gates this for a source install, but someone who
        // dragged Wyn.app out of the disk image never runs it. This is that
        // check, on the path they do take.
        guard Rosetta2.isRosettaInstalled else {
            throw WynInstallError.rosettaMissing
        }

        var runtimeInstalled = WynWineInstaller.isWynWineInstalled()

        if !runtimeInstalled {
            RuntimeManager.activeSource = .whiskyCDN
            let pin = RuntimeIntegrity.whiskyCDN
            let tarball = try await downloadFile(from: pin.url)
            try WynWineInstaller.install(from: tarball, expectedSHA256: pin.sha256)
            runtimeInstalled = true
        }

        var bottleData = BottleData()
        let existingBottles = bottleData.loadBottles()
        let hadSteamBottle = existingBottles.contains { $0.settings.name == SteamLauncher.defaultBottleName }
        let bottle = try SteamLauncher.ensureSteamBottle()

        var installerPath: URL?
        if installSteamClient && !SteamLauncher.isSteamInstalled(in: bottle) {
            installerPath = try await SteamLauncher.downloadInstaller()
        }

        return WynInstallResult(
            runtimeInstalled: runtimeInstalled,
            bottleCreated: !hadSteamBottle,
            steamInstallerPath: installerPath,
            bottle: bottle
        )
    }

    public static func postInstallInstructions(result: WynInstallResult) -> String {
        var lines: [String] = []
        lines.append("Wyn is ready.")
        lines.append("")

        if result.bottleCreated {
            lines.append("Created Steam bottle: \(result.bottle.settings.name)")
        }

        if result.steamInstallerPath != nil {
            lines.append("")
            lines.append("Next — install Steam (silent setup, then login window):")
            lines.append("  wyn steam install")
        } else if SteamLauncher.isSteamInstalled(in: result.bottle) {
            lines.append("")
            lines.append("Steam is already installed. Launch it with:")
            lines.append("  wyn steam launch")
        }

        lines.append("")
        lines.append("Recommended first game (~3 GB):")
        lines.append("  1. wyn steam launch")
        lines.append("  2. Install \"RV There Yet?\" in Steam")
        lines.append("  3. wyn play rv-there-yet")
        lines.append("")
        lines.append("List all game profiles: wyn profiles list")

        return lines.joined(separator: "\n")
    }

    private static func downloadFile(from url: URL) async throws -> URL {
        let (tempURL, _) = try await URLSession.shared.download(from: url)
        let dest = FileManager.default.temporaryDirectory
            .appending(path: "WynWine-\(UUID().uuidString).tar.gz")
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }
}

public enum WynInstallError: LocalizedError {
    case cannotResolveRuntimeVersion
    case rosettaMissing

    public var errorDescription: String? {
        switch self {
        case .cannotResolveRuntimeVersion:
            return """
            Could not fetch WynWine version from the runtime server.
            Download manually from https://github.com/frankea/Whisky/releases and run:
              wyn runtime install --from /path/to/Libraries.tar.gz
            """
        case .rosettaMissing:
            return """
            Rosetta 2 is not installed. Wine's unix half is x86_64, so Wyn \
            cannot run Windows games without it.
            """
        }
    }

    /// `Failure(step:error:)` surfaces this as the "Try:" line, so it has to be
    /// something a person can act on without leaving the dialog.
    public var recoverySuggestion: String? {
        switch self {
        case .cannotResolveRuntimeVersion:
            return nil
        case .rosettaMissing:
            // Deliberately an instruction rather than a button: installing
            // Rosetta needs admin rights, and an app that silently invokes a
            // privileged installer is worse than one that says what to run.
            return "Run this in Terminal, then press Setup again:\n  softwareupdate --install-rosetta --agree-to-license"
        }
    }
}
