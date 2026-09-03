//
//  DiagnosticsBundle+Collect.swift
//  WynKit
//
//  Gathering half of the diagnostics bundle. The redaction rules it obeys live
//  in DiagnosticsBundle.swift; nothing here writes a byte that has not been
//  through `redact`.
//

import Foundation

extension DiagnosticsBundle {

    public struct Result: Sendable {
        public let url: URL
        public let byteCount: Int
        public let fileCount: Int

        public var readableSize: String {
            ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
        }
    }

    /// Steam log files worth having, by name. A whitelist: `Steam/logs` also
    /// accumulates files we have no use for, and `Steam/config` — which is
    /// never touched — is one directory away.
    static let steamLogNames = [
        "bootstrap_log.txt",    // the client's own updater: verify + re-extract
        "webhelper.txt",        // which cef.win* variant, and with which flags
        "cef_log.txt",
        "connection_log.txt",
        "steamui_login.txt",
        "console_log.txt",
        "content_log.txt"
    ]

    private static let maxLogLines = 1500
    private static let maxWynLogs = 8

    /// Build the bundle and return where it landed. Defaults to the Desktop
    /// because a tester has to be able to find it without being told.
    @discardableResult
    public static func create(
        bottle: Bottle?,
        destinationDirectory: URL? = nil,
        note: String? = nil
    ) throws -> Result {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let user = NSUserName()

        let stamp = timestamp()
        let name = "wyn-diagnostics-\(stamp)"
        let staging = fm.temporaryDirectory.appending(path: name)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        func write(_ text: String, to relativePath: String) throws {
            let url = staging.appending(path: relativePath)
            try fm.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let safe = redact(text, homeDirectory: home, userName: user)
            try safe.write(to: url, atomically: true, encoding: .utf8)
        }

        try write(readme(note: note), to: "README.txt")
        try write(summary(bottle: bottle, stamp: stamp), to: "summary.txt")
        try write(cefReport(bottle: bottle), to: "cef-shim.txt")
        try write(processReport(), to: "processes.txt")
        try write(doctorReport(bottle: bottle), to: "doctor.txt")

        // Wyn's own logs.
        for log in recentWynLogs() {
            guard !isExcluded(fileName: log.lastPathComponent) else { continue }
            guard let text = readText(log) else { continue }
            try write(tail(text, lines: maxLogLines), to: "wyn-logs/\(log.lastPathComponent)")
        }

        // Steam's logs, by name only.
        if let bottle {
            let logs = SteamCEFShim.steamRoot(in: bottle).appending(path: "logs")
            for fileName in steamLogNames {
                guard !isExcluded(fileName: fileName) else { continue }
                let url = logs.appending(path: fileName)
                guard let text = readText(url) else { continue }
                try write(tail(text, lines: maxLogLines), to: "steam-logs/\(fileName)")
            }
        }

        let destination = (destinationDirectory ?? defaultDestination())
            .appending(path: "\(name).zip")
        try? fm.removeItem(at: destination)
        try zip(staging, to: destination)

        let fileCount = (try? fm.subpathsOfDirectory(atPath: staging.path(percentEncoded: false)))?
            .filter { !$0.hasSuffix(".DS_Store") }.count ?? 0
        let size = (try? fm.attributesOfItem(atPath: destination.path(percentEncoded: false))[.size] as? Int) ?? 0

        return Result(url: destination, byteCount: size, fileCount: fileCount)
    }

    // MARK: - Sections

    private static func readme(note: String?) -> String {
        var text = """
        Wyn diagnostics bundle
        ======================

        Made by Wyn to answer "why did it not work". Send the whole zip.

        WHAT IS IN HERE
          summary.txt    versions, renderer, bottles, what is installed
          doctor.txt     the same report as `wyn doctor`
          cef-shim.txt   Steam's CEF variants and whether the login-window shim
                         reached the one Steam actually loads
          processes.txt  Wine and Steam processes running at capture time
          wyn-logs/      Wyn's own recent logs
          steam-logs/    Steam's client logs from the bottle

        WHAT IS NOT IN HERE
          Nothing from Steam's config/ directory. Your account name, your
          SteamID and your saved-login token live there and are never read.
          No .vdf or ssfn* file of any kind.

          Everything above was scrubbed before it was written: your home folder
          path, your macOS user name, SteamIDs, and e-mail addresses are
          replaced with ~, <user>, <steamid> and <email>.

          Long logs are trimmed to their last \(maxLogLines) lines, which is
          where launch failures are. Trimmed files say so at the top.

        You can open every file in here and read it. Nothing is compressed
        beyond the zip, and nothing is encoded.
        """
        if let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text += "\n\n        WHAT THE REPORTER SAID\n          \(note)\n"
        }
        return text
    }

    private static func summary(bottle: Bottle?, stamp: String) -> String {
        var lines: [String] = []
        lines.append("captured: \(stamp)")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("arch: \(machineArchitecture())")
        lines.append("app: \(Bundle.main.bundleURL.path(percentEncoded: false))")
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
            lines.append("version: \(v) (\(build))")
        }
        lines.append("WynWine installed: \(WynWineInstaller.isWynWineInstalled())")
        lines.append("shim helper present: \(SteamCEFShim.bundledShimURL != nil)")
        lines.append("")

        lines.append("renderer:")
        for line in RendererWiring.inspect().statusLines {
            lines.append("  \(line)")
        }
        lines.append("")

        var data = BottleData()
        let bottles = data.loadBottles()
        lines.append("bottles registered: \(bottles.count)")
        for b in bottles {
            let effective = LaunchDiagnostics.effectiveLayer(for: b)
            let marker = (b.url == bottle?.url) ? " <- this report" : ""
            lines.append("  - \(b.settings.name): layer=\(b.settings.translationLayer.rawValue) "
                         + "dxvk=\(b.settings.dxvk) effective=\(effective.layer.rawValue)\(marker)")
            lines.append("      \(b.url.path(percentEncoded: false))")
        }
        if bottles.isEmpty {
            lines.append("  (none — Steam has never been installed, or the registry was lost)")
        }
        lines.append("")
        lines.append("free space on home volume: \(freeSpaceDescription())")
        return lines.joined(separator: "\n")
    }

    /// The black-login-window evidence, assembled so nobody has to know where
    /// it lives. This is the section the whole bundle exists for.
    private static func cefReport(bottle: Bottle?) -> String {
        guard let bottle else {
            return "No bottle to inspect — Steam has not been installed in this bottle yet."
        }
        var lines: [String] = []
        let root = SteamCEFShim.steamRoot(in: bottle)
        lines.append("steam root: \(root.path(percentEncoded: false))")
        lines.append("")

        let variants = SteamCEFShim.cefVariantDirectories(in: bottle)
        if variants.isEmpty {
            lines.append("No cef.win* directories. Steam has not unpacked its login UI yet.")
        } else {
            let helpers = SteamCEFShim.helperBearingVariants(in: bottle)
            let shimmed = SteamCEFShim.shimmedVariants(in: bottle)
            lines.append("cef variants:")
            for dir in variants {
                let name = dir.lastPathComponent
                let born = creationDate(of: dir).map(shortTime) ?? "?"
                var state = "no helper"
                if shimmed.contains(name) {
                    state = "SHIMMED"
                } else if helpers.contains(name) {
                    state = "Valve helper, NOT shimmed"
                }
                lines.append("  \(name)  created \(born)  \(state)")
                for exe in ["steamwebhelper.exe", "steamwebhelper_real.exe"] {
                    let url = dir.appending(path: exe)
                    if let size = fileSize(url) {
                        lines.append("      \(exe)  \(size) bytes")
                    }
                }
            }
            lines.append("")
            lines.append("all variants that have a helper are shimmed: \(SteamCEFShim.isInstalled(in: bottle))")
        }
        lines.append("")

        // The single most diagnostic fact there is.
        if let launch = SteamCEFShim.lastWebHelperLaunch(in: bottle) {
            lines.append("last helper Steam launched: \(launch.variant)/\(launch.executable)")
            lines.append("  carried --in-process-gpu: \(launch.shimmed)")
            if !launch.shimmed && launch.executable.lowercased().contains("_real") {
                lines.append("  ^^ a real helper without the flag. The login window will be black.")
            }
        } else {
            lines.append("Steam has not launched a webhelper yet (no webhelper.txt entries).")
        }
        lines.append("")

        let bootstrap = SteamCEFShim.bootstrapLogURL(in: bottle)
        if let text = readText(bootstrap) {
            let hits = text.components(separatedBy: "steamwebhelper.exe is 151908").count - 1
            lines.append("Steam rejected the shim as a corrupt file \(hits) time(s).")
            if hits > 0 {
                lines.append("  ^^ verify/re-extract loop: Steam is overwriting the shim and restarting.")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func processReport() -> String {
        let out = run("/bin/ps", ["-ax", "-o", "pid=,command="])
        let interesting = out
            .split(separator: "\n")
            .filter { line in
                let l = line.lowercased()
                return l.contains("wine") || l.contains("steam") || l.contains("wyn.app")
            }
            .map(String.init)
        if interesting.isEmpty { return "No Wine, Steam or Wyn processes running." }
        return interesting.joined(separator: "\n")
    }

    private static func doctorReport(bottle: Bottle?) -> String {
        guard let bottle else { return "No bottle — nothing for doctor to inspect." }
        let report = LaunchDiagnostics.inspect(
            bottle: bottle,
            profile: nil,
            executable: nil,
            environment: [:],
            phase: "diagnostics-bundle"
        )
        return report.rendered
    }

    // MARK: - Plumbing

    private static func defaultDestination() -> URL {
        let fm = FileManager.default
        if let desktop = try? fm.url(
            for: .desktopDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) {
            return desktop
        }
        return URL(fileURLWithPath: NSHomeDirectory())
    }

    /// `ditto` ships with macOS and has never needed a dependency.
    private static func zip(_ source: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [
            "-c", "-k", "--sequesterRsrc", "--keepParent",
            source.path(percentEncoded: false),
            destination.path(percentEncoded: false)
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DiagnosticsBundleError.zipFailed(status: process.terminationStatus)
        }
    }

    private static func recentWynLogs() -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: Wine.logsFolder,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }
        return items.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        .prefix(maxWynLogs)
        .map { $0 }
    }

    private static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func fileSize(_ url: URL) -> Int? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return (attrs?[.size] as? NSNumber)?.intValue
    }

    private static func creationDate(of url: URL) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return attrs?[.creationDate] as? Date
    }

    private static func shortTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: date)
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    private static func machineArchitecture() -> String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return machine
    }

    private static func freeSpaceDescription() -> String {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage
        else { return "unknown" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func run(_ launchPath: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return "(could not run \(launchPath): \(error.localizedDescription))"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

public enum DiagnosticsBundleError: LocalizedError {
    case zipFailed(status: Int32)

    public var errorDescription: String? {
        switch self {
        case .zipFailed(let status):
            return "Could not write the diagnostics zip (ditto exited \(status))."
        }
    }
}
