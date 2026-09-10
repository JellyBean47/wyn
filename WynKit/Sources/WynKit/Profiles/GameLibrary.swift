//
//  GameLibrary.swift
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

    /// The catalog exists to keep one tile per game across the profiles Wyn
    /// *ships* — `satisfactory-esync` and friends share a slug and stay hidden.
    /// It is not an allowlist for the world.
    ///
    /// It was being used as one, and that made adding a game impossible: a
    /// profile the person added — every profile the MCP server writes — has no
    /// catalog slug, so it was filtered out and the game stayed "no profile"
    /// forever no matter how correct the file was. Found end-to-end on
    /// Solarpunk, which saved cleanly and then simply never appeared.
    ///
    /// So the canonical filter applies to bundled profiles only. Anything the
    /// person added is theirs and always counts.
    public static func catalogProfiles() -> [GameProfile] {
        let all = ProfileStore.loadAll().filter { !hiddenProfileIDs.contains($0.id) }
        let userAdded = ProfileStore.userProfileIDs()
        let canonical = Set(GameCatalog.load().games.map(\.slug))
        if canonical.isEmpty {
            return all.filter { !$0.id.hasPrefix("satisfactory-") || userAdded.contains($0.id) }
        }
        return all.filter { canonical.contains($0.id) || userAdded.contains($0.id) }
    }

    /// Steam-installed apps in this bottle. Uses a bundled profile when `steamAppId` matches.
    ///
    /// `hostVolumesRoot` is `/Volumes` in production. Tests pass a fake tree so
    /// a machine's real `SteamLibrary` cannot leak into the listing.
    public static func installed(
        in bottle: Bottle,
        hostVolumesRoot: URL = URL(fileURLWithPath: "/Volumes")
    ) -> [GameLibraryItem] {
        let catalogByAppId = Dictionary(
            catalogProfiles().compactMap { profile -> (Int, GameProfile)? in
                guard let appId = profile.steamAppId else { return nil }
                return (appId, profile)
            },
            uniquingKeysWith: { first, _ in first }
        )

        return SteamLauncher.installedApps(in: bottle, hostVolumesRoot: hostVolumesRoot).compactMap { app in
            if let profile = catalogByAppId[app.appId] {
                // Search the folder `installedApps` already accepted. Re-walking
                // by app ID prefers a `C:` manifest that may only be a symlink
                // into another library, and that used to hide the tile entirely.
                guard let exe = SteamLauncher.findGameExecutable(
                    matching: profile,
                    under: app.installDirectory
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

    /// Text listing for `wyn steam games` and MCP `list_installed_games`.
    /// Catalog status is what the profile file claims; "this Mac" is launch
    /// evidence on this machine (a bundled `launched` with no matching record
    /// still reads as guessed here).
    public static func describeInstalled(
        in bottle: Bottle,
        hostVolumesRoot: URL = URL(fileURLWithPath: "/Volumes")
    ) -> String {
        let records = LaunchRecordStore.load()
        let items = installed(in: bottle, hostVolumesRoot: hostVolumesRoot)
        guard !items.isEmpty else {
            return "No games installed in the Steam bottle yet."
        }

        var lines = ["\(items.count) installed game(s):", ""]
        for item in items {
            let profile = item.profile
            let synthesised = profile.id.hasPrefix("steam-")
            let earned = synthesised
                ? "no profile"
                : LaunchRecordStore.effectiveStatus(for: profile, in: records).rawValue
            let line = "  steamAppId=\(profile.steamAppId.map(String.init) ?? "-")"
                + "  profile=\(synthesised ? "none" : profile.id)"
                + "  catalog=\(synthesised ? "—" : profile.status.rawValue)"
                + "  thisMac=\(earned)"
            lines.append(profile.name)
            lines.append(line)
        }
        lines.append("")
        lines.append("""
        "no profile" means Wyn has the game but no launch settings for it — \
        inspect_game_files on its app id is the next step. catalog is the \
        bundled claim (guessed / launched / verified); thisMac is what this \
        machine has actually recorded. verified still requires a person and a log.
        """)
        return lines.joined(separator: "\n")
    }
}
