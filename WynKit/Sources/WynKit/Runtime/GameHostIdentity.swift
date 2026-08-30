//
//  GameHostIdentity.swift
//  WynKit
//
//  D3DMetal game-host must be Sikarugir CrossOver-hosted Wine, not Whisky
//  with GPTK bolted on. Wyn does not vendor or download CrossOver Wine.
//

import Foundation

/// Structural identity of `Libraries/Wine` as the D3DMetal game-host.
public enum GameHostIdentity {
    /// Parked CX `wineserver` on the machine that proved Satisfactory (~593760, 4 Jun).
    public static let cxWineserverBytesExample = 593760
    /// Parked Whisky `wineserver` that must not be the game-host (~856608, 25 Apr).
    public static let whiskyWineserverBytesExample = 856608

    public static let howToObtain = """
    D3DMetal game-host is Sikarugir CrossOver-hosted Wine. Wyn will not download it.

    CrossOver Wine is CodeWeavers' product — Wyn does not redistribute it and will
    not fetch unofficial "CX engine" tarballs. Get a tree you are licensed to use:

      1. CrossOver from https://www.codeweavers.com/crossover (trial or purchase), or
      2. A Sikarugir wrapper whose engine is that CrossOver-hosted Wine
         (Sikarugir itself: https://github.com/Sikarugir-App/Sikarugir).

    Then copy or link it into Wyn's Libraries (not into this git tree):

      ./scripts/install-cx-game-host.sh --directory /Applications/CrossOver.app
      # or
      wyn runtime install --gptk-aware --directory /Applications/CrossOver.app

    A Sikarugir wrapper works the same: pass the .app. --link keeps CrossOver.app
    as the bytes; omit it to ditto into:
      ~/Library/Application Support/com.fly.gaming/Libraries/

    Identity (refuses Whisky-as-game-host):
      Wine/bin -> CrossOver-Hosted Application  (symlink or that folder copied to bin/)
      wine64 -> wineloader
      lib64/apple_gptk present
      wineserver is CX-class (parked ~593760 / 4 Jun), not Whisky (~856608 / 25 Apr)

    GPTK 3.0 is separate. After the CX tree is in place:
      wyn gptk install --from /path/to/Apple/GPTK/redist-or-dmg
    that overlays D3DMetal.framework + libd3dshared onto the CX tree.

    frankea (./scripts/setup.sh, Libraries-v3.1.1) stays DXMT / window rollback
    as Libraries.steam. Steam UI for D3DMetal 3.0 uses the game-host wineserver.
    Isolation AppDefaults for steam.exe / steamwebhelper must be =b (not n,b).
    """

    public struct Report: Sendable {
        public let wineRoot: URL
        public let binURL: URL
        public let binIsCrossOverHosted: Bool
        public let wine64IsWineloader: Bool
        public let appleGPTKPresent: Bool
        public let wineserverBytes: Int?
        public let looksLikeWhisky: Bool
        public let ntdllGPTKAware: Bool
        public let isCrossOverHosted: Bool
        public var refusal: String? {
            if looksLikeWhisky {
                return """
                Refusing Whisky-as-game-host. D3DMetal needs Sikarugir CrossOver-hosted \
                Wine (wine64 -> wineloader, lib64/apple_gptk), not Whisky 11 + GPTK. \
                Parked Whisky wineserver is ~\(GameHostIdentity.whiskyWineserverBytesExample) bytes (25 Apr); \
                CX is ~\(GameHostIdentity.cxWineserverBytesExample) (4 Jun). \
                frankea/setup.sh remains the DXMT rollback tree.
                """
            }
            if !isCrossOverHosted {
                return """
                Libraries/Wine is not CrossOver-hosted. Need Wine/bin -> CrossOver-Hosted \
                Application, wine64 -> wineloader, and lib64/apple_gptk.
                """
            }
            return nil
        }

        public var rendered: String {
            var lines: [String] = []
            lines.append("Game-host Wine:    \(wineRoot.path(percentEncoded: false))")
            lines.append("Wine/bin:          \(binURL.path(percentEncoded: false))")
            lines.append("bin is CX-hosted:  \(binIsCrossOverHosted ? "yes" : "no")")
            lines.append("wine64 wineloader: \(wine64IsWineloader ? "yes" : "no")")
            lines.append("lib64/apple_gptk:  \(appleGPTKPresent ? "yes" : "no")")
            if let n = wineserverBytes {
                lines.append("wineserver bytes:  \(n)")
            } else {
                lines.append("wineserver bytes:  (missing)")
            }
            lines.append("Looks like Whisky: \(looksLikeWhisky ? "YES — refused as game-host" : "no")")
            lines.append("ntdll CX_APPLEGPTK:\(ntdllGPTKAware ? "yes" : "no")")
            lines.append("CX game-host:      \(isCrossOverHosted ? "yes" : "no")")
            if let refusal {
                lines.append("Refuse:            \(refusal.split(separator: "\n").first.map(String.init) ?? refusal)")
            }
            return lines.joined(separator: "\n")
        }
    }

    public enum HostError: LocalizedError, Equatable {
        case missingSource(String)
        case notCrossOverHosted(String)
        case whiskyRefused(String)

        public var errorDescription: String? {
            switch self {
            case .missingSource(let detail):
                return "No CrossOver-hosted Wine at \(detail).\n\n\(GameHostIdentity.howToObtain)"
            case .notCrossOverHosted(let detail):
                return "\(detail)\n\n\(GameHostIdentity.howToObtain)"
            case .whiskyRefused(let detail):
                return detail
            }
        }
    }

    public static func inspect(libraryFolder: URL = WynWineInstaller.libraryFolder) -> Report {
        inspectWineRoot(libraryFolder.appending(path: "Wine"))
    }

    public static func inspectWineRoot(_ wineRoot: URL) -> Report {
        let fm = FileManager.default
        let bin = binFolder(in: wineRoot)
        let wine64 = bin.appending(path: "wine64")
        let wineserver = bin.appending(path: "wineserver")
        let apple = wineRoot.appending(path: "lib64").appending(path: "apple_gptk")

        let binCX = isCrossOverHostedBin(bin)
        let loader = resolvesToWineloader(wine64)
        let applePresent = directoryExists(apple)
        let serverBytes = fileSize(of: wineserver)
        let whiskyPlist = fm.fileExists(
            atPath: wineRoot.deletingLastPathComponent()
                .appending(path: "WhiskyWineVersion.plist")
                .path(percentEncoded: false)
        )
        let whiskyBySize = serverBytes.map { abs($0 - whiskyWineserverBytesExample) < 80_000 } ?? false
        let looksWhisky = (!loader && (whiskyBySize || whiskyPlist))
            || (whiskyBySize && !loader)
            || (whiskyPlist && !loader && !applePresent)

        let hosted = (binCX || loader) && loader && applePresent && !looksWhisky

        return Report(
            wineRoot: wineRoot,
            binURL: bin,
            binIsCrossOverHosted: binCX,
            wine64IsWineloader: loader,
            appleGPTKPresent: applePresent,
            wineserverBytes: serverBytes,
            looksLikeWhisky: looksWhisky,
            ntdllGPTKAware: ntdllHasCXAppleGPTK(in: wineRoot),
            isCrossOverHosted: hosted
        )
    }

    public static func isCrossOverHosted(libraryFolder: URL = WynWineInstaller.libraryFolder) -> Bool {
        inspect(libraryFolder: libraryFolder).isCrossOverHosted
    }

    public static func assertGameHost(libraryFolder: URL = WynWineInstaller.libraryFolder) throws {
        let report = inspect(libraryFolder: libraryFolder)
        if let refusal = report.refusal {
            if report.looksLikeWhisky {
                throw HostError.whiskyRefused(refusal)
            }
            throw HostError.notCrossOverHosted(refusal)
        }
    }

    /// Map CrossOver.app, a Sikarugir wrapper, a Wine root, or a Wyn Libraries/ tree
    /// to the folder that contains `bin/` or `CrossOver-Hosted Application/`.
    public static func resolveWineRoot(from userPath: URL) -> URL? {
        let fm = FileManager.default
        let path = userPath.path(percentEncoded: false)
        guard fm.fileExists(atPath: path) else { return nil }

        var candidates: [URL] = [userPath]
        if userPath.pathExtension == "app" {
            let shared = userPath.appending(path: "Contents").appending(path: "SharedSupport")
            candidates.append(shared.appending(path: "CrossOver"))
            candidates.append(shared.appending(path: "wine"))
        }
        candidates.append(userPath.appending(path: "Wine"))
        candidates.append(userPath.appending(path: "Contents").appending(path: "SharedSupport").appending(path: "CrossOver"))
        candidates.append(userPath.appending(path: "Contents").appending(path: "SharedSupport").appending(path: "wine"))

        for c in candidates {
            if isWineRoot(c) { return c }
            let hosted = c.appending(path: "CrossOver-Hosted Application")
            if isWineRoot(hosted) { return c }
            if c.lastPathComponent == "CrossOver-Hosted Application", isWineRoot(c) {
                return c.deletingLastPathComponent()
            }
        }
        return nil
    }

    public static func isWineRoot(_ url: URL) -> Bool {
        let bin = binFolder(in: url)
        let wine64 = bin.appending(path: "wine64")
        let loader = bin.appending(path: "wineloader")
        let wine = bin.appending(path: "wine")
        return fileExists(wine64) || fileExists(loader) || fileExists(wine)
    }

    /// Copy or symlink a user-supplied CX/Sikarugir Wine tree into `Libraries/`.
    /// Parks a non-CX `Libraries/` as `Libraries.pre-gptk-aware.bak` (frankea rollback).
    public static func install(from userPath: URL, link: Bool) throws {
        guard let sourceRoot = resolveWineRoot(from: userPath) else {
            throw HostError.missingSource(userPath.path(percentEncoded: false))
        }
        let sourceReport = inspectWineRoot(sourceRoot)
        if sourceReport.looksLikeWhisky {
            throw HostError.whiskyRefused(sourceReport.refusal ?? "Whisky Wine cannot be the D3DMetal game-host.")
        }
        if !sourceReport.isCrossOverHosted {
            throw HostError.notCrossOverHosted(
                sourceReport.refusal ?? "Source is not CrossOver-hosted Wine."
            )
        }

        try parkNonCrossOverLibraries()
        try materialize(from: sourceRoot, link: link)
        try assertGameHost()
    }

    public static func parkNonCrossOverLibraries() throws {
        let fm = FileManager.default
        let libraries = WynWineInstaller.libraryFolder
        guard fm.fileExists(atPath: libraries.path(percentEncoded: false)) else { return }
        if inspect(libraryFolder: libraries).isCrossOverHosted { return }

        let bak = WynWineInstaller.preGPTKAwareBackupFolder
        if fm.fileExists(atPath: bak.path(percentEncoded: false)) {
            let steamWine = WynWineInstaller.applicationFolder
                .appending(path: "Libraries.steam")
                .appending(path: "Wine")
                .appending(path: "bin")
                .appending(path: "wine64")
            if !fm.fileExists(atPath: steamWine.path(percentEncoded: false)) {
                try WynWineInstaller.ensureSteamWineTree()
            }
            try fm.removeItem(at: libraries)
        } else {
            try fm.moveItem(at: libraries, to: bak)
        }
        try WynWineInstaller.ensureSteamWineTree()
    }

    private static func materialize(from sourceRoot: URL, link: Bool) throws {
        let fm = FileManager.default
        let destWine = WynWineInstaller.libraryFolder.appending(path: "Wine")
        try fm.createDirectory(at: WynWineInstaller.applicationFolder, withIntermediateDirectories: true)
        if fm.fileExists(atPath: destWine.path(percentEncoded: false)) {
            try fm.removeItem(at: destWine)
        }
        try fm.createDirectory(at: destWine, withIntermediateDirectories: true)

        let hosted = sourceRoot.appending(path: "CrossOver-Hosted Application")
        let sourceBin: URL
        if directoryExists(hosted) {
            sourceBin = hosted
        } else {
            sourceBin = binFolder(in: sourceRoot)
        }

        try transfer(from: sourceBin, to: destWine.appending(path: "bin"), link: link)

        for name in ["lib", "lib64", "share", "include"] {
            let src = sourceRoot.appending(path: name)
            guard fm.fileExists(atPath: src.path(percentEncoded: false)) else { continue }
            try transfer(from: src, to: destWine.appending(path: name), link: link)
        }
    }

    private static func transfer(from src: URL, to dst: URL, link: Bool) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dst.path(percentEncoded: false)) {
            try fm.removeItem(at: dst)
        }
        if link {
            try fm.createSymbolicLink(at: dst, withDestinationURL: src)
        } else {
            try fm.copyItem(at: src, to: dst)
        }
    }

    public static func ntdllHasCXAppleGPTK(in wineRoot: URL) -> Bool {
        let ntdll = wineRoot
            .appending(path: "lib")
            .appending(path: "wine")
            .appending(path: "x86_64-unix")
            .appending(path: "ntdll.so")
        let ntdll64 = wineRoot
            .appending(path: "lib64")
            .appending(path: "wine")
            .appending(path: "x86_64-unix")
            .appending(path: "ntdll.so")
        for url in [ntdll, ntdll64] {
            guard let data = try? Data(contentsOf: url) else { continue }
            if data.range(of: Data("CX_APPLEGPTK_LIBD3DSHARED_PATH".utf8)) != nil {
                return true
            }
        }
        return false
    }

    private static func binFolder(in wineRoot: URL) -> URL {
        let hosted = wineRoot.appending(path: "CrossOver-Hosted Application")
        if directoryExists(hosted) { return hosted }
        return wineRoot.appending(path: "bin")
    }

    private static func isCrossOverHostedBin(_ bin: URL) -> Bool {
        if bin.lastPathComponent == "CrossOver-Hosted Application" { return true }
        let path = bin.path(percentEncoded: false)
        if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
            return URL(fileURLWithPath: dest).lastPathComponent == "CrossOver-Hosted Application"
        }
        return bin.resolvingSymlinksInPath().lastPathComponent == "CrossOver-Hosted Application"
    }

    private static func resolvesToWineloader(_ wine64: URL) -> Bool {
        guard fileExists(wine64) else { return false }
        if wine64.lastPathComponent == "wineloader" { return true }
        let path = wine64.path(percentEncoded: false)
        if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
            if URL(fileURLWithPath: dest).lastPathComponent == "wineloader" { return true }
        }
        return wine64.resolvingSymlinksInPath().lastPathComponent == "wineloader"
    }

    private static func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    private static func directoryExists(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        let ok = FileManager.default.fileExists(
            atPath: url.path(percentEncoded: false),
            isDirectory: &isDir
        )
        return ok && isDir.boolValue
    }

    private static func fileSize(of url: URL) -> Int? {
        let resolved = url.resolvingSymlinksInPath()
        guard let attrs = try? FileManager.default.attributesOfItem(
            atPath: resolved.path(percentEncoded: false)
        ) else { return nil }
        return (attrs[.size] as? NSNumber)?.intValue
    }
}
