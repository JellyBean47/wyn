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
        case notFoundInDownloads
        case d3dMetalTooOld(String)
        case diskImageFailed(String)

        public var errorDescription: String? {
            switch self {
            case .sourceMissing(let url):
                return "GPTK source not found at \(url.path(percentEncoded: false))"
            case .payloadIncomplete(let detail):
                return "GPTK payload incomplete: \(detail)"
            case .wineTreeMissing:
                return "WynWine is not installed. Run: wyn install"
            case .requiresExplicitSource, .notFoundInDownloads:
                return """
                GPTK/D3DMetal is not bundled. Download Game Porting Toolkit 3.0 from Apple, \
                then either drop it in ~/Downloads (Game_Porting_Toolkit_3.0.dmg) and run:
                  wyn gptk install
                Or point Wyn straight at it, wherever it landed:
                  wyn gptk install --pick        # browse for it in Finder
                  wyn gptk install --from /path  # if you already know the path
                \(GPTKInstaller.appleDownloadURL)
                Wyn never downloads GPTK.
                """
            case .d3dMetalTooOld(let version):
                return """
                This redist is D3DMetal \(version). Wyn needs Game Porting Toolkit 3.0 \
                (D3DMetal 3.x). Put Game_Porting_Toolkit_3.0.dmg in ~/Downloads, then:
                  wyn gptk install
                \(GPTKInstaller.appleDownloadURL)
                """
            case .diskImageFailed(let detail):
                return "Could not open GPTK disk image: \(detail)"
            }
        }
    }

    public static let appleDownloadURL =
        "https://developer.apple.com/download/all/?q=game%20porting%20toolkit"

    /// Auto-detect and install refuse D3DMetal 2.x. GPTK 3.0 is the product overlay.
    public static let minimumD3DMetalMajor = 3

    /// Canonical filename the user drops in ~/Downloads.
    public static let downloadsFileName = "Game_Porting_Toolkit_3.0.dmg"

    /// GPTK 3.0 in ~/Downloads: `Game_Porting_Toolkit_3.0.dmg` first, then other
    /// Game Porting Toolkit 3.x DMGs or extracted folders. Does not mount.
    public static func preferredDownloadsCandidate() -> URL? {
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")
        return gptkCandidate(in: downloads)
    }

    /// Best-looking GPTK candidate in an arbitrary folder, by the same rules
    /// ~/Downloads gets: exact `Game_Porting_Toolkit_3.0.dmg` first, then the
    /// highest-scoring GPTK-ish name. Does not mount, does not recurse.
    ///
    /// Shared so a folder the user browsed to is judged exactly like Downloads —
    /// where the DMG happens to sit should not change which file wins.
    public static func gptkCandidate(in folder: URL) -> URL? {
        let fm = FileManager.default
        let exact = folder.appending(path: downloadsFileName)
        if fm.fileExists(atPath: exact.path(percentEncoded: false)) {
            return exact
        }

        guard let kids = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        func looksLikeGPTK(_ url: URL) -> Bool {
            let n = url.lastPathComponent.lowercased()
            return n.contains("game_porting") || n.contains("game porting")
                || n.contains("gptk")
        }

        func score(_ url: URL) -> Int {
            let n = url.lastPathComponent.lowercased()
            let isDmg = n.hasSuffix(".dmg")
            if n.contains("3.0") && isDmg { return 400 }
            if n.contains("3.0") { return 350 }
            if n.contains("3") && isDmg { return 300 }
            if n.contains("3") { return 250 }
            if isDmg { return 150 }
            return 100
        }

        return kids.filter(looksLikeGPTK).max { score($0) < score($1) }
    }

    /// Auto-detect order: the folder the last install actually used, then
    /// ~/Downloads, then mounted volumes / GPTK.app.
    ///
    /// The remembered folder leads because a user who keeps GPTK in Documents or
    /// on an external drive told us so by browsing there once; re-searching
    /// Downloads first would ignore that every time.
    public static func preferredLocalSource() -> URL? {
        if let remembered = GPTKSourcePicker.rememberedCandidate() { return remembered }
        if let downloads = preferredDownloadsCandidate() { return downloads }
        return findLocalSource()
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

    /// Candidate GPTK redist roots (directory, DMG, or mounted volume).
    /// `wyn gptk install` with no `--from` uses `preferredLocalSource()` (Downloads 3.0 first).
    /// Never searches the Wyn git tree or `whisky-wine/` (those must not be a
    /// redistribution channel).
    public static func defaultSearchRoots() -> [URL] {
        var roots: [URL] = []
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        // Official Apple GPTK.app layout (user-installed from Apple).
        roots.append(URL(fileURLWithPath: "/Applications/Game Porting Toolkit.app/Contents/Resources/wine"))

        // Downloads: 3.0 DMG first, then extracted folders / other GPTK names.
        if let preferred = preferredDownloadsCandidate() {
            roots.append(preferred)
        }
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

    /// True when unix D3D modules are selected as D3DMetal (`d3d*.so` → `libd3dshared`).
    /// Distinct from `isInstalled()` (files present, not necessarily selected).
    public static func isWineModulesWired() -> Bool {
        GameHostIdentity.unixD3DMetalWired(
            in: WynWineInstaller.libraryFolder.appending(path: "Wine")
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

    /// True when Libraries/Wine is FOSS winecx with the ntdll GPTK hook.
    /// Proprietary Wine.app / wineloader and Whisky 11 without the hook are refused.
    /// Steam UI uses this gate; D3DMetal play also needs `isWineModulesWired()`.
    public static func isWineGPTKAware() -> Bool {
        GameHostIdentity.inspect().isFOSSGPTKHost
    }

    /// ntdll-only probe (winecx CX_APPLEGPTK hook). Does not accept Whisky as the game-host.
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
    /// Directories only — DMGs are opened by `resolveAndMount`.
    public static func resolveLibRoot(from candidate: URL) -> URL? {
        let fm = FileManager.default
        let probes = [
            candidate.appending(path: "lib"),
            candidate,
            candidate.appending(path: "redist").appending(path: "lib"),
            candidate.appending(path: "redist")
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
        if let downloads = preferredDownloadsCandidate() { return downloads }
        // Prefer the newest D3DMetal among already-extracted / mounted redists.
        var best: (url: URL, version: String)?
        for root in defaultSearchRoots() {
            guard let lib = resolveLibRoot(from: root) else { continue }
            let fw = lib.appending(path: "external").appending(path: "D3DMetal.framework")
            let ver = versionFromFramework(at: fw) ?? "0"
            if majorVersion(ver) < minimumD3DMetalMajor { continue }
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

    private static func majorVersion(_ version: String) -> Int {
        version.split(separator: ".").compactMap { Int($0) }.first ?? 0
    }

    /// Copy GPTK into WynWine `lib/external/`. Availability only — does **not**
    /// select D3DMetal. Unix `d3d*.so` pointers are `RendererWiring.set`.
    /// Overlays Wine PE stubs + MetalFX unix helpers when the Wine tree is
    /// GPTK-aware, or when `FLY_GPTK_WIRE_WINE=1` (experimental — breaks Steam
    /// on non-aware Wine). `sourceLibRoot` may be a redist directory or an Apple
    /// DMG (including the nested Evaluation image). Wyn never downloads GPTK.
    @discardableResult
    public static func install(from sourceLibRoot: URL) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: wineLibFolder.path(percentEncoded: false)) else {
            throw GPTKError.wineTreeMissing
        }

        let session = DiskImageSession()
        defer { session.detachAll() }
        guard let source = try resolveAndMount(sourceLibRoot, session: session) else {
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

        let version = versionFromFramework(at: srcFramework) ?? "unknown"
        if majorVersion(version) < minimumD3DMetalMajor {
            throw GPTKError.d3dMetalTooOld(version)
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

    /// Open a directory or Apple DMG (and nested Evaluation DMG) to a lib root.
    private static func resolveAndMount(_ candidate: URL, session: DiskImageSession) throws -> URL? {
        let fm = FileManager.default
        let path = candidate.path(percentEncoded: false)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return nil }

        if !isDir.boolValue, candidate.pathExtension.lowercased() == "dmg" {
            let volume = try session.attach(candidate)
            if let lib = resolveLibRoot(from: volume) { return lib }
            for nested in diskImages(in: volume, maxDepth: 2) {
                let inner = try session.attach(nested)
                if let lib = resolveLibRoot(from: inner) { return lib }
            }
            return nil
        }

        if let lib = resolveLibRoot(from: candidate) { return lib }
        return nil
    }

    private static func diskImages(in root: URL, maxDepth: Int) -> [URL] {
        var results: [URL] = []
        func walk(_ dir: URL, depth: Int) {
            guard depth <= maxDepth else { return }
            guard let kids = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return }
            for child in kids {
                if child.pathExtension.lowercased() == "dmg" {
                    results.append(child)
                    continue
                }
                let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDirectory {
                    walk(child, depth: depth + 1)
                }
            }
        }
        walk(root, depth: 1)
        return results
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

    /// Overlay GPTK PE stubs and MetalFX unix helpers (`nvngx`, `nvapi64`, `atidxx64`).
    /// Does **not** repoint `d3d11.so` / `d3d10.so` / `dxgi.so` / `d3d12.so` —
    /// that is renderer selection (`RendererWiring.set`), not GPTK availability.
    public static func wireWineModules(from sourceLibRoot: URL? = nil) throws {
        let fm = FileManager.default
        let session = DiskImageSession()
        defer { session.detachAll() }
        let source: URL
        if let sourceLibRoot, let resolved = try resolveAndMount(sourceLibRoot, session: session) {
            source = resolved
        } else if isInstalled() {
            guard let found = preferredLocalSource() else {
                throw GPTKError.payloadIncomplete("need GPTK 3.0 redist with wine/ to wire modules")
            }
            guard let resolved = try resolveAndMount(found, session: session) else {
                throw GPTKError.sourceMissing(found)
            }
            source = resolved
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
            "atidxx64.so", "nvapi64.so", "nvngx.so"
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

    /// Environment so winecx's GPTK ntdll hook finds libd3dshared + MetalFX.
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
            // winecx has no JSON compat DB here. Without CX_GRAPHICS_BACKEND,
            // set_graphics_backend HACKs DX11 exes onto DXMT (`HACK: trying graphics
            // backend dxmt`) and "builtin" d3d11 becomes DXMT. AppDefaults `d3d*=b`
            // are not enough; this env is the winecx hook.
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

    /// Mount Apple GPTK DMGs (and nested Evaluation images) for the install copy, then detach.
    fileprivate final class DiskImageSession {
        private var mountPoints: [URL] = []

        func attach(_ dmg: URL) throws -> URL {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            proc.arguments = [
                "attach", "-nobrowse", "-readonly", "-plist",
                dmg.path(percentEncoded: false)
            ]
            let out = Pipe()
            let err = Pipe()
            proc.standardOutput = out
            proc.standardError = err
            try proc.run()
            proc.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            if proc.terminationStatus != 0 {
                let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw GPTKError.diskImageFailed(
                    "hdiutil attach failed for \(dmg.lastPathComponent)\(msg.isEmpty ? "" : ": \(msg)")"
                )
            }
            guard let mount = Self.mountPoint(fromPlist: data) else {
                throw GPTKError.diskImageFailed(
                    "no mount-point in hdiutil output for \(dmg.lastPathComponent)"
                )
            }
            mountPoints.append(mount)
            return mount
        }

        func detachAll() {
            for mount in mountPoints.reversed() {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                proc.arguments = ["detach", mount.path(percentEncoded: false), "-quiet"]
                proc.standardOutput = Pipe()
                proc.standardError = Pipe()
                try? proc.run()
                proc.waitUntilExit()
            }
            mountPoints.removeAll()
        }

        private static func mountPoint(fromPlist data: Data) -> URL? {
            guard let obj = try? PropertyListSerialization.propertyList(from: data, format: nil)
                    as? [String: Any],
                  let entities = obj["system-entities"] as? [[String: Any]]
            else { return nil }
            var found: URL?
            for entity in entities {
                if let path = entity["mount-point"] as? String,
                   FileManager.default.fileExists(atPath: path) {
                    found = URL(fileURLWithPath: path)
                }
            }
            return found
        }
    }
}
