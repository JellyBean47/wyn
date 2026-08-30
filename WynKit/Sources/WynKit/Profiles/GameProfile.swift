//
//  GameProfile.swift
//  WynKit
//

import Foundation

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
    /// Play must start Ubisoft Connect on frankea, then Steam on the same wineserver.
    public var requiresUbisoftConnect: Bool

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
        requiresUbisoftConnect: Bool = false
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
        self.requiresUbisoftConnect = requiresUbisoftConnect
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
        requiresUbisoftConnect = try container.decodeIfPresent(Bool.self, forKey: .requiresUbisoftConnect) ?? false
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
