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
//
//  "Every directory that has a helper" is the shim's *scope*, not its finish
//  line. On a fresh bottle the variants land up to a minute apart, so that rule
//  reads as done before the variant Steam will actually load exists. The finish
//  line is `readiness` below: Steam names its own variant in logs/webhelper.txt,
//  and until it has, a Steam still writing bootstrap_log.txt means more is
//  coming.

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
        // Invariant, not a caller's concern: the shim never goes on disk while a
        // Steam client is running. Steam verifies its own files on any launch
        // without `-noverifyfiles`, and a 151,908-byte steamwebhelper.exe where
        // the manifest says 7,488,152 makes it re-extract the package over the
        // shim and restart — measured ten times in a hundred seconds on a fresh
        // bottle, 3 Sep 2026 00:14, with no exit. Callers stop Steam first.
        guard !SteamLauncher.anySteamClientRunning() else {
            if debug {
                print("[wyn:debug] CEF shim: a Steam client is running — refusing to write the shim")
            }
            return false
        }
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

    // MARK: - Which variant Steam actually loads

    /// A `steamwebhelper` launch exactly as Steam recorded it in `logs/webhelper.txt`.
    ///
    /// This is the only *first-hand* evidence of which `cef.win*` variant Steam
    /// chose. Everything else — the bottle's Windows version, which directory
    /// appeared first, how many are shimmed — is a guess, and guessing is what
    /// shipped the black login window twice (#36, then again on 2 Sep 2026).
    public struct WebHelperLaunch: Equatable, Sendable {
        public let variant: String      // "cef.win64"
        public let executable: String   // "steamwebhelper.exe" | "steamwebhelper_real.exe"
        public let shimmed: Bool        // the launch carried --in-process-gpu

        public init(variant: String, executable: String, shimmed: Bool) {
            self.variant = variant
            self.executable = executable
            self.shimmed = shimmed
        }
    }

    public static func webHelperLogURL(in bottle: Bottle) -> URL {
        steamRoot(in: bottle).appending(path: "logs").appending(path: "webhelper.txt")
    }

    public static func bootstrapLogURL(in bottle: Bottle) -> URL {
        steamRoot(in: bottle).appending(path: "logs").appending(path: "bootstrap_log.txt")
    }

    /// The **last** `webhelper launched pid:` line in `webhelper.txt`.
    ///
    /// Recorded shape, from the 2 Sep 2026 black-window run:
    /// ```
    /// [23:51:25] Startup - webhelper launched pid: 600  commandline: "C:\…\bin\cef\cef.win64\steamwebhelper.exe" … --disable-gpu --no-sandbox …
    /// [23:52:23] Startup - webhelper launched pid: 1964 commandline: "C:\…\bin\cef\cef.win64\steamwebhelper_real.exe" --disable-gpu --in-process-gpu …
    /// ```
    /// `--in-process-gpu` occurs **only** when the shim ran: Steam translates its
    /// own `-cef-disable-gpu` into `--disable-gpu` but silently drops
    /// `-cef-in-process-gpu`. That flag is the shim's signature, and its absence
    /// is the black window.
    public static func lastWebHelperLaunch(inLog text: String) -> WebHelperLaunch? {
        let cefSeparator = #"\bin\cef\"#
        // Steam writes these logs CRLF, and in Swift "\r\n" is a *single*
        // Character — so `split(separator: "\n")` matches nothing and hands
        // back the whole file as one line. That silently turned "the last
        // launch" into "the first launch in the file", and `shimmed` into
        // "--in-process-gpu appears anywhere in the log", which is true
        // forever once any good launch has happened. Split on newline-ness,
        // never on a newline literal.
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            guard line.contains("webhelper launched pid") else { continue }
            let lower = line.lowercased()
            guard let cefRange = lower.range(of: cefSeparator.lowercased()) else { continue }
            // Index into `line` at the same offset; both strings share a layout
            // only for ASCII, so work on the lowercased copy and recover names
            // from it — variant and exe names are ASCII by construction.
            let tail = lower[cefRange.upperBound...]
            let parts = tail.split(separator: "\\", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let variant = String(parts[0])
            guard variant.hasPrefix("cef.win"), !variant.isEmpty else { continue }
            var exe = String(parts[1])
            if let quote = exe.firstIndex(of: "\"") { exe = String(exe[exe.startIndex..<quote]) }
            if let space = exe.firstIndex(of: " ") { exe = String(exe[exe.startIndex..<space]) }
            guard !exe.isEmpty else { continue }
            return WebHelperLaunch(
                variant: variant,
                executable: exe,
                shimmed: lower.contains("--in-process-gpu")
            )
        }
        return nil
    }

    public static func lastWebHelperLaunch(in bottle: Bottle) -> WebHelperLaunch? {
        guard let data = try? Data(contentsOf: webHelperLogURL(in: bottle)) else { return nil }
        return lastWebHelperLaunch(inLog: String(decoding: data, as: UTF8.self))
    }

    /// `cef.win*` variants that currently carry a helper (ours or Valve's).
    static func helperBearingVariants(in bottle: Bottle) -> Set<String> {
        Set(cefVariantDirectories(in: bottle).filter { helperPresent(in: $0) }.map(\.lastPathComponent))
    }

    /// `cef.win*` variants whose helper is our shim.
    static func shimmedVariants(in bottle: Bottle) -> Set<String> {
        Set(cefVariantDirectories(in: bottle).filter { isShimmed(in: $0) }.map(\.lastPathComponent))
    }

    private static func modificationDate(of url: URL) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return attrs?[.modificationDate] as? Date
    }

    // MARK: - Has Steam's CEF layout stopped moving?

    enum LayoutState: Equatable {
        /// Steam is done unpacking `cef.win*`. `variant` is the one it named.
        case settled(variant: String?)
        case keepWaiting(String)
    }

    /// Everything the decision needs, so it can be decided without touching disk.
    struct LayoutInputs: Equatable {
        var helperVariants: Set<String>
        /// From `webhelper.txt`; nil until Steam has launched a helper even once.
        var steamVariant: String?
        var now: Date
        /// When `helperVariants` last changed.
        var lastVariantChange: Date
        /// mtime of `bootstrap_log.txt` — Steam writes it continuously while it
        /// is downloading and unpacking. nil when the log does not exist yet.
        var bootstrapLogMtime: Date?
        var settle: TimeInterval
    }

    /// Has Steam finished laying out `bin/cef`?
    ///
    /// This is deliberately *not* a question about shims. Shimming a running
    /// client that verifies its files is a loop (see `waitForVariantsToSettle`),
    /// so the shim goes on after Steam is stopped, and the only thing worth
    /// waiting for while it runs is the layout itself.
    ///
    /// The old rule — "every variant that has a helper is shimmed" — was true on
    /// a fresh bottle the instant `cef.win7x64` landed, ~47 s before `cef.win64`
    /// existed at all. Recorded 2 Sep 2026: win7x64 created **and** shimmed
    /// 23:50:23; win64 created 23:51:10; Valve's unshimmed helper launched out
    /// of it 23:51:25 → black login window. Reproduced 3 Sep 2026 with the same
    /// 47-second gap, so it is the shape of a first run, not a fluke.
    ///
    /// When Steam has named its variant, that variant decides and nothing else
    /// does. Until then, having a helper on disk is not enough: a variant that
    /// appeared moments ago, or a Steam still writing `bootstrap_log.txt`, means
    /// more is coming.
    static func layoutState(_ input: LayoutInputs) -> LayoutState {
        if let steam = input.steamVariant {
            if input.helperVariants.contains(steam) {
                return .settled(variant: steam)
            }
            return .keepWaiting("Steam loads \(steam) and it is not on disk yet")
        }
        if input.helperVariants.isEmpty {
            return .keepWaiting("no cef.win* helper on disk yet")
        }
        if input.now.timeIntervalSince(input.lastVariantChange) < input.settle {
            return .keepWaiting("a variant appeared less than \(Int(input.settle))s ago")
        }
        if let mtime = input.bootstrapLogMtime,
           input.now.timeIntervalSince(mtime) < input.settle {
            return .keepWaiting("Steam is still writing bootstrap_log.txt")
        }
        return .settled(variant: nil)
    }

    /// Wait until Steam has finished laying out `bin/cef` — **without touching it**.
    ///
    /// > Never shim a running Steam client. Steam verifies its own files on any
    /// > launch that does not carry `-noverifyfiles`, and the shim is 151,908
    /// > bytes where the manifest says 7,488,152. Measured on a fresh bottle,
    /// > 3 Sep 2026 00:14:
    /// >
    /// >     BVerifyInstalledFiles: bin\cef\cef.win64\steamwebhelper.exe
    /// >       is 151908 bytes, expected 7488152
    /// >
    /// > Steam then re-extracts the package over the shim and restarts — ten
    /// > times in a hundred seconds, and it does not stop. The bootstrap
    /// > `-silent` launches are exactly the ones that verify: `-noverifyfiles`
    /// > is stripped until `SteamUI.dll` exists, or the first client download
    /// > never happens. So the shim can only be written while Steam is **down**,
    /// > and the first process to load it must be a launch carrying
    /// > `-noverifyfiles`.
    ///
    /// Which is why this function waits and reports, and `install(into:)` is
    /// called by the caller afterwards, once the client has exited.
    ///
    /// Returns the variant Steam named in `webhelper.txt`, if it named one.
    @discardableResult
    public static func waitForVariantsToSettle(
        in bottle: Bottle,
        seconds: TimeInterval = 240,
        settle: TimeInterval = 15,
        debug: Bool = false
    ) async throws -> String? {
        let deadline = Date().addingTimeInterval(seconds)
        var knownHelpers = helperBearingVariants(in: bottle)
        // Backdated so a bottle that has nothing to wait for is not charged the
        // settle window. It is armed the moment a variant actually appears.
        var lastChange = Date().addingTimeInterval(-settle)
        var lastReason = ""

        while true {
            try Task.checkCancellation()

            let helpers = helperBearingVariants(in: bottle)
            if helpers != knownHelpers {
                if debug {
                    print("[wyn:debug] CEF shim: helpers \(knownHelpers.sorted()) → \(helpers.sorted())")
                }
                knownHelpers = helpers
                lastChange = Date()
            }

            let state = layoutState(
                LayoutInputs(
                    helperVariants: helpers,
                    steamVariant: lastWebHelperLaunch(in: bottle)?.variant,
                    now: Date(),
                    lastVariantChange: lastChange,
                    bootstrapLogMtime: modificationDate(of: bootstrapLogURL(in: bottle)),
                    settle: settle
                )
            )

            switch state {
            case .settled(let variant):
                if debug {
                    let named = variant ?? "no webhelper launch recorded yet"
                    print("[wyn:debug] CEF shim: layout settled (\(named))")
                }
                return variant
            case .keepWaiting(let reason):
                if reason != lastReason {
                    if debug { print("[wyn:debug] CEF shim: waiting — \(reason)") }
                    lastReason = reason
                }
            }

            if Date() >= deadline { break }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }

        print("Steam's CEF layout did not settle in \(Int(seconds))s (\(lastReason)).")
        return lastWebHelperLaunch(in: bottle)?.variant
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
