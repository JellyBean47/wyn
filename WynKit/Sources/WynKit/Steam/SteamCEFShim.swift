//
//  SteamCEFShim.swift
//  WynKit
//
//  Deploys a steamwebhelper.exe wrapper that injects
//  `--disable-gpu --in-process-gpu` so Steam's CEF UI works under
//  Wine/GPTK on Apple Silicon. Avoid `--single-process` — it often
//  deadlocks (RtlWaitForCriticalSection / "steamwebhelper is not responding").
//  Override via host FLY_CEF_FLAGS / AETHER_CEF_FLAGS (forwarded into Wine).
//  Pattern from notpop/steam-on-m1-wine, wisnuub/Steam-Win-Silicon.
//
//  Steam picks cef.win64 / cef.win7x64 / cef.win7 from the bottle's Windows
//  version. Shim every cef.win* directory that has a helper, not only win64 —
//  otherwise a win7 bottle silently bypasses the shim.

import Foundation

public enum SteamCEFShimError: LocalizedError {
    case shimBinaryMissing

    public var errorDescription: String? {
        switch self {
        case .shimBinaryMissing:
            // Name the bundle we are actually running from. The usual cause of
            // this error is not a bad build at all — it is running a *different*
            // Wyn.app: a bare `xcodebuild` (without scripts/build.sh's
            // -derivedDataPath) leaves an unfinished bundle in Xcode's default
            // DerivedData, Spotlight indexes it under the same name, and
            // launching that one produces exactly this message. Without the
            // path there is nothing to tell the two apart.
            let bundlePath = Bundle.main.bundleURL.path(percentEncoded: false)
            let installed = "/Applications/Wyn.app"
            var hint = ""
            if bundlePath.contains("/DerivedData/") {
                hint = """

                    This is a build-products bundle, not an installed one:
                      \(bundlePath)
                    Quit it and open \(installed) instead. Only scripts/build.sh
                    copies the helpers in, so a bundle built by a bare xcodebuild
                    never has them.
                    """
            } else if bundlePath != installed {
                hint = """

                    Running from: \(bundlePath)
                    """
            }
            return """
            steamwebhelper_shim.exe is missing (Tools/bin/). \
            Wyn.app carries this helper in its bundle, so a missing one usually \
            means the app was built before the helper was. Rebuild and reinstall:
              ./scripts/build.sh
            Building the helper on its own: ./scripts/build-helpers.sh \
            (needs x86_64-w64-mingw32-gcc, e.g. brew install mingw-w64)
            Without it Steam's login window paints black.\(hint)
            """
        }
    }
}

public enum SteamCEFShim {
    private static let maxShimBytes = 500_000

    /// Bundled / repo-built shim PE (x86_64 Windows).
    ///
    /// The app bundle comes first. Wyn.app is installed to /Applications and
    /// must not depend on a source checkout still existing at the path it was
    /// compiled from — `#filePath` is baked in at compile time, so for an
    /// installed app it points at someone else's Desktop, and even on the build
    /// machine reading it needs TCC consent the app never asks for. Missing the
    /// shim is not cosmetic: without it Steam's login window paints black.
    ///
    /// The source-relative and cwd paths stay as developer conveniences for
    /// `swift run` out of a checkout.
    public static var bundledShimURL: URL? {
        var candidates: [URL] = []

        if let bundled = Bundle.main.url(forResource: "steamwebhelper_shim", withExtension: "exe") {
            candidates.append(bundled)
        }

        // #filePath = .../WynKit/Sources/WynKit/Steam/SteamCEFShim.swift
        candidates.append(
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // Steam
                .deletingLastPathComponent() // WynKit
                .deletingLastPathComponent() // Sources
                .deletingLastPathComponent() // WynKit pkg
                .appending(path: "Tools/bin/steamwebhelper_shim.exe")
        )

        candidates.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appending(path: "Tools/bin/steamwebhelper_shim.exe")
        )

        return candidates.first {
            FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
        }
    }

    public static func steamRoot(in bottle: Bottle) -> URL {
        bottle.url
            .appending(path: "drive_c")
            .appending(path: "Program Files (x86)")
            .appending(path: "Steam")
    }

    public static func cefRoot(in bottle: Bottle) -> URL {
        steamRoot(in: bottle)
            .appending(path: "bin")
            .appending(path: "cef")
    }

    /// Steam's CEF variants (`cef.win64`, `cef.win7x64`, `cef.win7`, …).
    public static func cefVariantDirectories(in bottle: Bottle) -> [URL] {
        let fm = FileManager.default
        let root = cefRoot(in: bottle)
        guard fm.fileExists(atPath: root.path(percentEncoded: false)),
              let items = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              )
        else { return [] }

        return items.filter { url in
            let name = url.lastPathComponent.lowercased()
            guard name.hasPrefix("cef.win") else { return false }
            return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Steam root plus every CEF variant dir that currently exists.
    public static func steamAndCEFDirectories(in bottle: Bottle) -> [URL] {
        [steamRoot(in: bottle)] + cefVariantDirectories(in: bottle)
    }

    /// True when any CEF variant has Valve's helper or our renamed `_real` copy.
    public static func hasAnyHelper(in bottle: Bottle) -> Bool {
        cefVariantDirectories(in: bottle).contains { helperPresent(in: $0) }
    }

    /// True when at least one CEF variant is our small shim (Steam is using a
    /// shimmed helper, even if other `cef.win*` dirs are still Valve PEs).
    public static func anyVariantShimmed(in bottle: Bottle) -> Bool {
        cefVariantDirectories(in: bottle).contains { isShimmed(in: $0) }
    }

    /// True when every CEF variant that has a helper is our small shim.
    public static func isInstalled(in bottle: Bottle) -> Bool {
        let dirs = cefVariantDirectories(in: bottle)
        var any = false
        for dir in dirs where helperPresent(in: dir) {
            any = true
            if !isShimmed(in: dir) { return false }
        }
        return any
    }

    /// Poll until Steam unpacks steamwebhelper into any `cef.win*` dir.
    public static func waitUntilHelperExists(
        in bottle: Bottle,
        seconds: TimeInterval,
        debug: Bool = false
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        var lastLog = Date.distantPast
        while Date() < deadline {
            try Task.checkCancellation()
            if hasAnyHelper(in: bottle) {
                if debug {
                    let names = cefVariantDirectories(in: bottle).map(\.lastPathComponent)
                    print("[wyn:debug] CEF shim: helper appeared in \(names.joined(separator: ", "))")
                }
                return true
            }
            if Date().timeIntervalSince(lastLog) >= 15 {
                print("Waiting for Steam to unpack the login UI…")
                lastLog = Date()
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }

    /// Ensure every `cef.win*` dir has shim as steamwebhelper.exe and Valve as `_real`.
    /// Always re-applies the shim if Steam restored the Valve PE.
    /// Returns false when CEF is not on disk yet (first self-update).
    @discardableResult
    public static func install(into bottle: Bottle, debug: Bool = false) throws -> Bool {
        let dirs = cefVariantDirectories(in: bottle)
        let pending = dirs.filter { helperPresent(in: $0) }
        guard !pending.isEmpty else {
            if debug { print("[wyn:debug] CEF shim: no cef.win* helper yet — skip") }
            return false
        }

        if pending.allSatisfy({ isShimmed(in: $0) }), bundledShimURL == nil {
            if debug {
                print("[wyn:debug] CEF shim: on-disk shims present; Tools/bin PE missing — skip refresh")
            }
            return true
        }

        guard let shim = bundledShimURL else {
            throw SteamCEFShimError.shimBinaryMissing
        }

        var installed = 0
        for dir in pending {
            if try install(intoDirectory: dir, shim: shim, debug: debug) {
                installed += 1
            }
        }
        if debug {
            print("[wyn:debug] CEF shim: \(installed)/\(pending.count) cef.win* dir(s) → --disable-gpu --in-process-gpu")
        }
        return installed > 0
    }

    /// Keep shimming until every CEF variant on disk is shimmed *and* no new one
    /// has appeared for `settle` seconds.
    ///
    /// Steam unpacks its variants at different times. On a first run cef.win7x64
    /// can land first, a single install() pass shims it and reports success, and
    /// cef.win64 — the variant a Windows 10 bottle actually loads — is unpacked
    /// seconds later and never shimmed. The visible result is the black login
    /// window on an otherwise perfect install, which is indistinguishable from
    /// the shim being broken. Observed on a clean install: cef.win7x64 shimmed
    /// at install time, cef.win64 still carrying Valve's 7.4 MB helper.
    ///
    /// install() is idempotent and only touches dirs that need it, so polling it
    /// costs nothing and closes the race whichever order Steam unpacks in.
    @discardableResult
    public static func installUntilVariantsSettle(
        into bottle: Bottle,
        seconds: TimeInterval = 45,
        settle: TimeInterval = 6,
        debug: Bool = false
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        var knownCount = cefVariantDirectories(in: bottle).count
        // Backdated so an already-settled bottle returns on the first pass. The
        // settle window is meant to wait *after* a variant appears, not to add
        // six seconds to every launch that had nothing to do.
        var lastChange = Date().addingTimeInterval(-settle)
        var everInstalled = false

        while Date() < deadline {
            try Task.checkCancellation()
            if try install(into: bottle, debug: debug) { everInstalled = true }

            let count = cefVariantDirectories(in: bottle).count
            if count != knownCount {
                if debug {
                    print("[wyn:debug] CEF shim: variant count \(knownCount) → \(count); re-shimming")
                }
                knownCount = count
                lastChange = Date()
            }
            if isInstalled(in: bottle), Date().timeIntervalSince(lastChange) >= settle {
                return true
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return everInstalled || isInstalled(in: bottle)
    }

    /// Restore Valve's steamwebhelper in every variant when using frankea Steam Wine.
    @discardableResult
    public static func uninstall(from bottle: Bottle, debug: Bool = false) throws -> Bool {
        let dirs = cefVariantDirectories(in: bottle)
        guard !dirs.isEmpty else {
            if debug { print("[wyn:debug] CEF shim: no cef.win* dirs — nothing to restore") }
            return false
        }
        var restored = 0
        for dir in dirs {
            if try uninstall(fromDirectory: dir, debug: debug) {
                restored += 1
            }
        }
        return restored > 0
    }

    // MARK: - Per-directory

    private static func helperPresent(in dir: URL) -> Bool {
        let fm = FileManager.default
        let helper = dir.appending(path: "steamwebhelper.exe")
        let real = dir.appending(path: "steamwebhelper_real.exe")
        if fm.fileExists(atPath: real.path(percentEncoded: false)) {
            return true
        }
        guard fm.fileExists(atPath: helper.path(percentEncoded: false)),
              let attrs = try? fm.attributesOfItem(atPath: helper.path(percentEncoded: false)),
              let size = attrs[.size] as? NSNumber
        else { return false }
        return size.intValue >= maxShimBytes
    }

    private static func isShimmed(in dir: URL) -> Bool {
        let fm = FileManager.default
        let helper = dir.appending(path: "steamwebhelper.exe")
        let real = dir.appending(path: "steamwebhelper_real.exe")
        guard fm.fileExists(atPath: real.path(percentEncoded: false)),
              fm.fileExists(atPath: helper.path(percentEncoded: false)),
              let attrs = try? fm.attributesOfItem(atPath: helper.path(percentEncoded: false)),
              let size = attrs[.size] as? NSNumber
        else { return false }
        return size.intValue < maxShimBytes
    }

    @discardableResult
    private static func install(intoDirectory dir: URL, shim: URL, debug: Bool) throws -> Bool {
        let fm = FileManager.default
        let helper = dir.appending(path: "steamwebhelper.exe")
        let real = dir.appending(path: "steamwebhelper_real.exe")
        let marker = dir.appending(path: ".fly-cef-shim")

        let helperExists = fm.fileExists(atPath: helper.path(percentEncoded: false))
        let realExists = fm.fileExists(atPath: real.path(percentEncoded: false))
        guard helperExists || realExists else { return false }

        if isShimmed(in: dir),
           let shimData = try? Data(contentsOf: shim),
           let helperData = try? Data(contentsOf: helper),
           shimData == helperData {
            if debug {
                print("[wyn:debug] CEF shim: \(dir.lastPathComponent) already installed")
            }
            return true
        }

        if !realExists {
            let attrs = try fm.attributesOfItem(atPath: helper.path(percentEncoded: false))
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            if size < maxShimBytes {
                if debug {
                    print("[wyn:debug] CEF shim: \(dir.lastPathComponent) helper looks like a shim but no _real — abort")
                }
                return false
            }
            try fm.moveItem(at: helper, to: real)
        }

        if fm.fileExists(atPath: helper.path(percentEncoded: false)) {
            try fm.removeItem(at: helper)
        }
        try fm.copyItem(at: shim, to: helper)
        try "fly-cef-shim=disable-gpu,in-process-gpu\n".write(to: marker, atomically: true, encoding: .utf8)

        if debug {
            let sz = (try? fm.attributesOfItem(atPath: helper.path(percentEncoded: false))[.size] as? NSNumber)?.intValue ?? 0
            print("[wyn:debug] CEF shim: \(dir.lastPathComponent)/steamwebhelper (\(sz) bytes)")
        }
        return true
    }

    @discardableResult
    private static func uninstall(fromDirectory dir: URL, debug: Bool) throws -> Bool {
        let fm = FileManager.default
        let helper = dir.appending(path: "steamwebhelper.exe")
        let real = dir.appending(path: "steamwebhelper_real.exe")
        let marker = dir.appending(path: ".fly-cef-shim")

        guard fm.fileExists(atPath: real.path(percentEncoded: false)) else {
            if debug {
                print("[wyn:debug] CEF shim: \(dir.lastPathComponent) no steamwebhelper_real.exe — skip")
            }
            return false
        }

        if fm.fileExists(atPath: helper.path(percentEncoded: false)) {
            try fm.removeItem(at: helper)
        }
        try fm.moveItem(at: real, to: helper)
        try? fm.removeItem(at: marker)
        if debug {
            print("[wyn:debug] CEF shim: restored Valve steamwebhelper.exe in \(dir.lastPathComponent)")
        }
        return true
    }
}
