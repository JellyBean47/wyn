//
//  WynWineInstaller.swift
//  WynKit
//

import Foundation
import SemanticVersion

/// Which installed Wine tree to run.
/// - `game`: GPTK-aware `Libraries/` (D3DMetal / DXMT / DXVK for titles)
/// - `steam`: frankea `Libraries.steam` (or pre-GPTK bak) — Steam CEF login UI
/// - `rgl`: Rockstar clone tree (`Libraries.rgl`) — not Steam, not GPTK
public enum WineTree: String, Sendable, CaseIterable {
    case game
    case steam
    case rgl

    public var displayName: String {
        switch self {
        case .game: return "game (GPTK-aware Libraries)"
        case .steam: return "steam (frankea Libraries.steam)"
        case .rgl: return "rgl (Libraries.rgl)"
        }
    }
}

public class WynWineInstaller {
    public static let applicationFolder = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    )[0].appending(path: Bundle.wynSupportIdentifier)

    public static let libraryFolder = applicationFolder.appending(path: "Libraries")
    public static let binFolder: URL = libraryFolder.appending(path: "Wine").appending(path: "bin")

    private static let versionPlistNames = ["WynWineVersion", "FlyWineVersion", "WhiskyWineVersion"]

    public static func isWynWineInstalled() -> Bool {
        wynWineVersion() != nil && FileManager.default.fileExists(atPath: wine64Path.path)
    }

    private static var wine64Path: URL {
        binFolder.appending(path: "wine64")
    }

    /// Sibling backup left by GPTK-aware installs — frankea WhiskyWine with MoltenVK/FreeType/gnutls.
    public static var preGPTKAwareBackupFolder: URL {
        applicationFolder.appending(path: "Libraries.pre-gptk-aware.bak")
    }

    /// Stable Steam-only Wine tree (`Libraries.steam`). Falls back to the pre-GPTK bak.
    /// GPTK-aware `Libraries/` breaks Steam CEF; frankea Wine keeps login UI working.
    public static var steamLibraryFolder: URL {
        let dedicated = applicationFolder.appending(path: "Libraries.steam")
        let dedicatedWine = dedicated.appending(path: "Wine").appending(path: "bin").appending(path: "wine64")
        if FileManager.default.fileExists(atPath: dedicatedWine.path(percentEncoded: false)) {
            return dedicated
        }
        let fossWine = libraryFolder.appending(path: "Wine").appending(path: "bin").appending(path: "wine64")
        if FileManager.default.fileExists(atPath: fossWine.path(percentEncoded: false)) {
            return libraryFolder
        }
        return preGPTKAwareBackupFolder
    }

    public static var steamBinFolder: URL {
        steamLibraryFolder.appending(path: "Wine").appending(path: "bin")
    }

    /// Rockstar / RDR2 clone tree. Do not use for Steam or Connect.
    public static var rglLibraryFolder: URL {
        applicationFolder.appending(path: "Libraries.rgl")
    }

    public static func isSteamWineInstalled() -> Bool {
        let wine64 = steamBinFolder.appending(path: "wine64")
        return FileManager.default.fileExists(atPath: wine64.path(percentEncoded: false))
    }

    /// Ensure `Libraries.steam` exists (symlink to pre-GPTK bak when needed). Returns the tree root.
    /// Also repairs missing `libvulkan.1.dylib` → MoltenVK (required for DXVK on frankea).
    @discardableResult
    public static func ensureSteamWineTree() throws -> URL {
        let fm = FileManager.default
        let dedicated = applicationFolder.appending(path: "Libraries.steam")
        let dedicatedWine = dedicated.appending(path: "Wine").appending(path: "bin").appending(path: "wine64")
        let root: URL
        if fm.fileExists(atPath: dedicatedWine.path(percentEncoded: false)) {
            root = dedicated
        } else {
            let bak = preGPTKAwareBackupFolder
            let bakWine = bak.appending(path: "Wine").appending(path: "bin").appending(path: "wine64")
            let fossWine = libraryFolder.appending(path: "Wine").appending(path: "bin").appending(path: "wine64")
            // Fresh FOSS setup only has Libraries/. The pre-GPTK bak exists
            // only after a later GPTK-aware install.
            let source: URL
            if fm.fileExists(atPath: bakWine.path(percentEncoded: false)) {
                source = bak
            } else if fm.fileExists(atPath: fossWine.path(percentEncoded: false)) {
                source = libraryFolder
            } else {
                throw CocoaError(.fileNoSuchFile)
            }

            if fm.fileExists(atPath: dedicated.path(percentEncoded: false)) {
                try fm.removeItem(at: dedicated)
            }
            try fm.createSymbolicLink(at: dedicated, withDestinationURL: source)
            root = dedicated
        }
        try ensureFrankeaVulkanLinks(in: root)
        try ensureFrankeaDXVKPayload(in: root)
        return root
    }

    /// Ensure frankea `DXVK/` is the MoltenVK-tolerant macOS build (Gcenx 1.10.3-async),
    /// not upstream DXVK 2.x from GPTK Libraries (hard-requires geometryShader → CreateDXGIFactory AV).
    @discardableResult
    public static func ensureFrankeaDXVKPayload(in libraryRoot: URL? = nil) throws -> Bool {
        let fm = FileManager.default
        let root = libraryRoot ?? steamLibraryFolder
        let dest = root.appending(path: "DXVK")
        let destD3d11 = dest.appending(path: "x64").appending(path: "d3d11.dll")
        let destDxgi = dest.appending(path: "x64").appending(path: "dxgi.dll")

        // Frankea Libraries.tar.gz already ships Gcenx DXVK-macOS. Do not copy
        // from a gitignored whisky-wine/ tree (not a public install path).
        if fm.fileExists(atPath: destD3d11.path(percentEncoded: false)),
           fm.fileExists(atPath: destDxgi.path(percentEncoded: false)) {
            return true
        }

        let supportDXVK = applicationFolder.appending(path: "DXVK-macos")
        let supportD3d11 = supportDXVK.appending(path: "x64").appending(path: "d3d11.dll")
        let supportDxgi = supportDXVK.appending(path: "x64").appending(path: "dxgi.dll")
        if fm.fileExists(atPath: supportD3d11.path(percentEncoded: false)),
           fm.fileExists(atPath: supportDxgi.path(percentEncoded: false)) {
            if fm.fileExists(atPath: dest.path(percentEncoded: false)) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: supportDXVK, to: dest)
            return true
        }

        return fm.fileExists(atPath: destD3d11.path(percentEncoded: false))
    }

    /// Frankea ships `libMoltenVK.dylib` but often lacks `libvulkan.1.dylib`.
    /// winevulkan/DXVK dlopen `libvulkan.1.dylib` — without the symlink, CreateDXGIFactory AVs
    /// and Wyn incorrectly falls back to wined3d (fake GeForce 6800 → Feature Level 11.0 dialog).
    @discardableResult
    public static func ensureFrankeaVulkanLinks(in libraryRoot: URL? = nil) throws -> Int {
        let fm = FileManager.default
        let root = libraryRoot ?? steamLibraryFolder
        let destLib = root.appending(path: "Wine").appending(path: "lib")
        guard fm.fileExists(atPath: destLib.path(percentEncoded: false)) else { return 0 }

        var fixed = 0
        let molten = destLib.appending(path: "libMoltenVK.dylib")
        let vulkan = destLib.appending(path: "libvulkan.1.dylib")
        if fm.fileExists(atPath: molten.path(percentEncoded: false)),
           !fm.fileExists(atPath: vulkan.path(percentEncoded: false)) {
            try fm.createSymbolicLink(
                atPath: vulkan.path(percentEncoded: false),
                withDestinationPath: "libMoltenVK.dylib"
            )
            fixed += 1
        }

        let unixDir = destLib.appending(path: "wine").appending(path: "x86_64-unix")
        if fm.fileExists(atPath: unixDir.path(percentEncoded: false)) {
            for name in ["libvulkan.1.dylib", "libMoltenVK.dylib"] {
                let link = unixDir.appending(path: name)
                let target = destLib.appending(path: name)
                guard fm.fileExists(atPath: target.path(percentEncoded: false)),
                      !fm.fileExists(atPath: link.path(percentEncoded: false)) else { continue }
                try fm.createSymbolicLink(
                    atPath: link.path(percentEncoded: false),
                    withDestinationPath: "../../\(name)"
                )
                fixed += 1
            }
        }
        return fixed
    }

    public static func libraryFolder(for tree: WineTree) -> URL {
        switch tree {
        case .game: return libraryFolder
        case .steam: return steamLibraryFolder
        case .rgl: return rglLibraryFolder
        }
    }

    public static func binFolder(for tree: WineTree) -> URL {
        libraryFolder(for: tree).appending(path: "Wine").appending(path: "bin")
    }

    public static func isWineInstalled(for tree: WineTree) -> Bool {
        let wine64 = binFolder(for: tree).appending(path: "wine64")
        return FileManager.default.fileExists(atPath: wine64.path(percentEncoded: false))
    }

    public static func install(from tarball: URL, expectedSHA256: String? = nil) throws {
        try RuntimeIntegrity.assertNoAppleGPTK(inTarball: tarball)
        if let expectedSHA256 {
            try RuntimeIntegrity.verifySHA256(of: tarball, expected: expectedSHA256)
        }

        let fm = FileManager.default
        if !fm.fileExists(atPath: applicationFolder.path) {
            try fm.createDirectory(at: applicationFolder, withIntermediateDirectories: true)
        }

        // Replace Libraries wholesale so stale PE/unix modules from a prior runtime don't linger.
        if fm.fileExists(atPath: libraryFolder.path) {
            try fm.removeItem(at: libraryFolder)
        }

        try Tar.untar(tarBall: tarball, toURL: applicationFolder)

        if tarball.path.contains(fm.temporaryDirectory.path) {
            try? fm.removeItem(at: tarball)
        }
    }

    public static func installFromDirectory(_ source: URL) throws {
        try RuntimeIntegrity.assertNoAppleGPTK(inDirectory: source)
        if FileManager.default.fileExists(atPath: libraryFolder.path) {
            try FileManager.default.removeItem(at: libraryFolder)
        }
        try FileManager.default.createDirectory(at: applicationFolder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: libraryFolder)
    }

    /// EricSpencer GPTK-aware Wine ships without MoltenVK/FreeType/GnuTLS dylibs.
    /// Copy companion libs from a frankea-style tree (usually `Libraries.pre-gptk-aware.bak`)
    /// and ensure `libvulkan.1.dylib` + unix-dir lookups work for Steam CEF.
    @discardableResult
    public static func mergeCompanionLibraries(from backupLibRoot: URL? = nil) throws -> Int {
        let fm = FileManager.default
        let destLib = libraryFolder.appending(path: "Wine").appending(path: "lib")
        guard fm.fileExists(atPath: destLib.path(percentEncoded: false)) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let sourceLib: URL
        if let backupLibRoot {
            sourceLib = backupLibRoot
        } else {
            let bak = preGPTKAwareBackupFolder.appending(path: "Wine").appending(path: "lib")
            guard fm.fileExists(atPath: bak.path(percentEncoded: false)) else {
                return 0
            }
            sourceLib = bak
        }

        var copied = 0
        let skip = Set(["wine", "external"])
        guard let entries = try? fm.contentsOfDirectory(
            at: sourceLib,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        for entry in entries {
            let name = entry.lastPathComponent
            if skip.contains(name) { continue }
            let dest = destLib.appending(path: name)
            if fm.fileExists(atPath: dest.path(percentEncoded: false)) { continue }
            try fm.copyItem(at: entry, to: dest)
            copied += 1
        }

        // EricSpencer win32u dlopens libvulkan.1.dylib; frankea ships libMoltenVK.dylib only.
        let molten = destLib.appending(path: "libMoltenVK.dylib")
        let vulkan = destLib.appending(path: "libvulkan.1.dylib")
        if fm.fileExists(atPath: molten.path(percentEncoded: false)),
           !fm.fileExists(atPath: vulkan.path(percentEncoded: false)) {
            try fm.createSymbolicLink(
                atPath: vulkan.path(percentEncoded: false),
                withDestinationPath: "libMoltenVK.dylib"
            )
            copied += 1
        }

        // phase1l win32u rpath is often only @loader_path/ (unix dir), not ../../.
        let unixDir = destLib.appending(path: "wine").appending(path: "x86_64-unix")
        let unixLinks = ["libvulkan.1.dylib", "libfreetype.6.dylib", "libgnutls.30.dylib"]
        for name in unixLinks {
            let link = unixDir.appending(path: name)
            let target = destLib.appending(path: name)
            guard fm.fileExists(atPath: target.path(percentEncoded: false)),
                  !fm.fileExists(atPath: link.path(percentEncoded: false)) else { continue }
            try fm.createSymbolicLink(
                atPath: link.path(percentEncoded: false),
                withDestinationPath: "../../\(name)"
            )
            copied += 1
        }

        return copied
    }

    public static func uninstall() throws {
        try FileManager.default.removeItem(at: libraryFolder)
    }

    public static func shouldUpdateWynWine(source: RuntimeSource = RuntimeManager.activeSource) async -> (Bool, SemanticVersion) {
        guard source == .whiskyCDN, let remoteURL = source.versionPlistURL else {
            return (false, SemanticVersion(0, 0, 0))
        }

        let localVersion = wynWineVersion()
        let remoteVersion = await fetchRemoteVersion(from: remoteURL)

        if let localVersion, let remoteVersion, localVersion < remoteVersion {
            return (true, remoteVersion)
        }

        return (false, SemanticVersion(0, 0, 0))
    }

    public static func downloadURL(for version: SemanticVersion, source: RuntimeSource = RuntimeManager.activeSource) -> URL? {
        if let direct = source.directLibrariesURL {
            return direct
        }
        guard let base = source.releasesBaseURL else { return nil }
        let tag = "v\(version.major).\(version.minor).\(version.patch)"
        return base.appending(path: tag).appending(path: "Libraries.tar.gz")
    }

    public static func fetchRemoteVersion(from url: URL) async -> SemanticVersion? {
        await withCheckedContinuation { continuation in
            URLSession.shared.dataTask(with: url) { data, response, _ in
                guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode),
                      let data,
                      let info = try? PropertyListDecoder().decode(WynWineVersion.self, from: data) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: info.version)
            }.resume()
        }
    }

    public static func wynWineVersion() -> SemanticVersion? {
        for name in versionPlistNames {
            let versionPlist = libraryFolder.appending(path: name).appendingPathExtension("plist")
            guard FileManager.default.fileExists(atPath: versionPlist.path(percentEncoded: false)) else { continue }

            do {
                let data = try Data(contentsOf: versionPlist)
                let info = try PropertyListDecoder().decode(WynWineVersion.self, from: data)
                return info.version
            } catch {
                continue
            }
        }
        return nil
    }

}

struct WynWineVersion: Codable {
    var version: SemanticVersion = SemanticVersion(1, 0, 0)

    enum CodingKeys: String, CodingKey {
        case version
    }

    enum VersionKeys: String, CodingKey {
        case major, minor, patch
    }

    init(version: SemanticVersion = SemanticVersion(1, 0, 0)) {
        self.version = version
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let versionDict = try? container.nestedContainer(keyedBy: VersionKeys.self, forKey: .version) {
            let major = try versionDict.decode(Int.self, forKey: .major)
            let minor = try versionDict.decode(Int.self, forKey: .minor)
            let patch = try versionDict.decode(Int.self, forKey: .patch)
            version = SemanticVersion(major, minor, patch)
        } else {
            version = try container.decode(SemanticVersion.self, forKey: .version)
        }
    }
}
