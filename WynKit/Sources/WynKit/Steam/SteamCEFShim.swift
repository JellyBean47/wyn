//
//  SteamCEFShim.swift
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
//  line is `launchedUIVariant` below: a helper launch in logs/webhelper.txt
//  stamped after the newest updater session in bootstrap_log.txt began. Until
//  then Steam is still installing itself, however long its download takes.

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
    /// Every place the shim is looked for, in order. Exposed so the ordering can
    /// be tested without a shim on disk.
    static var shimSearchPaths: [URL] {
        var candidates: [URL] = []

        if let bundled = Bundle.main.url(forResource: "steamwebhelper_shim", withExtension: "exe") {
            candidates.append(bundled)
        }

        // The installed app carries it. This is the one that matters for the
        // CLI, whose Bundle.main is ~/.local/bin and holds no Resources — see
        // InstalledApp. Without this candidate every fresh bottle created from
        // the command line gets a black Steam login window.
        candidates.append(
            InstalledApp.resourcesDirectory.appending(path: "steamwebhelper_shim.exe")
        )

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

        return candidates
    }

    public static var bundledShimURL: URL? {
        shimSearchPaths.first {
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
        /// The line's own stamp, "2026-09-27 22:54:46". `bootstrap_log.txt`
        /// uses the same local-time format, so the two logs order as strings.
        public let loggedAt: String?

        public init(variant: String, executable: String, shimmed: Bool, loggedAt: String? = nil) {
            self.variant = variant
            self.executable = executable
            self.shimmed = shimmed
            self.loggedAt = loggedAt
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
                shimmed: lower.contains("--in-process-gpu"),
                loggedAt: logTimestamp(line)
            )
        }
        return nil
    }

    /// `[2026-09-27 22:54:46] Startup - …` → `2026-09-27 22:54:46`.
    ///
    /// Only the exact `yyyy-MM-dd HH:mm:ss` shape is accepted, because the
    /// callers compare stamps as strings and that is only meaningful for it.
    static func logTimestamp<S: StringProtocol>(_ line: S) -> String? {
        guard line.first == "[", let close = line.firstIndex(of: "]") else { return nil }
        let stamp = line[line.index(after: line.startIndex)..<close]
        guard stamp.count == 19 else { return nil }
        return String(stamp)
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

    private static func fileSize(of url: URL) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return (attrs?[.size] as? NSNumber)?.intValue ?? 0
    }

    // MARK: - Has Steam finished installing itself?

    /// Steam's updater, as the newest session in `bootstrap_log.txt` has it.
    ///
    /// Every start of `steam.exe` opens a session with `Startup - updater
    /// built …`. When the updater has installed something it relaunches Steam
    /// (`Update complete, launching Steam...`, then `Shutdown`): a new process
    /// and a new session, sometimes within the same second. A first run does
    /// that twice, for the 32-bit client and then the 64-bit one. Only the
    /// newest session is what is running now.
    public struct UpdaterSession: Equatable, Sendable {
        public enum Phase: Equatable, Sendable {
            /// Verifying, checking for updates, or handed over to the client.
            case starting
            /// `Downloading update (x of y KB)...`. The bare `Downloading
            /// update...` form carries no figures.
            case downloading(doneKB: Int?, totalKB: Int?)
            case installing
            /// This process is about to be replaced by the one it installed.
            case relaunching
            /// `Exhausted list of download hosts` / `Failed to determine
            /// download location`. On a first run Steam then shows "Failed to
            /// load steamui.dll" and waits for someone to close it.
            case downloadFailed
        }

        /// The session's first stamp, "2026-09-27 22:54:36".
        public let startedAt: String
        public let phase: Phase

        public init(startedAt: String, phase: Phase) {
            self.startedAt = startedAt
            self.phase = phase
        }
    }

    static func lastUpdaterSession(inLog text: String) -> UpdaterSession? {
        var startedAt: String?
        var phase = UpdaterSession.Phase.starting
        // Newline-ness, never a literal: Steam writes CRLF (see lastWebHelperLaunch).
        for line in text.split(whereSeparator: \.isNewline) {
            if line.contains("Startup - updater built") {
                guard let stamp = logTimestamp(line) else { continue }
                startedAt = stamp
                phase = .starting
            } else if startedAt == nil {
                continue
            } else if line.contains("Downloading update") {
                let figures = downloadFigures(line)
                phase = .downloading(doneKB: figures?.done, totalKB: figures?.total)
            } else if line.contains("Installing update") || line.contains("Extracting package") {
                phase = .installing
            } else if line.contains("Update complete, launching Steam") {
                phase = .relaunching
            } else if line.contains("Exhausted list of download hosts")
                        || line.contains("Failed to determine download location") {
                phase = .downloadFailed
            }
        }
        guard let startedAt else { return nil }
        return UpdaterSession(startedAt: startedAt, phase: phase)
    }

    public static func lastUpdaterSession(in bottle: Bottle) -> UpdaterSession? {
        guard let data = try? Data(contentsOf: bootstrapLogURL(in: bottle)) else { return nil }
        return lastUpdaterSession(inLog: String(decoding: data, as: UTF8.self))
    }

    /// `Downloading update (85,858 of 241,937 KB)...` → (85858, 241937). The
    /// separators are whatever the prefix's locale prints, so only the digits
    /// are kept.
    static func downloadFigures<S: StringProtocol>(_ line: S) -> (done: Int, total: Int)? {
        guard let open = line.firstIndex(of: "("),
              let close = line[open...].firstIndex(of: ")")
        else { return nil }
        let halves = String(line[line.index(after: open)..<close]).components(separatedBy: " of ")
        guard halves.count == 2 else { return nil }
        func number(_ text: String) -> Int? {
            Int(String(text.filter { $0.isASCII && $0.isNumber }))
        }
        guard let done = number(halves[0]), let total = number(halves[1]) else { return nil }
        return (done, total)
    }

    /// The variant Steam's current install launched its UI from, or nil if it
    /// has not yet.
    ///
    /// The client starts `steamwebhelper` only once the updater has handed
    /// over, so a launch stamped at or after the newest updater session began
    /// is first-hand evidence that the install finished: both downloads, the
    /// 32→64-bit hop, every `cef.win*` extract. It also names the variant Steam
    /// loads, which is the one the shim has to go into.
    ///
    /// "Some variant has a helper" is not this, and the difference has been the
    /// black window twice. 2 Sep 2026: `cef.win7x64` landed 47 s before
    /// `cef.win64` existed, and the shim went into the wrong one. 27 Sep 2026:
    /// a first run that stops between its two downloads leaves exactly that
    /// layout on disk.
    static func launchedUIVariant(
        webHelper: WebHelperLaunch?,
        session: UpdaterSession?,
        helperVariants: Set<String>
    ) -> String? {
        guard let webHelper, helperVariants.contains(webHelper.variant) else { return nil }
        if let session {
            // Stamped before this session began: that was the install before it.
            guard let at = webHelper.loggedAt, at >= session.startedAt else { return nil }
        }
        return webHelper.variant
    }

    /// Has Steam launched its UI since it last updated itself? False on a
    /// fresh bottle, and after a first run that stopped before it finished.
    public static func hasLaunchedUISinceLastUpdate(in bottle: Bottle) -> Bool {
        launchedUIVariant(
            webHelper: lastWebHelperLaunch(in: bottle),
            session: lastUpdaterSession(in: bottle),
            helperVariants: helperBearingVariants(in: bottle)
        ) != nil
    }

    /// What moves while Steam installs itself. Any change counts as progress.
    struct FirstRunMarks: Equatable {
        var bootstrapLogBytes: Int
        var webHelperLogBytes: Int
        var helperVariants: Set<String>
    }

    static func firstRunMarks(in bottle: Bottle) -> FirstRunMarks {
        FirstRunMarks(
            bootstrapLogBytes: fileSize(of: bootstrapLogURL(in: bottle)),
            webHelperLogBytes: fileSize(of: webHelperLogURL(in: bottle)),
            helperVariants: helperBearingVariants(in: bottle)
        )
    }

    /// Everything the first-run wait decides on, so it can be decided without
    /// touching disk.
    struct FirstRunInputs: Equatable {
        var clientRunning: Bool
        /// Seconds since `steam.exe` was last seen, or since Wyn started it.
        var clientGoneFor: TimeInterval
        var session: UpdaterSession?
        var webHelper: WebHelperLaunch?
        var helperVariants: Set<String>
        /// Seconds since anything in `FirstRunMarks` last changed.
        var quietFor: TimeInterval
        /// How long `steam.exe` may be missing and still be a relaunch in
        /// progress, or a start that has not reached the process table yet.
        var relaunchGrace: TimeInterval = 20
        /// How long a running Steam may go without writing anything.
        var stallAfter: TimeInterval = 600
    }

    enum FirstRunState: Equatable {
        /// The install is finished: its client launched the UI from `variant`.
        case uiLaunched(variant: String)
        /// Still installing. The string is for the person watching.
        case keepWaiting(String)
        /// `steam.exe` quit before its UI came up: a failed download someone
        /// closed, or a crash. Starting it again resumes the download.
        case exitedEarly
        /// Steam is running and has written nothing for `stallAfter`.
        case stalled(String)
    }

    /// Has Steam's first run finished, and if not, what is it doing?
    ///
    /// Deliberately no deadline. A first run is two downloads of ~236 MB, and
    /// on a slow line they take as long as they take: 12 and 5 minutes on 27
    /// Sep 2026, with Steam logging progress every one to two seconds
    /// throughout. So progress is the measure. The longest silence that night
    /// was 50 s, and that was Steam's own error dialog, not a download.
    ///
    /// The fixed waits this replaces are what broke that night. 180 s for a
    /// helper to appear gave up with the 32-bit client 77 MB into its download.
    /// 240 s for the layout to settle ran out part-way through the 64-bit one,
    /// and the three `-shutdown`s that followed (22:53:31, 22:53:49, 22:54:15)
    /// went to an updater, which ignores them. At 22:54:34 it finished,
    /// relaunched Steam `-silent` on Valve's helper, and the sign-in window
    /// was black.
    static func firstRunState(_ input: FirstRunInputs) -> FirstRunState {
        if let variant = launchedUIVariant(
            webHelper: input.webHelper,
            session: input.session,
            helperVariants: input.helperVariants
        ) {
            return .uiLaunched(variant: variant)
        }
        let status = firstRunStatus(input.session)
        guard input.clientRunning else {
            return input.clientGoneFor < input.relaunchGrace ? .keepWaiting(status) : .exitedEarly
        }
        if input.quietFor >= input.stallAfter {
            return .stalled(status)
        }
        return .keepWaiting(status)
    }

    /// One line for the person watching, from what the updater last logged.
    static func firstRunStatus(_ session: UpdaterSession?) -> String {
        switch session?.phase {
        case .downloading(let done?, let total?) where total > 0:
            return "Downloading Steam: \(done / 1024) of \(total / 1024) MB…"
        case .downloading:
            return "Downloading Steam…"
        case .installing:
            return "Installing Steam…"
        case .relaunching:
            return "Steam is restarting to finish installing…"
        case .downloadFailed:
            return "Steam's download failed. If Steam shows an error, close it: Wyn starts Steam again and the download resumes."
        case .starting, nil:
            return "Starting Steam…"
        }
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
