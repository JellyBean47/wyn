//
//  BottleSettings.swift
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
import os.log

public struct PinnedProgram: Codable, Hashable, Equatable {
    public var name: String
    public var url: URL?
    public var removable: Bool

    public init(name: String, url: URL) {
        self.name = name
        self.url = url
        do {
            let volume = try url.resourceValues(forKeys: [.volumeURLKey]).volume
            self.removable = try !(volume?.resourceValues(forKeys: [.volumeIsInternalKey]).volumeIsInternal ?? false)
        } catch {
            self.removable = false
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.url = try container.decodeIfPresent(URL.self, forKey: .url)
        self.removable = try container.decodeIfPresent(Bool.self, forKey: .removable) ?? false
    }
}

public struct BottleInfo: Codable, Equatable {
    var name: String = "Bottle"
    var pins: [PinnedProgram] = []
    var blocklist: [URL] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Bottle"
        self.pins = try container.decodeIfPresent([PinnedProgram].self, forKey: .pins) ?? []
        self.blocklist = try container.decodeIfPresent([URL].self, forKey: .blocklist) ?? []
    }
}

public enum WinVersion: String, CaseIterable, Codable, Sendable {
    case winXP = "winxp64"
    case win7 = "win7"
    case win8 = "win8"
    case win81 = "win81"
    case win10 = "win10"
    case win11 = "win11"

    public func pretty() -> String {
        switch self {
        case .winXP:
            return "Windows XP"
        case .win7:
            return "Windows 7"
        case .win8:
            return "Windows 8"
        case .win81:
            return "Windows 8.1"
        case .win10:
            return "Windows 10"
        case .win11:
            return "Windows 11"
        }
    }
}

public enum EnhancedSync: String, Codable, Equatable, Sendable {
    case none
    case esync
    case msync
}

/// Where a launch's windows live.
///
/// A game in exclusive fullscreen loses its native surface when macOS focus
/// changes, and winemac hands the rebuilt one a different `WineMetalView` — the
/// game then renders into a view that is no longer on screen. Measured on DOOM
/// (2016) 12 Sep 2026: black screen at 206% CPU, window gone, no errors logged.
/// Inside a Wine desktop there is no native surface to lose.
public enum VirtualDesktopMode: String, Codable, Equatable, Sendable, CaseIterable {
    /// Native macOS windows. Exclusive fullscreen works; alt-tab may not.
    case off
    /// Wrap what Wyn launches in `explorer /desktop=`. Covers titles Wyn starts
    /// directly — but **not** a game Steam spawns from `-applaunch`, because Wyn
    /// never runs that process.
    case launch
    /// Set the desktop in the prefix registry, so *every* process in the bottle
    /// gets one — including a game Steam launches. Each process reads
    /// `HKCU\Software\Wine\Explorer` at startup, so this reaches
    /// Steam-spawned titles without restarting Steam. The cost is that Steam's
    /// own window lands in a desktop too.
    case bottle

    public var displayName: String {
        switch self {
        case .off: return "Off (native windows)"
        case .launch: return "This launch only"
        case .bottle: return "Whole bottle (needed for Steam-launched games)"
        }
    }
}

public struct BottleWineConfig: Codable, Equatable {
    static let defaultWineVersion = SemanticVersion(7, 7, 0)
    var wineVersion: SemanticVersion = Self.defaultWineVersion
    var windowsVersion: WinVersion = .win10
    var enhancedSync: EnhancedSync = .msync
    var avxEnabled: Bool = false

    /// Where this bottle's launches put their windows. See `VirtualDesktopMode`.
    var virtualDesktopMode: VirtualDesktopMode = .off

    /// `WxH` for the desktop window. Empty means "ask the main display".
    var virtualDesktopSize: String = ""

    /// Spelled out because `virtualDesktop` is decode-only legacy — it has no
    /// property any more, and synthesis cannot know about it.
    enum CodingKeys: String, CodingKey {
        case wineVersion, windowsVersion, enhancedSync, avxEnabled
        case virtualDesktopMode, virtualDesktopSize
        case virtualDesktop
    }

    public init() {}

    // swiftlint:disable line_length
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.wineVersion = try container.decodeIfPresent(SemanticVersion.self, forKey: .wineVersion) ?? Self.defaultWineVersion
        self.windowsVersion = try container.decodeIfPresent(WinVersion.self, forKey: .windowsVersion) ?? .win10
        self.enhancedSync = try container.decodeIfPresent(EnhancedSync.self, forKey: .enhancedSync) ?? .msync
        self.avxEnabled = try container.decodeIfPresent(Bool.self, forKey: .avxEnabled) ?? false
        // `virtualDesktop: Bool` shipped first. A bottle written by that build
        // meant "wrap the launch", so migrate rather than silently switching it
        // off under someone who had turned it on.
        if let mode = try container.decodeIfPresent(VirtualDesktopMode.self, forKey: .virtualDesktopMode) {
            self.virtualDesktopMode = mode
        } else if try container.decodeIfPresent(Bool.self, forKey: .virtualDesktop) == true {
            self.virtualDesktopMode = .launch
        } else {
            self.virtualDesktopMode = .off
        }
        self.virtualDesktopSize = try container.decodeIfPresent(String.self, forKey: .virtualDesktopSize) ?? ""
    }

    /// Spelled out for the same reason as `CodingKeys`: the legacy
    /// `virtualDesktop` case has no property, so encoding cannot be synthesised.
    /// It is deliberately not written back — a bottle saved by this build
    /// carries the mode, and re-emitting the old boolean would give the next
    /// reader two answers.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(wineVersion, forKey: .wineVersion)
        try container.encode(windowsVersion, forKey: .windowsVersion)
        try container.encode(enhancedSync, forKey: .enhancedSync)
        try container.encode(avxEnabled, forKey: .avxEnabled)
        try container.encode(virtualDesktopMode, forKey: .virtualDesktopMode)
        try container.encode(virtualDesktopSize, forKey: .virtualDesktopSize)
    }
    // swiftlint:enable line_length
}

public struct BottleMetalConfig: Codable, Equatable {
    var metalHud: Bool = false
    var metalTrace: Bool = false
    var dxrEnabled: Bool = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.metalHud = try container.decodeIfPresent(Bool.self, forKey: .metalHud) ?? false
        self.metalTrace = try container.decodeIfPresent(Bool.self, forKey: .metalTrace) ?? false
        self.dxrEnabled = try container.decodeIfPresent(Bool.self, forKey: .dxrEnabled) ?? false
    }
}

public enum DXVKHUD: Codable, Equatable, Sendable {
    case full, partial, fps, off
}

public struct BottleGraphicsConfig: Codable, Equatable {
    var translationLayer: TranslationLayer = .dxmt
    var dxvk: Bool = false
    var dxvkAsync: Bool = true
    var dxvkHud: DXVKHUD = .off

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.translationLayer = try container.decodeIfPresent(TranslationLayer.self, forKey: .translationLayer) ?? .dxmt
        self.dxvk = try container.decodeIfPresent(Bool.self, forKey: .dxvk) ?? false
        self.dxvkAsync = try container.decodeIfPresent(Bool.self, forKey: .dxvkAsync) ?? true
        self.dxvkHud = try container.decodeIfPresent(DXVKHUD.self, forKey: .dxvkHud) ?? .off
    }
}

public struct BottleSettings: Codable, Equatable {
    static let defaultFileVersion = SemanticVersion(1, 0, 0)

    var fileVersion: SemanticVersion = Self.defaultFileVersion
    private var info: BottleInfo
    private var wineConfig: BottleWineConfig
    private var metalConfig: BottleMetalConfig
    private var graphicsConfig: BottleGraphicsConfig

    public init() {
        self.info = BottleInfo()
        self.wineConfig = BottleWineConfig()
        self.metalConfig = BottleMetalConfig()
        self.graphicsConfig = BottleGraphicsConfig()
    }

    // swiftlint:disable line_length
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.fileVersion = try container.decodeIfPresent(SemanticVersion.self, forKey: .fileVersion) ?? Self.defaultFileVersion
        self.info = try container.decodeIfPresent(BottleInfo.self, forKey: .info) ?? BottleInfo()
        self.wineConfig = try container.decodeIfPresent(BottleWineConfig.self, forKey: .wineConfig) ?? BottleWineConfig()
        self.metalConfig = try container.decodeIfPresent(BottleMetalConfig.self, forKey: .metalConfig) ?? BottleMetalConfig()
        if let graphics = try container.decodeIfPresent(BottleGraphicsConfig.self, forKey: .graphicsConfig) {
            self.graphicsConfig = graphics
        } else if let legacy = try container.decodeIfPresent(BottleGraphicsConfig.self, forKey: .dxvkConfig) {
            self.graphicsConfig = legacy
        } else {
            self.graphicsConfig = BottleGraphicsConfig()
        }
    }
    // swiftlint:enable line_length

    enum CodingKeys: String, CodingKey {
        case fileVersion, info, wineConfig, metalConfig, graphicsConfig
        case dxvkConfig // legacy Whisky/Wyn bottles
    }

    /// The name of this bottle
    public var name: String {
        get { return info.name }
        set { info.name = newValue }
    }

    /// The version of wine used by this bottle
    public var wineVersion: SemanticVersion {
        get { return wineConfig.wineVersion }
        set { wineConfig.wineVersion = newValue }
    }

    /// The version of windows used by this bottle
    public var windowsVersion: WinVersion {
        get { return wineConfig.windowsVersion }
        set { wineConfig.windowsVersion = newValue }
    }

    public var avxEnabled: Bool {
        get { return wineConfig.avxEnabled }
        set { wineConfig.avxEnabled = newValue }
    }

    /// Where launches in this bottle put their windows.
    public var virtualDesktopMode: VirtualDesktopMode {
        get { return wineConfig.virtualDesktopMode }
        set { wineConfig.virtualDesktopMode = newValue }
    }

    /// `WxH` for that desktop. Empty asks the main display.
    public var virtualDesktopSize: String {
        get { return wineConfig.virtualDesktopSize }
        set { wineConfig.virtualDesktopSize = newValue }
    }

    /// The pinned programs on this bottle
    public var pins: [PinnedProgram] {
        get { return info.pins }
        set { info.pins = newValue }
    }

    /// The blocked applicaitons on this bottle
    public var blocklist: [URL] {
        get { return info.blocklist }
        set { info.blocklist = newValue }
    }

    public var enhancedSync: EnhancedSync {
        get { return wineConfig.enhancedSync }
        set { wineConfig.enhancedSync = newValue }
    }

    public var metalHud: Bool {
        get { return metalConfig.metalHud }
        set { metalConfig.metalHud = newValue }
    }

    public var metalTrace: Bool {
        get { return metalConfig.metalTrace }
        set { metalConfig.metalTrace = newValue }
    }

    public var dxrEnabled: Bool {
        get { return metalConfig.dxrEnabled }
        set { metalConfig.dxrEnabled = newValue }
    }

    public var translationLayer: TranslationLayer {
        get { return graphicsConfig.translationLayer }
        set {
            graphicsConfig.translationLayer = newValue
            // Keep legacy dxvk flag in sync — a sticky true used to force DXVK
            // even when translationLayer was dxmt/d3dmetal.
            graphicsConfig.dxvk = (newValue == .dxvk)
        }
    }

    public var dxvk: Bool {
        get { return graphicsConfig.dxvk }
        set {
            graphicsConfig.dxvk = newValue
            if newValue {
                graphicsConfig.translationLayer = .dxvk
            } else if graphicsConfig.translationLayer == .dxvk {
                graphicsConfig.translationLayer = .dxmt
            }
        }
    }

    public var dxvkAsync: Bool {
        get { return graphicsConfig.dxvkAsync }
        set { graphicsConfig.dxvkAsync = newValue }
    }

    public var dxvkHud: DXVKHUD {
        get { return graphicsConfig.dxvkHud }
        set { graphicsConfig.dxvkHud = newValue }
    }

    @discardableResult
    public static func decode(from metadataURL: URL) throws -> BottleSettings {
        guard FileManager.default.fileExists(atPath: metadataURL.path(percentEncoded: false)) else {
            let decoder = PropertyListDecoder()
            let settings = try decoder.decode(BottleSettings.self, from: Data(contentsOf: metadataURL))
            try settings.encode(to: metadataURL)
            return settings
        }

        let decoder = PropertyListDecoder()
        let data = try Data(contentsOf: metadataURL)
        var settings = try decoder.decode(BottleSettings.self, from: data)

        guard settings.fileVersion == BottleSettings.defaultFileVersion else {
            Logger.wynKit.warning("Invalid file version `\(settings.fileVersion)`")
            settings = BottleSettings()
            try settings.encode(to: metadataURL)
            return settings
        }

        if settings.wineConfig.wineVersion != BottleWineConfig().wineVersion {
            Logger.wynKit.warning("Bottle has a different wine version `\(settings.wineConfig.wineVersion)`")
            settings.wineConfig.wineVersion = BottleWineConfig().wineVersion
            try settings.encode(to: metadataURL)
            return settings
        }

        return settings
    }

    func encode(to metadataUrl: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(self)
        try data.write(to: metadataUrl)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fileVersion, forKey: .fileVersion)
        try container.encode(info, forKey: .info)
        try container.encode(wineConfig, forKey: .wineConfig)
        try container.encode(metalConfig, forKey: .metalConfig)
        try container.encode(graphicsConfig, forKey: .graphicsConfig)
    }

    // swiftlint:disable:next cyclomatic_complexity
    public func environmentVariables(wineEnv: inout [String: String]) {
        // translationLayer is the source of truth; dxvk flag is legacy mirror only.
        let layer = translationLayer
        wineEnv.merge(
            layer.environmentOverrides(dxvkHud: dxvkHud, dxvkAsync: dxvkAsync),
            uniquingKeysWith: { _, new in new }
        )

        switch enhancedSync {
        case .none:
            break
        case .esync:
            wineEnv.updateValue("1", forKey: "WINEESYNC")
        case .msync:
            wineEnv.updateValue("1", forKey: "WINEMSYNC")
            // D3DM detects ESYNC and changes behaviour accordingly
            // so we have to lie to it so that it doesn't break
            // under MSYNC. Values hardcoded in lid3dshared.dylib
            wineEnv.updateValue("1", forKey: "WINEESYNC")
        }

        if metalHud {
            wineEnv.updateValue("1", forKey: "MTL_HUD_ENABLED")
        }

        if metalTrace {
            wineEnv.updateValue("1", forKey: "METAL_CAPTURE_ENABLED")
        }

        if avxEnabled {
            wineEnv.updateValue("1", forKey: "ROSETTA_ADVERTISE_AVX")
        }

        if dxrEnabled {
            wineEnv.updateValue("1", forKey: "D3DM_SUPPORT_DXR")
        }
    }
}
