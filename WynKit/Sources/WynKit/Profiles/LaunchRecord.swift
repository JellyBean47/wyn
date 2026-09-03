//
//  LaunchRecord.swift
//  WynKit
//
//  Evidence that a profile actually ran.
//
//  Wyn ships 120 profiles and exactly one of them was ever measured, because
//  measuring meant owning the game and sitting in front of it. Beta testers own
//  the games — but a tester playing Palworld for an hour currently produces
//  nothing at all, so five hundred of them still leave one verified profile.
//  The bottleneck is not testing, it is that nothing is written down.
//
//  So: when a game's process is seen running and stays up, that gets recorded,
//  locally, without anyone being asked to do anything.
//
//  Two things this deliberately does NOT claim.
//
//  A record says the process started and stayed up. It does not say the game
//  worked — the black Steam login window ran happily for minutes showing
//  nothing, which is exactly why `launched` is a rung below `verified` and why
//  only a person who watched the screen can grant the top one.
//
//  And a record is tied to a fingerprint of the settings that produced it. If
//  the profile's environment, launch args or bottle overrides change, the old
//  evidence stops counting — it vouched for settings that no longer exist. That
//  is the discipline that was missing when 72 profiles had MetalFX turned on.
//

import CryptoKit
import Foundation

public struct LaunchRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(profileID)-\(startedAt.timeIntervalSince1970)" }

    public let profileID: String
    public let startedAt: Date
    /// How long the game's process was observed running.
    public let ranForSeconds: Double
    /// Hash of the settings in force. Evidence does not survive a settings change.
    public let settingsFingerprint: String
    public let wynVersion: String
    public let macOSVersion: String
    /// The translation layer the profile asked for, so a record is comparable.
    public let layer: String?

    public init(
        profileID: String,
        startedAt: Date,
        ranForSeconds: Double,
        settingsFingerprint: String,
        wynVersion: String,
        macOSVersion: String,
        layer: String?
    ) {
        self.profileID = profileID
        self.startedAt = startedAt
        self.ranForSeconds = ranForSeconds
        self.settingsFingerprint = settingsFingerprint
        self.wynVersion = wynVersion
        self.macOSVersion = macOSVersion
        self.layer = layer
    }
}

extension GameProfile {
    /// Everything that changes how the game runs, hashed.
    ///
    /// Name, publisher and notes are excluded on purpose: fixing a typo in the
    /// notes must not throw away a real launch record. Anything that reaches
    /// Wine is included, because a record has to vouch for what it saw.
    public var settingsFingerprint: String {
        var parts: [String] = []
        parts.append("layer=\(bottle?.translationLayer?.rawValue ?? "-")")
        parts.append("win=\(bottle?.windowsVersion?.rawValue ?? "-")")
        parts.append("sync=\(bottle?.enhancedSync?.rawValue ?? "-")")
        parts.append("dxvk=\(bottle?.dxvk.map(String.init) ?? "-")")
        parts.append("dxvkAsync=\(bottle?.dxvkAsync.map(String.init) ?? "-")")
        parts.append("dxr=\(bottle?.dxrEnabled.map(String.init) ?? "-")")
        parts.append("avx=\(bottle?.avxEnabled.map(String.init) ?? "-")")
        parts.append("metalHud=\(bottle?.metalHud.map(String.init) ?? "-")")
        parts.append("args=\(launchArgs ?? "-")")
        parts.append("winetricks=\(winetricks.sorted().joined(separator: ","))")
        for key in environment.keys.sorted() {
            parts.append("env.\(key)=\(environment[key] ?? "")")
        }
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\n").utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}

// MARK: - Observing

/// Turns "which game processes are running right now" into launch records.
///
/// Pure and driven from outside, so the app's existing 2.5 s poll can feed it
/// and the tests can feed it a timeline. Nothing here watches processes itself;
/// adding a second watchdog to a Wine host is how you get orphans.
public struct LaunchObserver: Sendable {
    /// How long a game must stay up before it counts as more than "the process
    /// appeared". A crash-loop dies in seconds; the known-good Satisfactory
    /// session ran 39 minutes. A minute is comfortably clear of the first and
    /// forgiving of someone who quits straight away.
    public static let minimumUptime: TimeInterval = 60

    private var startedAt: [String: Date] = [:]

    public init() {}

    /// Feed the currently-running profile ids. Returns ids whose run just ended
    /// having lasted long enough to be worth recording, with how long they ran.
    public mutating func update(
        running: Set<String>,
        now: Date = Date()
    ) -> [(profileID: String, startedAt: Date, ranFor: TimeInterval)] {
        for id in running where startedAt[id] == nil {
            startedAt[id] = now
        }

        var finished: [(String, Date, TimeInterval)] = []
        for (id, start) in startedAt where !running.contains(id) {
            let ranFor = now.timeIntervalSince(start)
            startedAt[id] = nil
            if ranFor >= Self.minimumUptime {
                finished.append((id, start, ranFor))
            }
        }
        return finished.map { (profileID: $0.0, startedAt: $0.1, ranFor: $0.2) }
    }

    /// Ids currently being timed, for tests and diagnostics.
    public var inFlight: Set<String> { Set(startedAt.keys) }
}

// MARK: - Storing

public enum LaunchRecordStore {
    /// Beside the user's own profiles, not in the app bundle — the bundle is
    /// read-only and shared, and this is the machine's own evidence.
    public static var fileURL: URL {
        ProfileStore.userProfilesDirectory
            .deletingLastPathComponent()
            .appending(path: "launch-records.json")
    }

    public static func load() -> [LaunchRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([LaunchRecord].self, from: data)) ?? []
    }

    @discardableResult
    public static func append(_ record: LaunchRecord) -> Bool {
        var records = load()
        records.append(record)
        // Keep the file small and the newest evidence: a tester who plays one
        // game for a year should not carry a thousand identical rows.
        if records.count > 500 {
            records = Array(records.suffix(500))
        }
        return write(records)
    }

    @discardableResult
    static func write(_ records: [LaunchRecord]) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return false }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return (try? data.write(to: fileURL, options: .atomic)) != nil
    }

    /// Records that still vouch for this profile as it is configured now.
    public static func evidence(for profile: GameProfile, in records: [LaunchRecord]? = nil) -> [LaunchRecord] {
        let fingerprint = profile.settingsFingerprint
        return (records ?? load()).filter {
            $0.profileID == profile.id && $0.settingsFingerprint == fingerprint
        }
    }

    /// What this profile has actually earned.
    ///
    /// `verified` is declared by a person who measured something and wrote it
    /// down; no amount of local running promotes to it, because running is not
    /// measuring. `launched` is earned by evidence and never declared in the
    /// shipped JSON — which is why a profile file claiming `launched` is
    /// treated as the guess it is.
    public static func effectiveStatus(
        for profile: GameProfile,
        in records: [LaunchRecord]? = nil
    ) -> ProfileStatus {
        if profile.status == .verified { return .verified }
        return evidence(for: profile, in: records).isEmpty ? .guessed : .launched
    }

    public static func makeRecord(
        for profile: GameProfile,
        startedAt: Date,
        ranFor: TimeInterval
    ) -> LaunchRecord {
        LaunchRecord(
            profileID: profile.id,
            startedAt: startedAt,
            ranForSeconds: ranFor.rounded(),
            settingsFingerprint: profile.settingsFingerprint,
            wynVersion: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            layer: profile.bottle?.translationLayer?.rawValue
        )
    }
}
