//
//  GameProfile.swift
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

/// How much a profile's settings are actually worth.
///
/// A written profile and a measured one look identical on the page — plausible
/// JSON, confident notes — so the difference has to be stated rather than
/// inferred. 100 of the profiles Wyn ships were written in one commit and none
/// of them has ever been launched; `satisfactory` took weeks of measurement.
/// Treating those as the same kind of thing is how MetalFX ended up enabled in
/// 72 games.
///
/// `ProfileValidator` uses this: a profile may only enable a setting that was
/// measured to break a real game once it claims `verified`, which is a claim a
/// person has to make on purpose and back up in `notes`.
public enum ProfileStatus: String, Codable, Sendable, CaseIterable {
    /// Written from knowledge of the engine and the game. Never launched.
    case guessed
    /// Launched successfully at least once. Nothing measured beyond "it ran".
    case launched
    /// Settings were measured on real hardware, and `notes` says what was seen.
    case verified
}

/// Per-game compatibility profile.
public struct GameProfile: Codable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var publisher: String?
    public var steamAppId: Int?
    /// Glob patterns matched against executable filenames (e.g. "eldenring.exe").
    public var exePatterns: [String]
    public var bottle: ProfileBottleOverrides?
    public var environment: [String: String]
    public var winetricks: [String]
    public var launchArgs: String?
    /// Unreal `%LOCALAPPDATA%/<name>` project folder (may differ from Steam installdir).
    public var unrealProject: String?
    public var notes: String?
    /// Defaults to `.guessed`: a profile is a guess until someone says otherwise,
    /// and an absent field must never read as "tested".
    public var status: ProfileStatus
    /// `--frankea-steam` starts Connect on frankea (DXVK). Default D3DMetal play
    /// starts `upc.exe` on the game-host wineserver (UI may be transparent).
    public var requiresUbisoftConnect: Bool
    /// Offline `acs.exe` session. Written at Play because the Kunos menu does not stay up.
    public var assettoCorsa: AssettoCorsaSession?
    /// When false, Play does not rewrite Unreal `GameUserSettings` to Low + 40 FPS.
    /// Absent means true — that pin is the safe first diagnostic, and an old
    /// profile must keep it. Ready or Not's first run was unjudgeable because of it.
    public var pinUnrealLowScalability: Bool

    public var needsUbisoftConnectPlay: Bool {
        requiresUbisoftConnect || id == "ac-odyssey"
    }

    public init(
        id: String,
        name: String,
        publisher: String? = nil,
        steamAppId: Int? = nil,
        exePatterns: [String] = [],
        bottle: ProfileBottleOverrides? = nil,
        environment: [String: String] = [:],
        winetricks: [String] = [],
        launchArgs: String? = nil,
        unrealProject: String? = nil,
        notes: String? = nil,
        status: ProfileStatus = .guessed,
        requiresUbisoftConnect: Bool = false,
        assettoCorsa: AssettoCorsaSession? = nil,
        pinUnrealLowScalability: Bool = true
    ) {
        self.id = id
        self.name = name
        self.publisher = publisher
        self.steamAppId = steamAppId
        self.exePatterns = exePatterns
        self.bottle = bottle
        self.environment = environment
        self.winetricks = winetricks
        self.launchArgs = launchArgs
        self.unrealProject = unrealProject
        self.notes = notes
        self.status = status
        self.requiresUbisoftConnect = requiresUbisoftConnect
        self.assettoCorsa = assettoCorsa
        self.pinUnrealLowScalability = pinUnrealLowScalability
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        publisher = try container.decodeIfPresent(String.self, forKey: .publisher)
        steamAppId = try container.decodeIfPresent(Int.self, forKey: .steamAppId)
        exePatterns = try container.decodeIfPresent([String].self, forKey: .exePatterns) ?? []
        bottle = try container.decodeIfPresent(ProfileBottleOverrides.self, forKey: .bottle)
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        winetricks = try container.decodeIfPresent([String].self, forKey: .winetricks) ?? []
        launchArgs = try container.decodeIfPresent(String.self, forKey: .launchArgs)
        unrealProject = try container.decodeIfPresent(String.self, forKey: .unrealProject)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        // Absent means guessed. An unstated provenance must never read as tested.
        status = try container.decodeIfPresent(ProfileStatus.self, forKey: .status) ?? .guessed
        requiresUbisoftConnect = try container.decodeIfPresent(Bool.self, forKey: .requiresUbisoftConnect) ?? false
        assettoCorsa = try container.decodeIfPresent(AssettoCorsaSession.self, forKey: .assettoCorsa)
        pinUnrealLowScalability = try container.decodeIfPresent(
            Bool.self, forKey: .pinUnrealLowScalability
        ) ?? true
    }

    public func matches(executable: URL) -> Bool {
        let filename = executable.lastPathComponent.lowercased()
        return exePatterns.contains { pattern in
            fnmatch(pattern.lowercased(), filename, 0) == 0
        }
    }
}

public struct ProfileBottleOverrides: Codable, Sendable {
    public var windowsVersion: WinVersion?
    public var translationLayer: TranslationLayer?
    public var enhancedSync: EnhancedSync?
    public var dxvk: Bool?
    public var dxvkAsync: Bool?
    public var dxrEnabled: Bool?
    public var avxEnabled: Bool?
    public var metalHud: Bool?

    public init(
        windowsVersion: WinVersion? = nil,
        translationLayer: TranslationLayer? = nil,
        enhancedSync: EnhancedSync? = nil,
        dxvk: Bool? = nil,
        dxvkAsync: Bool? = nil,
        dxrEnabled: Bool? = nil,
        avxEnabled: Bool? = nil,
        metalHud: Bool? = nil
    ) {
        self.windowsVersion = windowsVersion
        self.translationLayer = translationLayer
        self.enhancedSync = enhancedSync
        self.dxvk = dxvk
        self.dxvkAsync = dxvkAsync
        self.dxrEnabled = dxrEnabled
        self.avxEnabled = avxEnabled
        self.metalHud = metalHud
    }
}
