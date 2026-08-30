//
//  RuntimeProvider.swift
//  WynKit
//

import Foundation
import SemanticVersion

/// Where Wyn sources its Wine + translation layer binaries.
public enum RuntimeSource: String, Codable, CaseIterable, Sendable {
    /// Prebuilt WhiskyWine tarball from the frankea/Whisky community fork (DXMT/DXVK; no GPTK hooks).
    case whiskyCDN = "whisky-cdn"
    /// User-supplied FOSS winecx (not downloaded). D3DMetal game-host.
    case gptkAware = "gptk-aware"
    /// Locally built runtime from vendor/whisky-wine (dev).
    case localBuild = "local-build"
    /// User-supplied tarball path.
    case custom = "custom"

    public var displayName: String {
        switch self {
        case .whiskyCDN: return "Community WhiskyWine"
        case .gptkAware: return "FOSS winecx game-host (user-built)"
        case .localBuild: return "Local Build"
        case .custom: return "Custom"
        }
    }

    public var versionPlistURL: URL? {
        switch self {
        case .whiskyCDN:
            return URL(string: "https://frankea.github.io/Whisky/WhiskyWineVersion.plist")
        case .gptkAware, .localBuild, .custom:
            return nil
        }
    }

    public var releasesBaseURL: URL? {
        switch self {
        case .whiskyCDN:
            return URL(string: "https://github.com/frankea/Whisky/releases/download")
        case .gptkAware:
            // Not fetched. Game-host is user-built winecx; see GameHostIdentity.
            return nil
        case .localBuild, .custom:
            return nil
        }
    }

    /// No tarball. `wyn runtime install --gptk-aware` copies/links user-built winecx.
    public static let gptkAwareReleaseTag: String? = nil

    public var directLibrariesURL: URL? {
        nil
    }
}

public struct RuntimeStatus: Sendable {
    public let installed: Bool
    public let version: SemanticVersion?
    public let source: RuntimeSource
    public let wineBinary: URL
    public let binFolder: URL

    public init(
        installed: Bool,
        version: SemanticVersion?,
        source: RuntimeSource,
        wineBinary: URL,
        binFolder: URL
    ) {
        self.installed = installed
        self.version = version
        self.source = source
        self.wineBinary = wineBinary
        self.binFolder = binFolder
    }
}

public enum RuntimeManager {
    private static let sourceKey = "FlyRuntimeSource"

    public static var activeSource: RuntimeSource {
        get {
            guard let raw = UserDefaults.standard.string(forKey: sourceKey),
                  let source = RuntimeSource(rawValue: raw) else {
                return .whiskyCDN
            }
            return source
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: sourceKey)
        }
    }

    public static func status() -> RuntimeStatus {
        let version = WynWineInstaller.wynWineVersion()
        return RuntimeStatus(
            installed: WynWineInstaller.isWynWineInstalled(),
            version: version,
            source: activeSource,
            wineBinary: Wine.wineBinary,
            binFolder: WynWineInstaller.binFolder
        )
    }

    /// Resolve a local dev runtime path relative to the Wyn repo root.
    public static func localVendorRuntimePath(repoRoot: URL) -> URL {
        repoRoot
            .appending(path: "vendor")
            .appending(path: "runtime")
    }
}
