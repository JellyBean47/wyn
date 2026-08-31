//
//  SteamLauncher+D3DMetalGpuSettle.swift
//  WynKit
//
//  Wait for leftover game EXEs, then 120s D3DMetal GPU settle. Never wineserver -k.
//

import Foundation

extension SteamLauncher {
    private static let gpuSettleMemory = GpuSettleMemory()

    private static func profileUsesD3DMetal(_ profile: GameProfile) -> Bool {
        profile.bottle?.translationLayer == .d3dMetal
    }

    /// Call before starting a game. Leftover EXEs first; D3DMetal then waits 120s.
    static func waitOutPreviousD3DMetalSession(
        profile: GameProfile,
        bottle: Bottle
    ) async throws {
        let processExit = try await waitForPreviousSessionToExit(profile: profile, bottle: bottle)
        try await waitForD3DMetalGpuSettle(
            profile: profile,
            bottle: bottle,
            processJustExitedAt: processExit
        )
    }

    /// Wyn detaches after `wine start`. Watch for the game EXE to vanish and stamp
    /// that time so the next Play does not need FactoryGame.log.
    static func scheduleD3DMetalExitStamp(profile: GameProfile, bottle: Bottle) {
        guard profileUsesD3DMetal(profile) else { return }
        let profileId = profile.id
        let names = gameSessionExeNames(for: profile)
        Task.detached {
            let deadline = Date().addingTimeInterval(60 * 15)
            var sawGame = false
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let leftover = leftoverSessionCommands(matching: names)
                if !leftover.isEmpty { sawGame = true; continue }
                if sawGame {
                    rememberGpuSessionExit(profileId: profileId, at: Date(), bottle: bottle)
                    return
                }
            }
        }
    }

    /// Game PEs only. CrashReportClient is not a live session.
    private static func gameSessionExeNames(for profile: GameProfile, extra: URL? = nil) -> Set<String> {
        var names = Set<String>()
        func insert(_ raw: String) {
            let base = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" })
                .last.map(String.init)?.lowercased() ?? raw.lowercased()
            guard base.hasSuffix(".exe") else { return }
            names.insert(base)
        }
        if let extra { insert(extra.lastPathComponent) }
        profile.exePatterns.forEach(insert)
        return names
    }

    /// First `*.exe` token in a `ps` command — Wine PE argv0, not `steamwebhelper`.
    /// Wine argv uses backslashes; `NSString.lastPathComponent` only splits on `/`.
    static func windowsExeBasename(fromCommand command: String) -> String? {
        for token in command.split(whereSeparator: \.isWhitespace) {
            let base = String(token)
                .split(whereSeparator: { $0 == "/" || $0 == "\\" })
                .last
                .map(String.init)?
                .lowercased()
            if let base, base.hasSuffix(".exe") { return base }
        }
        return nil
    }

    /// Wine PE rows whose first `.exe` basename is in `names`.
    /// Callers pass game EXE names; CrashReportClient is not a live session.
    /// Never Steam, steamwebhelper, or wineserver. Does not kill anything.
    static func leftoverSessionCommands(matching names: Set<String>) -> [String] {
        guard !names.isEmpty else { return [] }
        return pidAndCommandRows().compactMap { row in
            let command = row.command
            if lineIsSteamClientExe(command) { return nil }
            let lower = command.lowercased()
            if lower.contains("steamwebhelper") { return nil }
            if lower.contains("wineserver") { return nil }
            guard let base = windowsExeBasename(fromCommand: command), names.contains(base) else {
                return nil
            }
            return command
        }
    }

    /// Quick relaunch after quit must not start until the game EXE is gone.
    /// CrashReportClient alone is ignored — it can sit for hours. Wait only;
    /// never `wineserver -k`.
    /// - Returns: when the game EXE became empty; `nil` if it was already gone.
    @discardableResult
    private static func waitForPreviousSessionToExit(
        profile: GameProfile,
        bottle: Bottle? = nil,
        extraExecutable: URL? = nil,
        timeout: TimeInterval = 90
    ) async throws -> Date? {
        let names = gameSessionExeNames(for: profile, extra: extraExecutable)
        func leftovers() -> [String] {
            leftoverSessionCommands(matching: names).filter { command in
                guard let base = windowsExeBasename(fromCommand: command) else { return false }
                return D3DMetalGpuSettle.leftoverIsLiveGame(basename: base, gameExeNames: names)
            }
        }

        var leftover = leftovers()
        if leftover.isEmpty {
            let reporters = leftoverSessionCommands(matching: D3DMetalGpuSettle.reporterExeNames)
            if !reporters.isEmpty {
                progress("Ignoring leftover CrashReportClient (game already quit). Close it without sending if it is on screen.")
            }
            return nil
        }

        func summary(_ rows: [String]) -> String {
            let short = rows.compactMap { windowsExeBasename(fromCommand: $0) }
            return Array(Set(short)).sorted().joined(separator: ", ")
        }

        progress("Waiting for the previous session to exit (\(summary(leftover)))…")
        let deadline = Date().addingTimeInterval(timeout)
        var last = summary(leftover)
        while Date() < deadline {
            try Task.checkCancellation()
            leftover = leftovers()
            if leftover.isEmpty {
                try await Task.sleep(nanoseconds: 800_000_000)
                leftover = leftovers()
                if leftover.isEmpty {
                    let gone = Date()
                    rememberGpuSessionExit(profileId: profile.id, at: gone, bottle: bottle)
                    return gone
                }
            }
            let now = summary(leftover)
            if now != last {
                last = now
                progress("Waiting for the previous session to exit (\(now))…")
            }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        throw SteamError.previousSessionStillRunning(summary: summary(leftover))
    }

    private static func rememberGpuSessionExit(profileId: String, at date: Date, bottle: Bottle?) {
        gpuSettleMemory.set(profileId, date)
        guard let bottle else { return }
        let url = D3DMetalGpuSettle.stampURL(profileId: profileId, bottleURL: bottle.url)
        try? String(date.timeIntervalSince1970).write(to: url, atomically: true, encoding: .utf8)
    }

    private static func rememberedGpuSessionExit(profileId: String, bottle: Bottle) -> Date? {
        let memory = gpuSettleMemory.get(profileId)
        var stamp: Date?
        let url = D3DMetalGpuSettle.stampURL(profileId: profileId, bottleURL: bottle.url)
        if let raw = try? String(contentsOf: url, encoding: .utf8),
           let interval = TimeInterval(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            stamp = Date(timeIntervalSince1970: interval)
        }
        return [memory, stamp].compactMap { $0 }.max()
    }

    /// After EXEs are gone, wait until D3DMetal/Metal queues from the last play
    /// can retire. Steam stays Logged On.
    private static func waitForD3DMetalGpuSettle(
        profile: GameProfile,
        bottle: Bottle,
        processJustExitedAt: Date?
    ) async throws {
        guard profileUsesD3DMetal(profile) else { return }

        let logMtime: () -> Date? = {
            guard let project = profile.unrealProject else { return nil }
            return D3DMetalGpuSettle.latestUnrealSessionLogMtime(
                project: project, bottleURL: bottle.url
            )
        }

        var remaining = D3DMetalGpuSettle.remaining(
            processJustExitedAt: processJustExitedAt,
            rememberedExitAt: rememberedGpuSessionExit(profileId: profile.id, bottle: bottle),
            unrealLogMtime: logMtime()
        )
        guard remaining > 0.5 else { return }

        var exitAnchor = processJustExitedAt
        if let mark = exitAnchor {
            rememberGpuSessionExit(profileId: profile.id, at: mark, bottle: bottle)
        } else if let log = logMtime() {
            rememberGpuSessionExit(profileId: profile.id, at: log, bottle: bottle)
        }

        while remaining > 0.5 {
            try Task.checkCancellation()
            let leftovers = leftoverSessionCommands(
                matching: gameSessionExeNames(for: profile)
            )
            if !leftovers.isEmpty {
                if let gone = try await waitForPreviousSessionToExit(
                    profile: profile, bottle: bottle
                ) {
                    exitAnchor = gone
                }
                remaining = D3DMetalGpuSettle.remaining(
                    processJustExitedAt: exitAnchor,
                    rememberedExitAt: rememberedGpuSessionExit(
                        profileId: profile.id, bottle: bottle
                    ),
                    unrealLogMtime: logMtime()
                )
                continue
            }
            progress("Waiting for the GPU to settle (\(Int(remaining.rounded(.up)))s)…")
            let slice = min(remaining, 3)
            try await Task.sleep(nanoseconds: UInt64(slice * 1_000_000_000))
            remaining = D3DMetalGpuSettle.remaining(
                processJustExitedAt: exitAnchor,
                rememberedExitAt: rememberedGpuSessionExit(
                    profileId: profile.id, bottle: bottle
                ),
                unrealLogMtime: logMtime()
            )
        }
    }
}

private final class GpuSettleMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [String: Date] = [:]

    func get(_ id: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return dates[id]
    }

    func set(_ id: String, _ date: Date) {
        lock.lock()
        defer { lock.unlock() }
        if let previous = dates[id], previous > date { return }
        dates[id] = date
    }
}
