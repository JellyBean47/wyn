//
//  SteamBottlePrerequisites.swift
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
//  What Steam's first Play of a Ubisoft game would have installed into the bottle.
//
//  Steam runs each game's install script the first time the game is started
//  from Steam's own Play button, and for Ubisoft titles that script runs the
//  `UbisoftConnectInstaller.exe` the game ships. Wyn starts those games itself,
//  so on a fresh bottle Connect never arrives. Measured 29 Sep 2026 on a fresh
//  build 8 install: no `Program Files (x86)/Ubisoft`, no Connect tile, and
//  Assassin's Creed Odyssey stopped at "Ubisoft Connect is not installed"
//  before any Wine process started. The old bottle only had Connect because it
//  had been installed there long before.
//
//  Not Visual C++. The same fresh bottle already had it: Steam's own first run
//  writes `...\VC\Runtimes\X64` Installed=1, v14.51. Microsoft's current
//  redistributable (14.44) then refuses with 0x80070666, "a newer version is
//  installed". The "MISSING" Wyn showed was its own case-sensitive registry
//  match (see WindowsRuntimes.section), not a missing runtime.
//
//  The installer is Ubisoft's own, fetched when needed and never rehosted, the
//  same as the store installers in StoreInstaller. Measured in a clone of that
//  bottle on build 8's Wine: `UbisoftConnectInstaller.exe /S` exits 0 in about
//  8 s and leaves `upc.exe` where PlatformCatalog looks for it.
//

import Foundation

public enum SteamBottlePrerequisiteError: LocalizedError, Sendable {
    case downloadFailed(String)
    case connectNotInstalled

    public var errorDescription: String? {
        switch self {
        case .downloadFailed(let detail):
            return "Could not download the Ubisoft Connect installer. \(detail)"
        case .connectNotInstalled:
            return "Ubisoft Connect's installer finished, but upc.exe is not in the Steam bottle."
        }
    }
}

public enum SteamBottlePrerequisites {

    static let connectInstallerURL = URL(
        string: "https://static3.cdn.ubi.com/orbit/launcher_installer/UbisoftConnectInstaller.exe"
    )!
    static let connectInstallerName = "UbisoftConnectInstaller.exe"

    /// Whether a launch of this profile has to install Connect first. Pure, so
    /// the rule can be tested without a bottle.
    public static func needsConnectInstall(needsConnect: Bool, connectInstalled: Bool) -> Bool {
        needsConnect && !connectInstalled
    }

    public static func isConnectInstalled(in bottle: Bottle) -> Bool {
        PlatformCatalog.exeURL(kind: .ubisoft, in: bottle) != nil
    }

    /// Install Connect before a Ubisoft game's first launch, the way Steam's
    /// first Play would. A no-op for every other game and once Connect is in.
    public static func ensure(
        for profile: GameProfile,
        in bottle: Bottle,
        installDirectory: URL? = nil
    ) async throws {
        guard needsConnectInstall(
            needsConnect: profile.needsUbisoftConnectPlay,
            connectInstalled: isConnectInstalled(in: bottle)
        ) else { return }
        LaunchProgress.emit("Installing Ubisoft Connect into the Steam bottle (first launch only)…")
        try await installConnect(in: bottle, fallbackSearch: installDirectory)
    }

    /// Ubisoft's own installer, silently, into the Steam bottle, where Steam's
    /// Ubisoft games look for it. When the download fails, the copy a Ubisoft
    /// game ships in its own folder (the one Steam's install script runs) is
    /// used instead.
    public static func installConnect(in bottle: Bottle, fallbackSearch: URL? = nil) async throws {
        if isConnectInstalled(in: bottle) { return }
        let installer: URL
        do {
            installer = try await fetchConnectInstaller()
        } catch {
            guard let local = localConnectInstaller(in: fallbackSearch) else { throw error }
            installer = local
        }
        _ = try await Wine.runWine([installer.path(percentEncoded: false), "/S"], bottle: bottle)
        guard isConnectInstalled(in: bottle) else {
            throw SteamBottlePrerequisiteError.connectNotInstalled
        }
    }

    static func localConnectInstaller(in directory: URL?) -> URL? {
        guard let directory else { return nil }
        let candidate = directory.appending(path: connectInstallerName)
        return FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) ? candidate : nil
    }

    private static func fetchConnectInstaller() async throws -> URL {
        let fm = FileManager.default
        let folder = StoreInstaller.installerFolder
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appending(path: connectInstallerName)
        if let size = (try? fm.attributesOfItem(atPath: dest.path(percentEncoded: false))[.size]) as? NSNumber,
           size.int64Value > 100_000 {
            return dest
        }
        var request = URLRequest(url: connectInstallerURL)
        request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64)", forHTTPHeaderField: "User-Agent")
        let (tempURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SteamBottlePrerequisiteError.downloadFailed("HTTP \(code)")
        }
        if (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().contains("text/html") {
            throw SteamBottlePrerequisiteError.downloadFailed("The server returned a web page instead of an installer.")
        }
        if fm.fileExists(atPath: dest.path(percentEncoded: false)) {
            try fm.removeItem(at: dest)
        }
        try fm.moveItem(at: tempURL, to: dest)
        let size = ((try? fm.attributesOfItem(atPath: dest.path(percentEncoded: false))[.size]) as? NSNumber)?.int64Value ?? 0
        guard size > 100_000 else {
            try? fm.removeItem(at: dest)
            throw SteamBottlePrerequisiteError.downloadFailed("The file is too small (\(size) bytes).")
        }
        return dest
    }
}
