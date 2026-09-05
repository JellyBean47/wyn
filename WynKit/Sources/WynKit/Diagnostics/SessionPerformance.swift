//
//  SessionPerformance.swift
//  WynKit
//
//  What a game session actually did, read back from the game's own log.
//
//  Until this existed, a model adding a game over MCP could see whether a
//  profile launched and nothing else. That is not enough to configure a game
//  well, and on 5 September it turned out not to be enough to configure one
//  *correctly* either: a two-hour Solarpunk session ran on DXVK while its
//  profile said d3dmetal, at 45 fps where D3DMetal gives 120. Every tool the
//  model had would have reported success.
//
//  Two things are recoverable from an Unreal log and both matter.
//
//  WHICH LAYER REALLY RAN. The layers fake different adapters, and this is the
//  only reliable way to know which one a game got — the profile does not decide
//  it, the running Wine tree does:
//
//      D3DMetal ->  "AMD Compatibility Mode"    VendorId 0x1002
//      DXVK     ->  "NVIDIA GeForce 6800"       VendorId 0x10de
//
//  HOW FAST IT WENT. Frame rate comes from UE's own `[timestamp][frame]` log
//  prefix: the frames the engine advanced between two log lines, bucketed per
//  minute. It is a sampling estimate rather than an instrumented counter, so
//  minutes with little logging are dropped instead of reported as though they
//  meant something. Over a real session it tracks closely — the DXVK and
//  D3DMetal numbers above were measured this way and the difference was not
//  subtle.
//
//  The findings this produces encode the diagnosis that took a day to reach:
//  a game running slowly *at low resolution* is not a game that needs its
//  settings lowered. It is almost always the wrong translation layer.
//

import Foundation

public enum SessionPerformance {

    // MARK: - Types

    /// The translation layer a session actually used, by the adapter it faked.
    public enum DetectedLayer: Sendable, Equatable {
        case d3dMetal
        case dxvk
        /// DXMT, and it is the odd one out: it does not fake an adapter at all.
        /// D3DMetal claims to be an AMD card and DXVK an NVIDIA one, so both
        /// are recognised by a made-up vendor id. DXMT reports the real GPU
        /// under Apple's own vendor id — `Apple M4`, `0x106b` — which is why
        /// this file called the first DXMT session ever measured here an
        /// "unrecognised adapter".
        case dxmt
        /// An adapter string nobody has taught this file to recognise. Named
        /// rather than guessed — a wrong layer attribution is worse than none.
        case unrecognised(String)

        public var displayName: String {
            switch self {
            case .d3dMetal: return "D3DMetal (Apple GPTK)"
            case .dxvk: return "DXVK (DXVK-macOS → MoltenVK → Metal)"
            case .dxmt: return "DXMT (D3D11 → Metal)"
            case .unrecognised(let adapter): return "unrecognised adapter \"\(adapter)\""
            }
        }

        public var translationLayer: TranslationLayer? {
            switch self {
            case .d3dMetal: return .d3dMetal
            case .dxvk: return .dxvk
            case .dxmt: return .dxmt
            case .unrecognised: return nil
            }
        }

        static func from(vendorId: String?, adapter: String?) -> DetectedLayer? {
            switch vendorId?.lowercased() {
            case "1002": return .d3dMetal
            case "10de": return .dxvk
            // 0x106b is Apple. DXMT passes the real GPU through rather than
            // impersonating a PC card, so this is the only one of the three
            // where the adapter string is the truth.
            case "106b": return .dxmt
            case .some: return .unrecognised(adapter ?? "vendor \(vendorId ?? "?")")
            case nil: return adapter.map { .unrecognised($0) }
            }
        }
    }

    public struct Distribution: Sendable, Equatable {
        public let minimum: Double
        public let p25: Double
        public let median: Double
        public let p75: Double
        public let maximum: Double
        public let minutes: Int

        init?(_ values: [Double]) {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            minimum = sorted[0]
            p25 = sorted[sorted.count / 4]
            median = sorted[sorted.count / 2]
            p75 = sorted[(3 * sorted.count) / 4]
            maximum = sorted[sorted.count - 1]
            minutes = sorted.count
        }

        public var summary: String {
            String(
                format: "min %.1f  p25 %.1f  median %.1f  p75 %.1f  max %.1f  (%d min)",
                minimum, p25, median, p75, maximum, minutes
            )
        }
    }

    public struct Report: Sendable {
        public let logURL: URL
        public let layer: DetectedLayer?
        public let adapter: String?
        public let sessionMinutes: Double
        public let framesCounted: Int
        public let fps: Distribution?
        public let resolution: String?
        public let screenPercentage: Int?
        public let hitches: Int
        public let vsync: Bool?
        public let frameRateLimit: Double?

        /// Seconds the game thread waited for the render thread before giving
        /// up, when the engine reported that it did.
        ///
        /// This is not a slow session, it is a stopped one, and the difference
        /// was invisible here on 5 September: Solarpunk wedged on its first
        /// frame, the game thread gave up after 120 seconds, and this file read
        /// the log and said "Nothing looks wrong". Everything it measures —
        /// frame rate, coverage, hitches — is about a session that ran. None of
        /// them can describe one that did not.
        ///
        /// Only ever set from the engine's own timeout line, so it cannot fire
        /// on a healthy session. Absence of the line is not evidence of health;
        /// it is the absence of that particular admission.
        public let renderThreadTimeoutSeconds: Double?

        /// Effective pixels actually rendered, which is what makes a frame rate
        /// mean something. 45 fps is fine at 4K and alarming at 576x324.
        public var effectiveResolution: String? {
            guard let resolution, let screenPercentage else { return nil }
            let parts = resolution.lowercased().split(separator: "x")
            guard parts.count >= 2, let width = Int(parts[0]), let height = Int(parts[1]) else {
                return nil
            }
            let scale = Double(screenPercentage) / 100
            return "\(Int(Double(width) * scale))x\(Int(Double(height) * scale))"
        }
    }

    // MARK: - Finding the log

    /// The most recently written `Saved/Logs/<project>.log` in the bottle.
    ///
    /// Searched across every Wine user because the launch path decides which
    /// one is written: the direct D3DMetal path runs as `crossover`, while a
    /// game launched through frankea Steam runs as the macOS user. Picking the
    /// wrong one silently reports a stale session.
    public static func latestLog(project: String, in bottle: Bottle) -> URL? {
        guard !project.isEmpty else { return nil }
        let fm = FileManager.default
        let usersRoot = bottle.url.appending(path: "drive_c").appending(path: "users")
        guard let users = try? fm.contentsOfDirectory(at: usersRoot, includingPropertiesForKeys: nil)
        else { return nil }

        var best: (url: URL, mtime: Date)?
        for user in users {
            let log = user
                .appending(path: "AppData").appending(path: "Local")
                .appending(path: project)
                .appending(path: "Saved").appending(path: "Logs")
                .appending(path: "\(project).log")
            guard fm.fileExists(atPath: log.path(percentEncoded: false)) else { continue }
            let mtime = (try? log.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            if best == nil || mtime > best!.mtime { best = (log, mtime) }
        }
        return best?.url
    }

    // MARK: - Reading it

    public static func read(logURL: URL) -> Report? {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return nil }
        return read(logText: text, logURL: logURL)
    }

    static func read(logText: String, logURL: URL) -> Report {
        var adapter: String?
        var vendor: String?
        var resolution: String?
        var screenPercentage: Int?
        var hitches = 0
        var threadTimeout: Double?

        var buckets: [String: (frames: Int, seconds: Double)] = [:]
        var previous: (time: Double, frame: Int)?
        var firstTime: Double?
        var lastTime: Double?
        var totalFrames = 0

        for line in logText.split(whereSeparator: \.isNewline) {
            if adapter == nil, line.contains("Description"), line.contains("RHI"),
               let value = line.components(separatedBy: "Description").last?
                   .drop(while: { $0 == " " || $0 == ":" }) {
                adapter = String(value).trimmingCharacters(in: .whitespaces)
            }
            if vendor == nil, let found = match(line, #"VendorId\s*:\s*([0-9a-fA-F]{4})"#) {
                vendor = found
            }
            if resolution == nil, let found = match(line, #"r\.setres:([0-9]+x[0-9]+)"#) {
                resolution = found
            }
            if let found = match(line, #"r\.ScreenPercentage\s*=\s*"?([0-9]+)"#) {
                screenPercentage = Int(found)
            }
            // Only an actual hitch event. Matching "LogHitch" counted the line
            // that merely *enables* hitch logging — one phantom hitch on every
            // healthy session, which is how a signal becomes noise.
            if line.lowercased().contains("hitch detected") {
                hitches += 1
            }
            // "GameThread timed out waiting for RenderThread after 120.00
            // seconds:" — the engine admitting a thread stopped answering.
            // Matched on the shape rather than on GameThread specifically, so
            // the reverse wording is caught too. Only the longest wait is kept:
            // one stall is the event, and a log that reports it twice is still
            // one wedged session.
            if line.contains("timed out waiting for"),
               let seconds = match(line, #"timed out waiting for \w+ after ([0-9.]+) seconds"#)
                   .flatMap(Double.init) {
                threadTimeout = max(threadTimeout ?? 0, seconds)
            }

            guard let stamp = framePrefix(line) else { continue }
            if firstTime == nil { firstTime = stamp.time }
            lastTime = stamp.time

            if let previous {
                let elapsed = stamp.time - previous.time
                let advanced = stamp.frame - previous.frame
                // A level load resets the counter, a menu is not frame rate,
                // and a jump implying thousands of frames a second is neither —
                // it is the engine skipping its counter forward across a load
                // or a first log line. Rejecting on the implied *rate* catches
                // all three; a bare cap on the frame delta does not.
                let plausible = elapsed > 0
                    && Double(advanced) / elapsed <= maximumPlausibleFPS
                if advanced > 0, plausible, elapsed < 5 {
                    let key = stamp.minuteKey
                    var bucket = buckets[key] ?? (0, 0)
                    bucket.frames += advanced
                    bucket.seconds += elapsed
                    buckets[key] = bucket
                    totalFrames += advanced
                }
            }
            previous = (stamp.time, stamp.frame)
        }

        let perMinute = buckets.values
            .filter { $0.seconds >= minimumBucketSeconds }
            .map { Double($0.frames) / $0.seconds }

        var span = (lastTime ?? 0) - (firstTime ?? 0)
        if span < 0 { span += 24 * 3600 }   // crossed midnight

        let settings = gameUserSettings(besideLog: logURL)

        return Report(
            logURL: logURL,
            layer: DetectedLayer.from(vendorId: vendor, adapter: adapter),
            adapter: adapter,
            sessionMinutes: span / 60,
            framesCounted: totalFrames,
            fps: Distribution(perMinute),
            resolution: resolution,
            screenPercentage: screenPercentage,
            hitches: hitches,
            vsync: settings.vsync,
            frameRateLimit: settings.limit,
            renderThreadTimeoutSeconds: threadTimeout
        )
    }

    // MARK: - Saying what it means

    /// The report a person or a model reads.
    ///
    /// The findings are the point. A frame rate on its own invites the wrong
    /// conclusion; a frame rate next to the resolution that produced it, and a
    /// sentence saying which of those two numbers is the suspicious one, does
    /// not.
    public static func rendered(_ report: Report, expecting expected: TranslationLayer? = nil) -> String {
        var lines: [String] = []

        lines.append("Log: \(report.logURL.lastPathComponent)")
        lines.append("Layer that actually ran: "
                     + (report.layer?.displayName ?? "could not tell — no adapter line in the log"))
        if let adapter = report.adapter {
            lines.append("  adapter reported: \(adapter)")
        }
        lines.append(String(format: "Session: %.1f min, %d frames counted",
                            report.sessionMinutes, report.framesCounted))
        if let stalled = report.renderThreadTimeoutSeconds {
            lines.append(String(format: "STOPPED: a thread stopped answering for %.0f s", stalled))
        }
        lines.append("Frame rate: " + (report.fps?.summary ?? "not enough log coverage to measure"))

        var rendering = "Rendering: \(report.resolution ?? "resolution not in log")"
        if let percentage = report.screenPercentage {
            rendering += " at \(percentage)% screen percentage"
        }
        if let effective = report.effectiveResolution {
            rendering += " → ~\(effective) effective"
        }
        lines.append(rendering)

        if let vsync = report.vsync {
            lines.append("VSync: \(vsync ? "on" : "off")")
        }
        if let limit = report.frameRateLimit, limit > 0 {
            lines.append(String(format: "FrameRateLimit in settings: %.0f", limit))
        }
        lines.append("Hitches logged: \(report.hitches)")

        let findings = self.findings(report, expecting: expected)
        if findings.isEmpty {
            lines.append("")
            lines.append("Nothing looks wrong.")
        } else {
            lines.append("")
            lines.append("Findings:")
            lines.append(contentsOf: findings.map { "  - \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    /// The diagnosis, in the order a person should read it.
    public static func findings(_ report: Report,
                                expecting expected: TranslationLayer? = nil) -> [String] {
        var out: [String] = []

        // 0. A session that stopped comes before a session that was slow.
        //
        // Solarpunk wedged on its first frame on 5 September and this function
        // returned nothing at all: the frame rate was unmeasurable, so no
        // finding about frame rate could fire, and "unmeasurable" was being
        // treated as "nothing to say". A checker that reports a 120-second
        // deadlock as a clean bill is worse than no checker, because it is
        // believed.
        if let stalled = report.renderThreadTimeoutSeconds {
            out.append("""
            THE SESSION STOPPED. The engine gave up after \
            \(String(format: "%.0f", stalled)) seconds waiting for a thread that never answered, \
            so nothing below is a measurement of how this game performs — it is a description of \
            a game that hung. This is not fixed by lowering settings. Look at where it stopped: \
            take a `sample <pid>` while it is still wedged, and if the render thread is parked in \
            `msync_wait_objs` while D3DMetal's own thread waits in `os_sync_wait_on_address`, the \
            two are waiting on each other and the GPU is idle.
            """)
        }

        // 0b. The same failure, for a hang the engine never got round to
        // admitting. Deliberately narrow — minutes of session with no
        // measurable coverage AND essentially no frames — because a quiet
        // healthy minute can also log little, and a false "it hung" would be
        // exactly the kind of noise the finding above exists to avoid.
        if report.renderThreadTimeoutSeconds == nil,
           report.sessionMinutes >= 2, report.fps == nil, report.framesCounted <= 2 {
            out.append("""
            \(String(format: "%.0f", report.sessionMinutes)) minutes of log and \
            \(report.framesCounted) frame(s) advanced. Whatever this session was, it was not \
            playing. Treat the numbers below as absent rather than as evidence, and check whether \
            the game was wedged rather than idle.
            """)
        }

        // 1. Wrong layer next. Everything else is misleading until this is right.
        if let expected, let actual = report.layer?.translationLayer, actual != expected {
            out.append("""
            WRONG LAYER. The profile asks for \(expected.displayName) but the session ran on \
            \(report.layer?.displayName ?? "something else"). The profile does not decide this — \
            the Wine tree the bottle is running does. Quit Steam and launch again before drawing \
            any conclusion from the numbers above; nothing here is evidence about \
            \(expected.displayName).
            """)
        }

        // 2. The signature that cost a day: slow *and* small.
        if let fps = report.fps, let effective = report.effectiveResolution,
           fps.median < 60, isSmall(effective) {
            out.append("""
            Slow at a low resolution (\(String(format: "%.0f", fps.median)) fps median at \
            ~\(effective)). That combination is almost never a settings problem — a machine that \
            cannot hold 60 fps at that few pixels is being held back by something structural, \
            and the translation layer is the first thing to check. Do not respond by lowering \
            settings further.
            """)
        }

        // 3. Frames nobody sees are heat. Worth saying, gently.
        if report.vsync == false, let fps = report.fps, fps.median > 90 {
            out.append("""
            VSync is off and the median is \(String(format: "%.0f", fps.median)) fps. Frames above \
            the display's refresh rate are discarded — they cost power and produce heat without \
            being seen. Turning VSync on in the game's own settings pins it to the panel.
            """)
        }

        // 4. A cap that is not capping means the setting is a lie.
        if let limit = report.frameRateLimit, limit > 0,
           let fps = report.fps, fps.maximum > limit * 1.1 {
            out.append("""
            FrameRateLimit is set to \(String(format: "%.0f", limit)) but frames reach \
            \(String(format: "%.0f", fps.maximum)). The game is not honouring its own limit, so \
            do not rely on it — VSync is the cap that works.
            """)
        }

        if report.hitches > 0 {
            out.append("\(report.hitches) hitch line(s) in the log — frames over the hitch threshold.")
        }

        return out
    }

    /// The whole thing for one profile, or an explanation of why not.
    public static func report(profile: GameProfile, in bottle: Bottle) -> String {
        guard let project = profile.unrealProject, !project.isEmpty else {
            return """
            \(profile.name) has no `unrealProject`, so Wyn does not know where its log lives. \
            Frame rate can only be read from an Unreal game's own log; for anything else the \
            only evidence is launch records.
            """
        }
        guard let log = latestLog(project: project, in: bottle) else {
            return """
            No log found at users/*/AppData/Local/\(project)/Saved/Logs/\(project).log. \
            The game has to have been run at least once.
            """
        }
        guard let report = read(logURL: log) else {
            return "Could not read \(log.lastPathComponent)."
        }
        return rendered(report, expecting: profile.bottle?.translationLayer)
    }

    // MARK: - Parsing helpers

    static let minimumBucketSeconds = 20.0

    /// Above this, the frame counter jumped rather than the game ran. Set well
    /// clear of any real display: the fastest thing measured here is 120.
    static let maximumPlausibleFPS = 1000.0

    private struct Stamp {
        let time: Double
        let frame: Int
        let minuteKey: String
    }

    /// `[2026.09.04-18.11.57:343][  0]` → seconds-of-day plus frame number.
    private static func framePrefix(_ line: Substring) -> Stamp? {
        guard line.hasPrefix("[") else { return nil }
        guard let closeDate = line.firstIndex(of: "]") else { return nil }
        let datePart = line[line.index(after: line.startIndex)..<closeDate]
        // …-HH.MM.SS:mmm
        guard let dash = datePart.firstIndex(of: "-") else { return nil }
        let clock = datePart[datePart.index(after: dash)...]
        let bits = clock.split(whereSeparator: { $0 == "." || $0 == ":" })
        guard bits.count == 4,
              let hh = Int(bits[0]), let mm = Int(bits[1]),
              let ss = Int(bits[2]), let ms = Int(bits[3]) else { return nil }

        let rest = line[line.index(after: closeDate)...]
        guard rest.hasPrefix("["), let closeFrame = rest.firstIndex(of: "]") else { return nil }
        let frameText = rest[rest.index(after: rest.startIndex)..<closeFrame]
            .trimmingCharacters(in: .whitespaces)
        guard let frame = Int(frameText) else { return nil }

        return Stamp(
            time: Double(hh * 3600 + mm * 60 + ss) + Double(ms) / 1000,
            frame: frame,
            minuteKey: String(format: "%02d:%02d", hh, mm)
        )
    }

    private static func match(_ line: Substring, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let text = String(line)
        let range = NSRange(text.startIndex..., in: text)
        guard let hit = regex.firstMatch(in: text, range: range), hit.numberOfRanges > 1,
              let captured = Range(hit.range(at: 1), in: text) else { return nil }
        return String(text[captured])
    }

    /// Under 400k pixels — roughly 720p at half scale and below.
    private static func isSmall(_ resolution: String) -> Bool {
        let parts = resolution.lowercased().split(separator: "x")
        guard parts.count >= 2, let width = Int(parts[0]), let height = Int(parts[1]) else {
            return false
        }
        return width * height < 400_000
    }

    /// `Saved/Logs/x.log` → `Saved/Config/Windows/GameUserSettings.ini`.
    private static func gameUserSettings(besideLog log: URL) -> (vsync: Bool?, limit: Double?) {
        let saved = log.deletingLastPathComponent().deletingLastPathComponent()
        let ini = saved
            .appending(path: "Config").appending(path: "Windows")
            .appending(path: "GameUserSettings.ini")
        guard let text = try? String(contentsOf: ini, encoding: .utf8) else { return (nil, nil) }

        var vsync: Bool?
        var limit: Double?
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let (name, _, value) = partition(trimmed)
            // First occurrence wins: the engine section is written first and is
            // the one in effect when the two sections disagree, which they do.
            if name == "bUseVSync", vsync == nil { vsync = value.lowercased() == "true" }
            if name == "FrameRateLimit", limit == nil { limit = Double(value) }
        }
        return (vsync, limit)
    }

    private static func partition(_ line: String) -> (String, Bool, String) {
        guard let equals = line.firstIndex(of: "=") else { return (line, false, "") }
        return (String(line[..<equals]), true, String(line[line.index(after: equals)...]))
    }
}
