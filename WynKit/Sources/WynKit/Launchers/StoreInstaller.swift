//
//  StoreInstaller.swift
//  WynKit
//
//  Official Windows storefront install: one BottleVM bottle per store,
//  frankea Wine, official Windows installer. Never Steam (32050D6B) or
//  Rockstar/RDR2 (F83BCCE3).
//

import Foundation

public enum StoreInstallError: LocalizedError, Sendable {
    case notInstallable(PlatformKind)
    case downloadFailed(PlatformKind, String)
    case wineTreeMissing
    case forbiddenBottle(String)

    public var errorDescription: String? {
        switch self {
        case .notInstallable(let kind):
            return "\(kind.displayName) is not installed via this installer."
        case .downloadFailed(let kind, let detail):
            return "Could not download the \(kind.displayName) installer. \(detail)"
        case .wineTreeMissing:
            return "Frankea Wine (Libraries.steam) is missing. Run setup first."
        case .forbiddenBottle(let name):
            return "Refusing to install \(name) into the Steam or Rockstar bottle."
        }
    }
}

public enum StoreInstaller {
    public static let steamBottleUUID = "32050D6B-F756-491C-8CBF-8C4CAC1B5ECF"
    public static let rockstarBottleUUID = "F83BCCE3-5035-4EC9-993A-148CE70A6EF1"

    public static let installerFolder = WynWineInstaller.applicationFolder.appending(path: "Installers")

    public static func dedicatedBottleName(for kind: PlatformKind) -> String? {
        kind.dedicatedBottleName
    }

    public static func ensureBottle(for kind: PlatformKind) throws -> Bottle {
        guard let name = kind.dedicatedBottleName else {
            throw StoreInstallError.notInstallable(kind)
        }
        var data = BottleData()
        if let existing = data.loadBottles().first(where: { $0.settings.name == name }) {
            try assertAllowed(existing, kind: kind)
            return existing
        }

        var uuid = UUID().uuidString
        while uuid == steamBottleUUID || uuid == rockstarBottleUUID {
            uuid = UUID().uuidString
        }
        let bottleURL = BottleData.defaultBottleDir.appending(path: uuid)
        try FileManager.default.createDirectory(at: bottleURL, withIntermediateDirectories: true)

        let bottle = Bottle(bottleUrl: bottleURL, inFlight: true)
        try assertAllowed(bottle, kind: kind)
        bottle.settings.name = name
        bottle.settings.windowsVersion = .win10
        bottle.settings.enhancedSync = .esync
        bottle.settings.avxEnabled = true

        data.paths.append(bottleURL)
        return bottle
    }

    public static func install(_ kind: PlatformKind) async throws {
        guard PlatformKind.installableStorefronts.contains(kind) else {
            throw StoreInstallError.notInstallable(kind)
        }
        guard WynWineInstaller.isWineInstalled(for: .steam) else {
            throw StoreInstallError.wineTreeMissing
        }

        let bottle = try ensureBottle(for: kind)
        try assertAllowed(bottle, kind: kind)

        let system32 = bottle.url
            .appending(path: "drive_c")
            .appending(path: "windows")
            .appending(path: "system32")
        if !FileManager.default.fileExists(atPath: system32.path(percentEncoded: false)) {
            try StorefrontLauncher.wineboot(in: bottle)
        }

        // Galaxy 2.x writes `Program Files/GOG Galaxy/GalaxyClient.exe`. If that
        // (or the old x86 path) is already there, do not run the web installer
        // again — Inno Setup then shows "already installed" and Wyn used to
        // look like a failed wizard because it only probed (x86).
        if kind == .gog, PlatformCatalog.exeURL(kind: .gog, in: bottle) != nil {
            return
        }
        if kind == .gog, PlatformCatalog.isStoreInstallerRunning(.gog) {
            return
        }

        let installer = try await downloadInstaller(for: kind)
        if kind == .ea {
            // Installer launches EADesktop at the end. Qt needs ANGLE + D3D11
            // (DXVK); a thin prefix hits "Failed to create OpenGL context".
            try StorefrontLauncher.prepareStoreGraphics(in: bottle)
            try StorefrontLauncher.runInstaller(
                at: installer,
                in: bottle,
                extraEnv: StorefrontLauncher.launchEnvironment(kind: .ea)
            )
        } else if kind == .battlenet {
            // Battle.net-Setup.exe launches Battle.net.exe when it finishes.
            // A thin prefix uses wined3d (GeForce 6800 / GL context fail), then
            // CEF hits 0x80000003 and Wine attaches winedbg. Same DXVK +
            // winedbg.exe=d env as Play, so the child is not a 6800 crash.
            try await Wine.killBottleAndWait(bottle: bottle)
            try StorefrontLauncher.prepareStoreGraphics(in: bottle)
            try StorefrontLauncher.runInstaller(
                at: installer,
                in: bottle,
                extraEnv: StorefrontLauncher.launchEnvironment(kind: .battlenet)
            )
        } else if kind == .gog {
            // Same class as Battle.net: Setup launches GalaxyClient.exe. A thin
            // prefix is wined3d (GeForce 6800). First-run then died on a missing
            // `campaignParamsForLogIn` key after `/campaign=""`.
            try StorefrontLauncher.prepareStoreGraphics(in: bottle)
            try StorefrontLauncher.runInstaller(
                at: installer,
                in: bottle,
                extraEnv: StorefrontLauncher.launchEnvironment(kind: .gog)
            )
        } else {
            try StorefrontLauncher.runInstaller(at: installer, in: bottle)
        }
    }

    /// Wipe the dedicated store prefix (not Steam, not Rockstar) so Install can start clean.
    public static func reset(_ kind: PlatformKind) async throws {
        guard let name = kind.dedicatedBottleName else {
            throw StoreInstallError.notInstallable(kind)
        }
        var data = BottleData()
        let matches = data.loadBottles().filter { $0.settings.name == name }
        for bottle in matches {
            try assertAllowed(bottle, kind: kind)
            try await Wine.killBottleAndWait(bottle: bottle)
            try? FileManager.default.removeItem(at: bottle.url)
            data.paths.removeAll { $0.lastPathComponent == bottle.url.lastPathComponent }
        }
    }

    /// Fetch an official vendor installer. Called only from explicit Install
    /// actions (`wyn steam install`, clicking Install in the app). Wyn does not
    /// rehost these files and does not put them in git.
    public static func downloadInstaller(for kind: PlatformKind) async throws -> URL {
        guard let spec = installerSpec(for: kind) else {
            throw StoreInstallError.notInstallable(kind)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: installerFolder, withIntermediateDirectories: true)
        let dest = installerFolder.appending(path: spec.filename)
        if let attrs = try? fm.attributesOfItem(atPath: dest.path(percentEncoded: false)),
           let size = attrs[.size] as? NSNumber,
           size.int64Value > 100_000 {
            return dest
        }

        var request = URLRequest(url: spec.url)
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64)",
            forHTTPHeaderField: "User-Agent"
        )
        let (tempURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw StoreInstallError.downloadFailed(kind, "HTTP \(code)")
        }
        let mime = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        if mime.lowercased().contains("text/html") {
            throw StoreInstallError.downloadFailed(kind, "Server returned HTML instead of an installer.")
        }
        if fm.fileExists(atPath: dest.path(percentEncoded: false)) {
            try fm.removeItem(at: dest)
        }
        try fm.moveItem(at: tempURL, to: dest)
        let size = (try? fm.attributesOfItem(atPath: dest.path(percentEncoded: false))[.size] as? NSNumber)?.int64Value ?? 0
        if size < 100_000 {
            try? fm.removeItem(at: dest)
            throw StoreInstallError.downloadFailed(kind, "Downloaded file is too small (\(size) bytes).")
        }
        return dest
    }

    private struct InstallerSpec {
        let url: URL
        let filename: String
    }

    private static func installerSpec(for kind: PlatformKind) -> InstallerSpec? {
        switch kind {
        case .epic:
            return InstallerSpec(
                url: URL(string: "https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/installer/download/EpicGamesLauncherInstaller.msi")!,
                filename: "EpicGamesLauncherInstaller.msi"
            )
        case .ea:
            return InstallerSpec(
                url: URL(string: "https://origin-a.akamaihd.net/EA-Desktop-Client-Download/installer-releases/EAappInstaller.exe")!,
                filename: "EAappInstaller.exe"
            )
        case .battlenet:
            return InstallerSpec(
                url: URL(string: "https://downloader.battle.net/download/getInstaller?os=win&installer=Battle.net-Setup.exe")!,
                filename: "Battle.net-Setup.exe"
            )
        case .gog:
            return InstallerSpec(
                url: URL(string: "https://webinstallers.gog.com/download/GOG_Galaxy_2.0.exe")!,
                filename: "GOG_Galaxy_2.0.exe"
            )
        default:
            return nil
        }
    }

    private static func assertAllowed(_ bottle: Bottle, kind: PlatformKind) throws {
        let id = bottle.url.lastPathComponent.uppercased()
        if id == steamBottleUUID || id == rockstarBottleUUID {
            throw StoreInstallError.forbiddenBottle(kind.displayName)
        }
    }
}

public struct PlatformRowItem: Identifiable, Hashable, Sendable {
    public let kind: PlatformKind
    public let installed: InstalledPlatform?

    public var id: String {
        installed?.id ?? "install-\(kind.rawValue)"
    }

    public var needsInstall: Bool { installed == nil }
}

extension PlatformKind {
    /// BottleVM name for a dedicated store prefix. Never `"Steam"`.
    public var dedicatedBottleName: String? {
        switch self {
        case .epic: return "Epic Games Store"
        case .ea: return "EA App"
        case .battlenet: return "Battle.net"
        case .gog: return "GOG Galaxy"
        default: return nil
        }
    }
}
