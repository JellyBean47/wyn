//
//  D3DMetalGpuSettle.swift
//  WynKit
//
//  After a D3DMetal Unreal quit, Metal queues are still retiring. Immediate
//  Play hits RHIThread EXCEPTION_ILLEGAL_INSTRUCTION. This is not a thermal
//  cool-down and not a wineserver kill — wait only.
//

import Foundation

/// How long `wyn play` / the Wyn tile must wait after the last D3DMetal session.
///
/// 29 Aug 2026, Satisfactory on FOSS winecx + D3DMetal 3.0:
/// - ~7s after FMallocBinned2 canary → SIGILL
/// - ~31s → SIGILL (a 30s gate skipped this)
/// - ~103s (13:24 → 13:26) → fine
/// CrossOver has no Wine patch; Steam's Play button is just slower.
public enum D3DMetalGpuSettle: Sendable {
    public static let duration: TimeInterval = 120

    /// Seconds still to wait. `nil` last-exit = cold start (no wait).
    public static func remaining(
        now: Date = Date(),
        settle: TimeInterval = duration,
        processJustExitedAt: Date?,
        rememberedExitAt: Date?,
        unrealLogMtime: Date?
    ) -> TimeInterval {
        let last = [processJustExitedAt, rememberedExitAt, unrealLogMtime]
            .compactMap { $0 }
            .max()
        guard let last else { return 0 }
        return max(0, settle - now.timeIntervalSince(last))
    }

    public static func stampURL(profileId: String, bottleURL: URL) -> URL {
        bottleURL.appending(path: ".wyn-d3dmetal-gpu-exit-\(profileId)")
    }

    /// Unreal CrashReportClient / crashpad left after a quit. Not a live game session.
    public static let reporterExeNames: Set<String> = [
        "crashreportclient.exe",
        "crashpad_handler.exe"
    ]

    /// True when a leftover PE is the game itself. Reporter-only leftovers must not
    /// block Play — they outlive the session for hours if nobody clicks Close.
    public static func leftoverIsLiveGame(basename: String, gameExeNames: Set<String>) -> Bool {
        let base = basename.lowercased()
        if reporterExeNames.contains(base) { return false }
        return gameExeNames.contains(base)
    }

    /// Latest Unreal `Saved/Logs/<project>.log` mtime (canary / LogExit).
    public static func latestUnrealSessionLogMtime(project: String, bottleURL: URL) -> Date? {
        guard !project.isEmpty else { return nil }
        let usersRoot = bottleURL.appending(path: "drive_c").appending(path: "users")
        let fm = FileManager.default
        guard let users = try? fm.contentsOfDirectory(
            at: usersRoot, includingPropertiesForKeys: nil
        ) else { return nil }
        var latest: Date?
        for user in users {
            let log = user
                .appending(path: "AppData")
                .appending(path: "Local")
                .appending(path: project)
                .appending(path: "Saved")
                .appending(path: "Logs")
                .appending(path: "\(project).log")
            guard fm.fileExists(atPath: log.path(percentEncoded: false)) else { continue }
            let mtime = (try? log.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            if latest == nil || mtime > latest! { latest = mtime }
        }
        return latest
    }
}
