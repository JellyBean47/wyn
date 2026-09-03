//
//  GameLibrary.swift
//  WynKit
//
//  Installed-game catalog for the library UI.
//

import Foundation

/// A Steam-installed game shown in the library. Catalog profiles supply launch
/// plumbing when we have them; otherwise the tile is a synthetic `steam-<appId>`.
public struct GameLibraryItem: Identifiable, Sendable, Hashable {
    public var id: String { profile.id }
    public let profile: GameProfile
    public let executable: URL?

    public init(profile: GameProfile, executable: URL? = nil) {
        self.profile = profile
        self.executable = executable
    }

    public static func == (lhs: GameLibraryItem, rhs: GameLibraryItem) -> Bool {
        lhs.profile.id == rhs.profile.id && lhs.executable == rhs.executable
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(profile.id)
        hasher.combine(executable)
    }
}

public enum GameLibrary {
    /// Profiles that are launch plumbing, not games.
    public static let hiddenProfileIDs: Set<String> = ["steam"]

    public static func steamBottle() -> Bottle? {
        var data = BottleData()
        return data.loadBottles().first { $0.settings.name == SteamLauncher.defaultBottleName }
    }

    /// Wine tree or Steam bottle missing — first-run sheet.
    /// GPTK/D3DMetal is optional (FOSS default is DXMT/DXVK).
    public static func needsSetup() -> Bool {
        !WynWineInstaller.isWynWineInstalled()
            || steamBottle() == nil
    }

    /// One profile per unique game. Canonical slugs live in `GameCatalog`;
    /// variant files (`satisfactory-esync`, …) share a slug and stay hidden.
    public static func catalogProfiles() -> [GameProfile] {
        let all = ProfileStore.loadAll().filter { !hiddenProfileIDs.contains($0.id) }
        let canonical = Set(GameCatalog.load().games.map(\.slug))
        if canonical.isEmpty {
            return all.filter { !$0.id.hasPrefix("satisfactory-") }
        }
        return all.filter { canonical.contains($0.id) }
    }

    /// Steam-installed apps in this bottle. Uses a bundled profile when `steamAppId` matches.
    public static func installed(in bottle: Bottle) -> [GameLibraryItem] {
        let catalogByAppId = Dictionary(
            catalogProfiles().compactMap { profile -> (Int, GameProfile)? in
                guard let appId = profile.steamAppId else { return nil }
                return (appId, profile)
            },
            uniquingKeysWith: { first, _ in first }
        )

        return SteamLauncher.installedApps(in: bottle).compactMap { app in
            if let profile = catalogByAppId[app.appId] {
                guard let exe = SteamLauncher.findGameExecutable(
                    forAppId: app.appId,
                    in: bottle,
                    profile: profile
                ) else {
                    return nil
                }
                return GameLibraryItem(profile: profile, executable: exe)
            }

            let profile = GameProfile(
                id: "steam-\(app.appId)",
                name: app.name,
                steamAppId: app.appId,
                exePatterns: []
            )
            return GameLibraryItem(profile: profile)
        }
        .sorted {
            $0.profile.name.localizedCaseInsensitiveCompare($1.profile.name) == .orderedAscending
        }
    }
}
