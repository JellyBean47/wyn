//
//  GPTKInstaller.swift
//  WynKit
//
//  Installs a *user-provided* Apple Game Porting Toolkit (D3DMetal) payload into
//  the WynWine tree. GPTK is proprietary — never ship it in Wyn releases; only
//  copy from a local GPTK redist / Apple DMG the user already has.
//

import Foundation

public enum GPTKInstaller {
    public enum GPTKError: LocalizedError, Equatable {
        case sourceMissing(URL)
        case payloadIncomplete(String)
        case wineTreeMissing
        case requiresExplicitSource

        public var errorDescription: String? {
            switch self {
            case .sourceMissing(let url):
                return "GPTK source not found at \(url.path(percentEncoded: false))"
            case .payloadIncomplete(let detail):
                return "GPTK payload incomplete: \(detail)"
            case .wineTreeMissing:
                return "WynWine is not installed. Run: wyn install"
            case .requiresExplicitSource:
                return """
                GPTK/D3DMetal is not bundled. Download Game Porting Toolkit from Apple, then:
                  wyn gptk install --from /path/to/redist
                https://developer.apple.com/download/all/?q=game%20porting%20toolkit
                Wyn never downloads GPTK.
                """
            }
        }
    }

    /// `…/Libraries/Wine/lib`
    public static var wineLibFolder: URL {
        WynWineInstaller.libraryFolder.appending(path: "Wine").appending(path: "lib")
    }

    /// `…/Libraries/Wine/lib/external`
    public static var externalFolder: URL {
        wineLibFolder.appending(path: "external")
    }

    public static var libd3dsharedURL: URL {
        externalFolder.appending(path: "libd3dshared.dylib")
    }

    public static var d3dMetalFrameworkURL: URL {
        externalFolder.appending(path: "D3DMetal.framework")
    }

    /// True when D3DMetal.framework + libd3dshared sit under Wine/lib/external.
    public static func isInstalled() -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: libd3dsharedURL.path(percentEncoded: false))
            && fm.fileExists(atPath: d3dMetalFrameworkURL.path(percentEncoded: false))
    }

    /// `CFBundleShortVersionString` from installed D3DMetal.framework, if present.
    public static func installedD3DMetalVersion() -> String? {
        versionFromFramework(at: d3dMetalFrameworkURL)
    }

    /// Version string from a candidate framework URL.
    public static func versionFromFramework(at frameworkURL: URL) -> String? {
        let plist = frameworkURL
            .appending(path: "Resources")
            .appending(path: "Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        if let short = obj["CFBundleShortVersionString"] as? String { return short }
        return obj["CFBundleVersion"] as? String
    }

    /// Candidate GPTK redist roots (directory that contains `lib/external` or `external`).
    /// Used only by `wyn gptk status`. Install requires `--from`.
    /// Never searches the Wyn git tree or `whisky-wine/` (those must not be a
    /// redistribution channel).
    public static func defaultSearchRoots() -> [URL] {
        var roots: [URL] = []
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        // Official Apple GPTK.app layout (user-installed from Apple).
        roots.append(URL(fileURLWithPath: "/Applications/Game Porting Toolkit.app/Contents/Resources/wine"))

        // Downloads: extracted folders / mounted DMG names.
        let downloads = home.appending(path: "Downloads")
        if let kids = try? fm.contentsOfDirectory(
            at: downloads,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for url in kids {
                let n = url.lastPathComponent.lowercased()
                if n.contains("game_porting") || n.contains("game porting")
                    || n.contains("evaluation") || n.contains("gptk") {
                    roots.append(url)
                }
            }
        }

        // Mounted evaluation volumes.
        if let vols = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Volumes"),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for vol in vols {
                let n = vol.lastPathComponent.lowercased()
                if n.contains("evaluation") || n.contains("game porting") || n.contains("gptk") {
                    roots.append(vol)
                    roots.append(vol.appending(path: "redist"))
                }
            }
        }

        return roots
    }

    /// True when GPTK PE/unix stubs were overlaid into the Wine tree.
    public static func isWineModulesWired() -> Bool {
        FileManager.default.fileExists(
            atPath: wineLibFolder
                .appending(path: "wine")
                .appending(path: "x86_64-unix")
                .appending(path: "d3d11.so")
                .path(percentEncoded: false)
        )
    }

    /// True when MetalFX/DLSS complement (`nvngx` + `nvapi64`) is wired into the Wine tree.
    public static func isMetalFXWired() -> Bool {
        let pe = wineLibFolder
            .appending(path: "wine")
            .appending(path: "x86_64-windows")
            .appending(path: "nvngx.dll")
        let unix = wineLibFolder
            .appending(path: "wine")
            .appending(path: "x86_64-unix")
            .appending(path: "nvngx.so")
        let fm = FileManager.default
        return fm.fileExists(atPath: pe.path(percentEncoded: false))
            && fm.fileExists(atPath: unix.path(percentEncoded: false))
    }

    /// Absolute path to the Wine-tree `nvngx.dll` (GPTK MetalFX shim), if present.
    public static var nvngxDLLURL: URL {
        wineLibFolder
            .appending(path: "wine")
            .appending(path: "x86_64-windows")
            .appending(path: "nvngx.dll")
    }

    /// True when Libraries/Wine is a CrossOver-hosted game-host that can load D3DMetal.
    /// ntdll `CX_APPLEGPTK_*` alone is not enough — EricSpencer/Whisky tarballs have
    /// the symbol but are not the game-host. Steam UI uses this gate.
    public static func isWineGPTKAware() -> Bool {
        let report = GameHostIdentity.inspect()
        return report.isCrossOverHosted && report.ntdllGPTKAware
    }

    /// ntdll-only probe (CX hooks). Does not accept Whisky as the game-host.
    public static func ntdllHasCXAppleGPTK() -> Bool {
        GameHostIdentity.ntdllHasCXAppleGPTK(in: WynWineInstaller.libraryFolder.appending(path: "Wine"))
    }

    /// Overlay GPTK PE/unix stubs only when Wine is GPTK-aware, or when forced.
    /// Community WhiskyWine has no `CX_APPLEGPTK_*` hooks — overlaying there breaks Steam.
    public static var allowExperimentalWineOverlay: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["WYN_GPTK_WIRE_WINE"] == "1" || env["FLY_GPTK_WIRE_WINE"] == "1"
    }

    public static var shouldWireWineModules: Bool {
        isWineGPTKAware() || allowExperimentalWineOverlay
    }

    /// Resolve a redist root to the folder that contains `external/libd3dshared.dylib`.
    public static func resolveLibRoot(from candidate: URL) -> URL? {
        let fm = FileManager.default
        let probes = [
            candidate.appending(path: "lib"),
            candidate,
            candidate.appending(path: "redist").appending(path: "lib")
        ]
        for root in probes {
            let external = root.appending(path: "external").appending(path: "libd3dshared.dylib")
            if fm.fileExists(atPath: external.path(percentEncoded: false)) {
                return root
            }
        }
        return nil
    }

    public static func findLocalSource() -> URL? {
        // Prefer the newest D3DMetal among discoverable redists (skip 2.1 if 3+/4 present).
        var best: (url: URL, version: String)?
        for root in defaultSearchRoots() {
            guard let lib = resolveLibRoot(from: root) else { continue }
            let fw = lib.appending(path: "external").appending(path: "D3DMetal.framework")
            let ver = versionFromFramework(at: fw) ?? "0"
            if let current = best {
                if compareVersions(ver, current.version) > 0 {
                    best = (lib, ver)
                }
            } else {
                best = (lib, ver)
            }
        }
        return best?.url
    }

    /// Crude numeric version compare (`3.0` > `2.1` > `2`).
    private static func compareVersions(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        let n = max(pa.count, pb.count)
        for i in 0..<n {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y ? 1 : -1 }
        }
        return 0
    }

    /// Copy GPTK into WynWine `lib/external/`.
    /// Overlays Wine PE/unix stubs when the Wine tree is GPTK-aware, or when
    /// `FLY_GPTK_WIRE_WINE=1` (experimental — breaks Steam on non-aware Wine).
    /// `sourceLibRoot` is required — Wyn never auto-picks Desktop/whisky-wine.
    @discardableResult
    public static func install(from sourceLibRoot: URL) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: wineLibFolder.path(percentEncoded: false)) else {
            throw GPTKError.wineTreeMissing
        }

        guard let source = resolveLibRoot(from: sourceLibRoot) else {
            throw GPTKError.sourceMissing(sourceLibRoot)
        }

        let srcExternal = source.appending(path: "external")
        let srcLibd3d = srcExternal.appending(path: "libd3dshared.dylib")
        let srcFramework = srcExternal.appending(path: "D3DMetal.framework")
        guard fm.fileExists(atPath: srcLibd3d.path(percentEncoded: false)) else {
            throw GPTKError.payloadIncomplete("missing external/libd3dshared.dylib")
        }
        guard fm.fileExists(atPath: srcFramework.path(percentEncoded: false)) else {
            throw GPTKError.payloadIncomplete("missing external/D3DMetal.framework")
        }

        // 1) external/ — preserve external → external-VER.bak symlink layout when present.
        try installExternalPayload(from: srcExternal)

        guard isInstalled() else {
            throw GPTKError.payloadIncomplete("post-install verification failed")
        }

        if shouldWireWineModules {
            try wireWineModules(from: source)
        }

        return externalFolder
    }

    /// True when `lib/external` is a symlink whose destination name looks like `external-*.bak`.
    public static func isExternalBakSymlinkLayout() -> Bool {
        bakSymlinkDestinationName() != nil
    }

    /// Destination basename of `lib/external` when it is an `external-*.bak` symlink.
    private static func bakSymlinkDestinationName() -> String? {
        let fm = FileManager.default
        let path = externalFolder.path(percentEncoded: false)
        guard let dest = try? fm.destinationOfSymbolicLink(atPath: path) else { return nil }
        let name = URL(fileURLWithPath: dest).lastPathComponent
        guard name.hasPrefix("external-"), name.hasSuffix(".bak") else { return nil }
        return name
    }

    /// Install D3DMetal into `lib/external`, keeping bak-symlink layout when already in use.
    private static func installExternalPayload(from srcExternal: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: wineLibFolder, withIntermediateDirectories: true)

        let version = versionFromFramework(
            at: srcExternal.appending(path: "D3DMetal.framework")
        ) ?? "unknown"
        let bakName = "external-\(version).bak"
        let bakURL = wineLibFolder.appending(path: bakName)

        if let existingBak = bakSymlinkDestinationName() {
            // Keep symlink layout: refresh the bak tree (or a versioned bak), then retarget.
            let targetBak = wineLibFolder.appending(path: existingBak)
            let writeURL: URL
            if existingBak == bakName {
                writeURL = targetBak
            } else {
                writeURL = bakURL
            }
            if fm.fileExists(atPath: writeURL.path(percentEncoded: false)) {
                try fm.removeItem(at: writeURL)
            }
            try fm.copyItem(at: srcExternal, to: writeURL)
            // Retarget symlink without deleting bak trees.
            if fm.fileExists(atPath: externalFolder.path(percentEncoded: false)) {
                try fm.removeItem(at: externalFolder) // removes symlink only
            }
            try fm.createSymbolicLink(
                atPath: externalFolder.path(percentEncoded: false),
                withDestinationPath: bakName
            )
            return
        }

        // Legacy: external is a real directory (or missing) — replace with bak+symlink.
        if fm.fileExists(atPath: externalFolder.path(percentEncoded: false)) {
            var isLink = false
            if let attrs = try? fm.attributesOfItem(atPath: externalFolder.path(percentEncoded: false)),
               let type = attrs[.type] as? FileAttributeType {
                isLink = type == .typeSymbolicLink
            }
            if isLink {
                try fm.removeItem(at: externalFolder)
            } else {
                // Move aside rather than destroy unknown contents.
                let aside = wineLibFolder.appending(path: "external.pre-bak-layout")
                if fm.fileExists(atPath: aside.path(percentEncoded: false)) {
                    try fm.removeItem(at: aside)
                }
                try fm.moveItem(at: externalFolder, to: aside)
            }
        }
        if fm.fileExists(atPath: bakURL.path(percentEncoded: false)) {
            try fm.removeItem(at: bakURL)
        }
        try fm.copyItem(at: srcExternal, to: bakURL)
        try fm.createSymbolicLink(
            atPath: externalFolder.path(percentEncoded: false),
            withDestinationPath: bakName
        )
    }

    /// Experimental: replace Wine D3D PE/unix modules with Apple GPTK stubs.
    /// Also wires MetalFX complement: `nvngx-on-metalfx` → `nvngx`, plus `nvapi64`.
    public static func wireWineModules(from sourceLibRoot: URL? = nil) throws {
        let fm = FileManager.default
        let source: URL
        if let sourceLibRoot, let resolved = resolveLibRoot(from: sourceLibRoot) {
            source = resolved
        } else if isInstalled() {
            // PE stubs still need the GPTK redist wine/ folder from the original source.
            guard let found = findLocalSource() else {
                throw GPTKError.payloadIncomplete("need GPTK redist with wine/ to wire modules")
            }
            source = found
        } else {
            throw GPTKError.payloadIncomplete("install GPTK external/ first")
        }

        let peNames = ["d3d11.dll", "dxgi.dll", "d3d12.dll", "d3d10.dll", "atidxx64.dll", "nvapi64.dll"]
        let peDir = wineLibFolder.appending(path: "wine").appending(path: "x86_64-windows")
        let srcPE = source.appending(path: "wine").appending(path: "x86_64-windows")
        for name in peNames {
            let src = srcPE.appending(path: name)
            guard fm.fileExists(atPath: src.path(percentEncoded: false)) else { continue }
            let dst = peDir.appending(path: name)
            try backupIfNeeded(at: dst)
            try fm.installFileIfContentDiffers(at: dst, from: src)
        }

        // GPTK ships `nvngx-on-metalfx.dll`; games/D3DMetal load `nvngx.dll`.
        let srcNvngx = srcPE.appending(path: "nvngx-on-metalfx.dll")
        if fm.fileExists(atPath: srcNvngx.path(percentEncoded: false)) {
            let dstNvngx = peDir.appending(path: "nvngx.dll")
            try backupIfNeeded(at: dstNvngx)
            try fm.installFileIfContentDiffers(at: dstNvngx, from: srcNvngx)
        }

        let unixDir = wineLibFolder.appending(path: "wine").appending(path: "x86_64-unix")
        try fm.createDirectory(at: unixDir, withIntermediateDirectories: true)
        let soNames = [
            "d3d11.so", "dxgi.so", "d3d12.so", "d3d10.so", "atidxx64.so",
            "nvapi64.so", "nvngx.so"
        ]
        let relativeTarget = "../../external/libd3dshared.dylib"
        for name in soNames {
            let link = unixDir.appending(path: name)
            try backupIfNeeded(at: link)
            if fm.fileExists(atPath: link.path(percentEncoded: false)) {
                try fm.removeItem(at: link)
            }
            try fm.createSymbolicLink(
                atPath: link.path(percentEncoded: false),
                withDestinationPath: relativeTarget
            )
        }

        let frameworkLink = unixDir.appending(path: "D3DMetal.framework")
        if fm.fileExists(atPath: frameworkLink.path(percentEncoded: false)) {
            try fm.removeItem(at: frameworkLink)
        }
        try fm.createSymbolicLink(
            atPath: frameworkLink.path(percentEncoded: false),
            withDestinationPath: "../../external/D3DMetal.framework"
        )
    }

    /// Environment additions so CrossOver-style loaders find libd3dshared + MetalFX.
    /// Avoid DYLD_FALLBACK_LIBRARY_PATH — pointing it only at external/ breaks Wine's
    /// own lib lookup and can kill Steam before the game starts.
    public static func launchEnvironment() -> [String: String] {
        let libd3d = libd3dsharedURL.path(percentEncoded: false)
        // MetalFX on/off is profile-owned (`D3DM_ENABLE_METALFX`) — do not force "1"
        // here or combo/profile A/Bs cannot disable it.
        let wineRoot = WynWineInstaller.libraryFolder.appending(path: "Wine")
        var env: [String: String] = [
            "CX_APPLEGPTK_LIBD3DSHARED_PATH": libd3d,
            "CX_APPLEGPT_LIBD3DSHARED_PATH": libd3d,
            // cxcompatdb has no JSON DB on Wyn. Without CX_GRAPHICS_BACKEND, `set_graphics_backend`
            // HACKs DX11 exes onto DXMT (`HACK: trying graphics backend dxmt`) and "builtin"
            // d3d11 becomes DXMT. CrossOver drives this env; AppDefaults `d3d*=b` are not enough.
            "CX_ROOT": wineRoot.path(percentEncoded: false),
            "CX_GRAPHICS_BACKEND": "d3dmetal"
        ]
        if isMetalFXWired() {
            env["D3DM_NVNGX_PATH"] = nvngxDLLURL.path(percentEncoded: false)
        }
        return env
    }

    // MARK: - Private

    private static func backupIfNeeded(at url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path(percentEncoded: false)) else { return }
        // Don't backup our own symlinks / already-backed files.
        let backup = url.appendingPathExtension("fly-pre-gptk")
        if fm.fileExists(atPath: backup.path(percentEncoded: false)) { return }
        var isLink: Bool = false
        if let attrs = try? fm.attributesOfItem(atPath: url.path(percentEncoded: false)),
           let type = attrs[.type] as? FileAttributeType {
            isLink = type == .typeSymbolicLink
        }
        if isLink { return }
        try fm.copyItem(at: url, to: backup)
    }
}
