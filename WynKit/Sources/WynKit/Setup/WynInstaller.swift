//
//  WynInstaller.swift
//  WynKit
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

        if let installer = result.steamInstallerPath {
            lines.append("")
            lines.append("Next — install Steam (one-time, ~2 min):")
            lines.append("  wyn steam install")
            lines.append("")
            lines.append("Or run the installer manually:")
            lines.append("  wyn run Steam \"\(installer.path)\"")
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

    public var errorDescription: String? {
        switch self {
        case .cannotResolveRuntimeVersion:
            return """
            Could not fetch WynWine version from the runtime server.
            Download manually from https://github.com/frankea/Whisky/releases and run:
              wyn runtime install --from /path/to/Libraries.tar.gz
            """
        }
    }
}
