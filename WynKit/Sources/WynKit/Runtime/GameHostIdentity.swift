//
//  GameHostIdentity.swift
//  WynKit
//
//  D3DMetal game-host must be FOSS winecx (ntdll CX_APPLEGPTK + unix
//  libd3dshared symlinks), not a proprietary Wine.app / wineloader layout,
//  and not Whisky 11 without those hooks.
//

import Foundation

/// Structural identity of `Libraries/Wine` as the D3DMetal game-host.
public enum GameHostIdentity {
    /// Parked Whisky `wineserver` that must not be the game-host (~856608, 25 Apr).
    public static let whiskyWineserverBytesExample = 856608

    /// Filesystem names of a proprietary Wine.app layout. Matched only so install
    /// can refuse that tree; Wyn does not use or copy it.
    private static let refusedAppBundleName = "CrossOver"
    private static let refusedAppPathFragment = "/CrossOver.app"
    private static let refusedHostedBinName = "CrossOver-Hosted Application"

    public static let howToObtain = """
    D3DMetal game-host is self-built FOSS winecx (Wine 11.15 + in-tree GPTK ntdll \
    hook). Wyn will not download Wine for --gptk-aware. Proprietary Wine.app \
    bundles and wineloader layouts are refused. Whisky 11 with GPTK bolted on \
    is not accepted.

    Build from the pinned winecx tree (mingw-w64 gcc, not llvm-mingw):

      ./scripts/build-foss-game-host.sh

    Source: https://github.com/dappermint/winecx  (wine1115 / WINECX_COMMIT in \
    that script). Then:

      wyn runtime install --gptk-aware --directory /path/to/wine-prefix-or-Libraries
      wyn gptk install --from /path/to/Apple/GPTK/redist-or-dmg

    Identity:
      ntdll.so contains CX_APPLEGPTK_LIBD3DSHARED_PATH (winecx GPTK hook)
      wine64 is a normal Wine loader (not wineloader)
      Wine/bin is an ordinary bin/ directory
      after GPTK overlay: d3d11.so / dxgi.so / d3d12.so are symlinks to \
    lib/external/libd3dshared.dylib beside D3DMetal.framework

    Refuses:
      proprietary Wine.app / wineloader / hosted-application bin
      Whisky 11 / frankea v3.1.1 (no ntdll hook) — that stays DXMT rollback \
    as Libraries.steam via ./scripts/setup.sh

    Isolation AppDefaults for steam.exe / steamwebhelper must be =b (not n,b).
    """

    public struct Report: Sendable {
        public let wineRoot: URL
        public let binURL: URL
        public let binIsProprietaryHosted: Bool
        public let wine64IsWineloader: Bool
        public let appleGPTKPresent: Bool
        public let wineserverBytes: Int?
        public let looksLikeWhisky: Bool
        public let ntdllGPTKAware: Bool
        public let unixD3DMetalWired: Bool
        public let isProprietaryHosted: Bool
        public let isFOSSGPTKHost: Bool
        public var refusal: String? {
            if isProprietaryHosted {
                return """
                Refusing a proprietary Wine loader as the D3DMetal game-host \
                (wineloader / hosted-application bin). \
                Build FOSS winecx and pass that tree to \
                wyn runtime install --gptk-aware --directory …
                """
            }
            if looksLikeWhisky {
                return """
                Refusing Whisky-as-game-host. D3DMetal needs FOSS winecx with \
                ntdll CX_APPLEGPTK_LIBD3DSHARED_PATH, not Whisky 11 + GPTK overlay. \
                Parked Whisky wineserver is ~\(GameHostIdentity.whiskyWineserverBytesExample) bytes (25 Apr). \
                frankea/setup.sh remains the DXMT rollback tree.
                """
            }
            if !ntdllGPTKAware {
                return """
                Libraries/Wine is not a FOSS GPTK game-host. Need ntdll.so with \
                CX_APPLEGPTK_LIBD3DSHARED_PATH, and wine64 must not be wineloader.
                """
            }
            if !isFOSSGPTKHost {
                return """
                Libraries/Wine is not accepted as the D3DMetal game-host.
                """
            }
            return nil
        }

        public var rendered: String {
            var lines: [String] = []
            lines.append("Game-host Wine:    \(wineRoot.path(percentEncoded: false))")
            lines.append("Wine/bin:          \(binURL.path(percentEncoded: false))")
            lines.append("bin hosted layout: \(binIsProprietaryHosted ? "yes — refused" : "no")")
            lines.append("wine64 wineloader: \(wine64IsWineloader ? "yes — refused" : "no")")
            lines.append("lib64/apple_gptk:  \(appleGPTKPresent ? "yes (unused for FOSS host)" : "no")")
            if let n = wineserverBytes {
                lines.append("wineserver bytes:  \(n)")
            } else {
                lines.append("wineserver bytes:  (missing)")
            }
            lines.append("Looks like Whisky: \(looksLikeWhisky ? "YES — refused as game-host" : "no")")
            lines.append("ntdll CX_APPLEGPTK:\(ntdllGPTKAware ? "yes" : "no")")
            lines.append("unix libd3dshared: \(unixD3DMetalWired ? "yes (symlinks)" : "no")")
            lines.append("proprietary host:  \(isProprietaryHosted ? "yes — refused" : "no")")
            lines.append("FOSS GPTK host:    \(isFOSSGPTKHost ? "yes" : "no")")
            if let refusal {
                lines.append("Refuse:            \(refusal.split(separator: "\n").first.map(String.init) ?? refusal)")
            }
            return lines.joined(separator: "\n")
        }
    }

    public enum HostError: LocalizedError, Equatable {
        case missingSource(String)
        case proprietaryHostRefused(String)
        case notFOSSGPTKHost(String)
        case whiskyRefused(String)

        public var errorDescription: String? {
            switch self {
            case .missingSource(let detail):
                return "No FOSS winecx tree at \(detail).\n\n\(GameHostIdentity.howToObtain)"
            case .proprietaryHostRefused(let detail):
                return "\(detail)\n\n\(GameHostIdentity.howToObtain)"
            case .notFOSSGPTKHost(let detail):
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

        let binHosted = isProprietaryHostedBin(bin)
        let loader = resolvesToWineloader(wine64)
        let applePresent = directoryExists(apple)
        let serverBytes = fileSize(of: wineserver)
        let ntdll = ntdllHasCXAppleGPTK(in: wineRoot)
        let whiskyPlist = fm.fileExists(
            atPath: wineRoot.deletingLastPathComponent()
                .appending(path: "WhiskyWineVersion.plist")
                .path(percentEncoded: false)
        )
        let whiskyBySize = serverBytes.map { abs($0 - whiskyWineserverBytesExample) < 80_000 } ?? false
        // Whisky 11 / v3.1.1: plist or wineserver size, and no ntdll GPTK hook.
        // winecx-gptk packaged as a Whisky beta (ntdll hook present) is not this.
        let looksWhisky = !ntdll && (whiskyBySize || whiskyPlist)

        let hosted = binHosted || loader
        let hasLoader = fileExists(wine64) || fileExists(bin.appending(path: "wine"))
        let foss = ntdll && !hosted && !looksWhisky && hasLoader

        return Report(
            wineRoot: wineRoot,
            binURL: bin,
            binIsProprietaryHosted: binHosted,
            wine64IsWineloader: loader,
            appleGPTKPresent: applePresent,
            wineserverBytes: serverBytes,
            looksLikeWhisky: looksWhisky,
            ntdllGPTKAware: ntdll,
            unixD3DMetalWired: unixD3DMetalWired(in: wineRoot),
            isProprietaryHosted: hosted,
            isFOSSGPTKHost: foss
        )
    }

    public static func isProprietaryHosted(libraryFolder: URL = WynWineInstaller.libraryFolder) -> Bool {
        inspect(libraryFolder: libraryFolder).isProprietaryHosted
    }

    public static func isFOSSGPTKHost(libraryFolder: URL = WynWineInstaller.libraryFolder) -> Bool {
        inspect(libraryFolder: libraryFolder).isFOSSGPTKHost
    }

    public static func assertGameHost(libraryFolder: URL = WynWineInstaller.libraryFolder) throws {
        let report = inspect(libraryFolder: libraryFolder)
        if let refusal = report.refusal {
            if report.isProprietaryHosted {
                throw HostError.proprietaryHostRefused(refusal)
            }
            if report.looksLikeWhisky {
                throw HostError.whiskyRefused(refusal)
            }
            throw HostError.notFOSSGPTKHost(refusal)
        }
    }

    /// Map a Wine prefix, a Wyn Libraries/ tree, or a Wine root to the folder
    /// that contains `bin/wine64`. Known proprietary .app layouts are still
    /// resolved so install() can refuse them.
    public static func resolveWineRoot(from userPath: URL) -> URL? {
        let fm = FileManager.default
        let path = userPath.path(percentEncoded: false)
        guard fm.fileExists(atPath: path) else { return nil }

        var candidates: [URL] = [userPath]
        if userPath.pathExtension == "app" {
            let shared = userPath.appending(path: "Contents").appending(path: "SharedSupport")
            candidates.append(shared.appending(path: refusedAppBundleName))
            candidates.append(shared.appending(path: "wine"))
        }
        candidates.append(userPath.appending(path: "Wine"))
        candidates.append(userPath.appending(path: "Contents").appending(path: "SharedSupport").appending(path: refusedAppBundleName))
        candidates.append(userPath.appending(path: "Contents").appending(path: "SharedSupport").appending(path: "wine"))

        for c in candidates {
            if isWineRoot(c) { return c }
            let hosted = c.appending(path: refusedHostedBinName)
            if isWineRoot(hosted) { return c }
            if c.lastPathComponent == refusedHostedBinName, isWineRoot(c) {
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

    /// Copy or symlink a user-supplied FOSS winecx tree into `Libraries/`.
    /// Parks a non-host `Libraries/` as `Libraries.pre-gptk-aware.bak` (frankea rollback).
    public static func install(from userPath: URL, link: Bool) throws {
        if looksLikeRefusedWineApp(userPath) {
            throw HostError.proprietaryHostRefused(
                "Refusing a proprietary Wine.app bundle at \(userPath.path(percentEncoded: false))."
            )
        }
        guard let sourceRoot = resolveWineRoot(from: userPath) else {
            throw HostError.missingSource(userPath.path(percentEncoded: false))
        }
        let sourceReport = inspectWineRoot(sourceRoot)
        if sourceReport.isProprietaryHosted {
            throw HostError.proprietaryHostRefused(
                sourceReport.refusal ?? "Source is a proprietary Wine loader."
            )
        }
        if sourceReport.looksLikeWhisky {
            throw HostError.whiskyRefused(sourceReport.refusal ?? "Whisky Wine cannot be the D3DMetal game-host.")
        }
        if !sourceReport.isFOSSGPTKHost {
            throw HostError.notFOSSGPTKHost(
                sourceReport.refusal ?? "Source is not FOSS winecx with ntdll CX_APPLEGPTK."
            )
        }

        try parkNonFOSSGameHostLibraries()
        try materialize(from: sourceRoot, link: link)
        try ensureWine64Symlink()
        try writeFOSSVersionPlist()
        try assertGameHost()
    }

    public static func parkNonFOSSGameHostLibraries() throws {
        let fm = FileManager.default
        let libraries = WynWineInstaller.libraryFolder
        guard fm.fileExists(atPath: libraries.path(percentEncoded: false)) else { return }
        if inspect(libraryFolder: libraries).isFOSSGPTKHost { return }

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

    /// True when unix `d3d11.so` (and dxgi/d3d12) are symlinks to `libd3dshared.dylib`.
    public static func unixD3DMetalWired(in wineRoot: URL) -> Bool {
        let unixDir = wineLibUnixDir(in: wineRoot)
        let needed = ["d3d11.so", "dxgi.so", "d3d12.so"]
        for name in needed {
            let link = unixDir.appending(path: name)
            guard let dest = symlinkDestination(of: link) else { return false }
            if !dest.contains("libd3dshared") { return false }
        }
        let external = wineRoot.appending(path: "lib").appending(path: "external")
        let dylib = external.appending(path: "libd3dshared.dylib")
        let framework = external.appending(path: "D3DMetal.framework")
        return fileExists(dylib) && directoryExists(framework)
    }

    private static func materialize(from sourceRoot: URL, link: Bool) throws {
        let fm = FileManager.default
        let destWine = WynWineInstaller.libraryFolder.appending(path: "Wine")
        try fm.createDirectory(at: WynWineInstaller.applicationFolder, withIntermediateDirectories: true)
        if fm.fileExists(atPath: destWine.path(percentEncoded: false)) {
            try fm.removeItem(at: destWine)
        }
        try fm.createDirectory(at: destWine, withIntermediateDirectories: true)

        // FOSS winecx ships an ordinary bin/. Hosted-application layouts are refused above.
        let sourceBin = sourceRoot.appending(path: "bin")

        try transfer(from: sourceBin, to: destWine.appending(path: "bin"), link: link)

        for name in ["lib", "lib64", "share", "include"] {
            let src = sourceRoot.appending(path: name)
            guard fm.fileExists(atPath: src.path(percentEncoded: false)) else { continue }
            try transfer(from: src, to: destWine.appending(path: name), link: link)
        }
    }

    /// Wine 11's macOS loader is `wine`; Wyn still execs `wine64`.
    private static func ensureWine64Symlink() throws {
        let bin = binFolder(in: WynWineInstaller.libraryFolder.appending(path: "Wine"))
        let wine64 = bin.appending(path: "wine64")
        let wine = bin.appending(path: "wine")
        if fileExists(wine64) { return }
        guard fileExists(wine) else { return }
        try FileManager.default.createSymbolicLink(
            atPath: wine64.path(percentEncoded: false),
            withDestinationPath: "wine"
        )
    }

    /// `isWynWineInstalled()` requires a version plist; frankea ships one, winecx destroot does not.
    private static func writeFOSSVersionPlist() throws {
        let url = WynWineInstaller.libraryFolder.appending(path: "WynWineVersion.plist")
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { return }
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>version</key>
            <dict>
                <key>major</key><integer>11</integer>
                <key>minor</key><integer>15</integer>
                <key>patch</key><integer>0</integer>
            </dict>
        </dict>
        </plist>
        """
        try plist.write(to: url, atomically: true, encoding: .utf8)
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

    private static func wineLibUnixDir(in wineRoot: URL) -> URL {
        let lib = wineRoot
            .appending(path: "lib")
            .appending(path: "wine")
            .appending(path: "x86_64-unix")
        if directoryExists(lib) { return lib }
        return wineRoot
            .appending(path: "lib64")
            .appending(path: "wine")
            .appending(path: "x86_64-unix")
    }

    private static func binFolder(in wineRoot: URL) -> URL {
        let hosted = wineRoot.appending(path: refusedHostedBinName)
        if directoryExists(hosted) { return hosted }
        return wineRoot.appending(path: "bin")
    }

    private static func looksLikeRefusedWineApp(_ url: URL) -> Bool {
        let path = url.path(percentEncoded: false)
        if url.pathExtension == "app", url.deletingPathExtension().lastPathComponent == refusedAppBundleName {
            return true
        }
        if path.contains(refusedAppPathFragment) { return true }
        return false
    }

    private static func isProprietaryHostedBin(_ bin: URL) -> Bool {
        if bin.lastPathComponent == refusedHostedBinName { return true }
        let path = bin.path(percentEncoded: false)
        if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
            return URL(fileURLWithPath: dest).lastPathComponent == refusedHostedBinName
        }
        return bin.resolvingSymlinksInPath().lastPathComponent == refusedHostedBinName
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

    private static func symlinkDestination(of url: URL) -> String? {
        let path = url.path(percentEncoded: false)
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else {
            return nil
        }
        return dest
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
