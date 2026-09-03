//
//  WindowsRuntimes.swift
//  WynKit
//
//  What a profile's `winetricks` list is actually worth.
//
//  Every one of the 120 shipped profiles carries a `winetricks` array, almost
//  always ["vcrun2019", "vcrun2022"]. Nothing installed them. The only code
//  that touched the field printed it, so the array documented a dependency and
//  then implied — to anyone reading a profile — that Wyn had satisfied it.
//
//  Adding Solarpunk is what exposed the cost. Steam threw a "Visual C++
//  2015-2022 Redistributable" dialog, which looked exactly like the missing
//  dependency the profile named, and we chased it. It was a false negative from
//  Steam's prereq shim: the runtime had been installed the whole time, and the
//  proof was four lines of system.reg. Guessing cost an hour; reading the
//  registry would have cost a second.
//
//  So this reads the registry. It does NOT install anything — Wyn does not
//  download Microsoft redistributables, and the games that need them get them
//  from Steam's own prerequisite installer at install time. The value here is
//  turning "the profile says vcrun2022" into "vcrun2022 is present, v14.51.
//  36247.00" or "vcrun2022 is missing", which is a fact rather than a claim.
//
//  Two deliberate choices:
//
//  It parses system.reg as text instead of running `wine reg query`. A wine
//  process against a live bottle is slow, noisy, and something we specifically
//  avoid while a game is running. The hive is a text file; read the text file.
//
//  It has an `unknown` case and uses it. A verb this file has never heard of
//  gets reported as uncheckable, not as satisfied. Silently returning "fine"
//  for anything unrecognised is how the field became decorative in the first
//  place.
//

import Foundation

/// A Windows runtime a profile can declare a dependency on, by winetricks verb.
public enum WindowsRuntime: String, Sendable, CaseIterable {

    /// The VC++ 2015–2022 x64 runtime.
    ///
    /// `vcrun2019` and `vcrun2022` are the same redistributable. Microsoft has
    /// shipped 2015, 2017, 2019 and 2022 as one binary-compatible 14.x runtime
    /// since 2017, and the registry has one key for all of them — which is why
    /// 114 profiles asking for `vcrun2019` and 79 asking for `vcrun2022` are
    /// asking for the same thing, and why both map here.
    case visualCPlusPlus

    /// .NET Framework 4.x. In a Wine bottle this is normally Wine Mono rather
    /// than Microsoft's runtime, and `check` says so instead of pretending.
    case dotNetFramework

    public init?(winetricksVerb verb: String) {
        switch verb.lowercased() {
        case "vcrun2015", "vcrun2017", "vcrun2019", "vcrun2022":
            self = .visualCPlusPlus
        case "dotnet40", "dotnet45", "dotnet46", "dotnet47", "dotnet48":
            self = .dotNetFramework
        default:
            return nil
        }
    }

    public var displayName: String {
        switch self {
        case .visualCPlusPlus: return "Visual C++ 2015-2022 runtime"
        case .dotNetFramework: return ".NET Framework 4.x"
        }
    }

    /// The key in `system.reg` (the HKLM hive, so paths are written without the
    /// `HKLM\Software` prefix Wine strips when it writes the file).
    fileprivate var registryKey: String {
        switch self {
        case .visualCPlusPlus:
            return #"Software\Microsoft\VisualStudio\14.0\VC\Runtimes\x64"#
        case .dotNetFramework:
            return #"Software\Microsoft\NET Framework Setup\NDP\v4\Full"#
        }
    }

    /// The DWORD that means "this is installed", not merely "something wrote a
    /// key here".
    fileprivate var installedFlag: String {
        switch self {
        case .visualCPlusPlus: return "Installed"
        case .dotNetFramework: return "Install"
        }
    }
}

// MARK: - The result

/// What a check found. Three outcomes, because two would force a lie: a verb
/// nobody has taught this file to probe is neither present nor missing.
public enum RuntimeCheck: Sendable, Equatable {
    /// Found, with whatever the registry says it is.
    case present(String)
    /// The key is absent or the installed flag is not set.
    case missing
    /// Cannot be answered — an unrecognised verb, or a bottle with no registry.
    case unknown(String)

    public var isMissing: Bool {
        if case .missing = self { return true }
        return false
    }
}

public struct RuntimeRequirement: Sendable, Equatable {
    /// The verbs exactly as the profile wrote them, so a report can quote them
    /// back. Usually one. `vcrun2019` and `vcrun2022` name the same runtime and
    /// most profiles list both, so those collapse into a single requirement
    /// carrying both verbs rather than printing the same line twice.
    public let verbs: [String]
    public let runtime: WindowsRuntime?
    public let result: RuntimeCheck

    public var verb: String { verbs.joined(separator: ", ") }

    public var displayName: String { runtime?.displayName ?? verb }

    /// One line, suitable for a terminal, a diagnostics bundle, or an alert.
    public var summary: String {
        switch result {
        case .present(let detail):
            return detail.isEmpty
                ? "\(displayName): present"
                : "\(displayName): present (\(detail))"
        case .missing:
            return "\(displayName): MISSING"
        case .unknown(let why):
            return "\(displayName): not checked — \(why)"
        }
    }
}

// MARK: - The check

public enum WindowsRuntimes {

    /// One read of the hive, reusable across many profiles.
    ///
    /// `system.reg` on a real bottle is about 4 MB. Checking 110 profiles a
    /// value at a time — which the diagnostics report and a SwiftUI computed
    /// property both do — would read nearly half a gigabyte to answer two
    /// questions. Take a snapshot, ask it repeatedly.
    ///
    /// It is a point-in-time copy by design: nothing here installs anything, so
    /// the hive cannot change underneath a single report.
    public struct Snapshot: Sendable {
        /// Every runtime's verdict, worked out once at init.
        ///
        /// There are only two of them and the answer does not depend on which
        /// profile is asking, so scanning a 4 MB string per profile per runtime
        /// — 220-odd full-string searches for a diagnostics report — buys
        /// nothing. Two searches, then dictionary lookups.
        fileprivate let verdicts: [WindowsRuntime: RuntimeCheck]

        public init(prefix: URL) {
            let hive = try? String(
                contentsOf: prefix.appending(path: "system.reg"),
                encoding: .utf8
            )
            guard let hive else {
                verdicts = [:]
                return
            }
            var verdicts: [WindowsRuntime: RuntimeCheck] = [:]
            for runtime in WindowsRuntime.allCases {
                verdicts[runtime] = WindowsRuntimes.probe(runtime, in: hive, prefix: prefix)
            }
            self.verdicts = verdicts
        }

        public init(bottle: Bottle) { self.init(prefix: bottle.url) }

        public func check(profile: GameProfile) -> [RuntimeRequirement] {
            check(verbs: profile.winetricks)
        }

        public func check(verbs: [String]) -> [RuntimeRequirement] {
            WindowsRuntimes.check(verbs: verbs, verdicts: verdicts)
        }

        public func missing(profile: GameProfile) -> [RuntimeRequirement] {
            check(profile: profile).filter(\.result.isMissing)
        }
    }

    /// Check every runtime a profile declares, in the order it declared them.
    ///
    /// Reads the hive each call. For more than one profile, take a `Snapshot`.
    public static func check(profile: GameProfile, in bottle: Bottle) -> [RuntimeRequirement] {
        Snapshot(bottle: bottle).check(profile: profile)
    }

    /// Prefix-based so it can be tested against a fixture directory rather than
    /// a real bottle.
    public static func check(verbs: [String], prefix: URL) -> [RuntimeRequirement] {
        Snapshot(prefix: prefix).check(verbs: verbs)
    }

    /// An empty `verdicts` means the bottle has no registry — which is not the
    /// same as the runtimes being absent, and must not be reported as missing.
    private static func check(
        verbs: [String],
        verdicts: [WindowsRuntime: RuntimeCheck]
    ) -> [RuntimeRequirement] {
        guard !verbs.isEmpty else { return [] }

        // Collapse verbs that name the same runtime, keeping first-seen order,
        // so a profile listing both vcrun2019 and vcrun2022 gets one line.
        // Unrecognised verbs never merge — each is its own unanswered question.
        var groups: [(runtime: WindowsRuntime?, verbs: [String])] = []
        for verb in verbs {
            let runtime = WindowsRuntime(winetricksVerb: verb)
            if let runtime, let existing = groups.firstIndex(where: { $0.runtime == runtime }) {
                groups[existing].verbs.append(verb)
            } else {
                groups.append((runtime, [verb]))
            }
        }

        return groups.map { runtime, matched in
            guard let runtime else {
                return RuntimeRequirement(
                    verbs: matched,
                    runtime: nil,
                    result: .unknown("Wyn does not know how to look for \"\(matched.joined(separator: ", "))\"")
                )
            }
            return RuntimeRequirement(
                verbs: matched,
                runtime: runtime,
                result: verdicts[runtime] ?? .unknown("this bottle has no registry yet")
            )
        }
    }

    /// The ones that are actually absent. Empty is the common case and the one
    /// callers should stay quiet about.
    public static func missing(profile: GameProfile, in bottle: Bottle) -> [RuntimeRequirement] {
        check(profile: profile, in: bottle).filter(\.result.isMissing)
    }

    // MARK: - Reading the hive

    private static func probe(_ runtime: WindowsRuntime, in hive: String, prefix: URL) -> RuntimeCheck {
        guard let values = section(runtime.registryKey, in: hive) else { return .missing }
        guard dword(values[runtime.installedFlag]) == 1 else { return .missing }

        var detail = values["Version"].map(unquoted) ?? ""

        // Wine Mono answers for .NET, and reports a version Microsoft never
        // shipped. Say which one is there rather than implying MS .NET 4.8.
        if runtime == .dotNetFramework, isWineMono(prefix: prefix) {
            detail = detail.isEmpty ? "Wine Mono" : "\(detail), Wine Mono"
        }

        return .present(detail)
    }

    /// Pull one `[key]` section out of a .reg file as name → raw value.
    ///
    /// Wine writes the key with every backslash doubled and a trailing epoch,
    /// e.g. `[Software\\Microsoft\\...\\x64] 1788466788`, so the header is
    /// matched on the bracketed part alone.
    private static func section(_ key: String, in hive: String) -> [String: String]? {
        let header = "[" + key.replacingOccurrences(of: #"\"#, with: #"\\"#) + "]"
        guard let start = hive.range(of: header) else { return nil }

        let rest = hive[start.upperBound...]
        let end = rest.range(of: "\n[")?.lowerBound ?? rest.endIndex

        var values: [String: String] = [:]
        for line in rest[..<end].split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("\""), let split = line.range(of: "\"=") else { continue }
            let name = String(line[line.index(after: line.startIndex)..<split.lowerBound])
            values[name] = String(line[split.upperBound...])
        }
        return values
    }

    private static func dword(_ raw: String?) -> Int? {
        guard let raw, raw.hasPrefix("dword:") else { return nil }
        return Int(raw.dropFirst("dword:".count), radix: 16)
    }

    private static func unquoted(_ raw: String) -> String {
        guard raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 else { return raw }
        return String(raw.dropFirst().dropLast())
    }

    private static func isWineMono(prefix: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: prefix.appending(path: "drive_c/windows/mono").path(percentEncoded: false)
        )
    }
}
