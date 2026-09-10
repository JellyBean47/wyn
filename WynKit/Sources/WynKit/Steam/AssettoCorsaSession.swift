//
//  AssettoCorsaSession.swift
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

import Foundation

/// Offline session for `acs.exe`. The Kunos menu (`AssettoCorsa.exe`) is what
/// normally writes these files; it does not stay up here, so Play writes them.
///
/// Default on this install: original Monza (`monza`, not `ks_monza` — that
/// folder is not on disk), Lotus Elise, 7 AI. Magione already loaded as a
/// one-car practice; this is a different track and a grid.
public struct AssettoCorsaSession: Codable, Sendable, Equatable {
    public var track: String
    /// `CONFIG_TRACK`. Empty for a track with one layout (Monza).
    public var layout: String
    public var car: String
    /// Opponents. Player is extra, so `CARS` is `aiCount + 1`.
    public var aiCount: Int
    /// 0–100. Official special events use 100. The 22:33 session logged
    /// `AI AGGRESSION: 0.000000` because launcher.ini had `AI_AGGRESSION=0`.
    public var aiAggression: Int

    public init(
        track: String,
        layout: String = "",
        car: String,
        aiCount: Int,
        aiAggression: Int = 100
    ) {
        self.track = track
        self.layout = layout
        self.car = car
        self.aiCount = aiCount
        self.aiAggression = aiAggression
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        track = try container.decode(String.self, forKey: .track)
        layout = try container.decodeIfPresent(String.self, forKey: .layout) ?? ""
        car = try container.decode(String.self, forKey: .car)
        aiCount = try container.decode(Int.self, forKey: .aiCount)
        aiAggression = try container.decodeIfPresent(Int.self, forKey: .aiAggression) ?? 100
    }

    /// Original Autodromo di Monza, 26 pit boxes on this install. Seven AI is
    /// a real grid without packing the first D3DMetal session.
    public static let playableDefault = AssettoCorsaSession(
        track: "monza",
        layout: "",
        car: "lotus_elise_sc",
        aiCount: 7,
        aiAggression: 100
    )
}

extension AssettoCorsaSession {
    /// Writes `cfg/race.ini` and `cfg/entry_list.ini` next to `acs.exe`, and
    /// into any bottle `Documents/Assetto Corsa/cfg` that already exists.
    ///
    /// Leaves the current files alone when the track or car is missing, so a
    /// bad profile cannot wipe the Magione session that already loaded.
    @discardableResult
    public static func write(
        _ session: AssettoCorsaSession,
        installRoot: URL,
        bottle: Bottle? = nil
    ) -> [URL] {
        guard let prepared = prepare(session, installRoot: installRoot) else {
            return []
        }
        var written: [URL] = []
        for dir in cfgDirectories(installRoot: installRoot, bottle: bottle) {
            written.append(contentsOf: write(prepared, to: dir))
            _ = persistUser(prepared.session, to: dir)
        }
        return written
    }

    /// Last `wyn ac set` / `--ac-car` pick. Play reads this so the bundled
    /// Monza profile does not wipe a car you already chose.
    public static let userSessionFileName = "wyn-session.json"

    public static func loadUser(installRoot: URL, bottle: Bottle? = nil) -> AssettoCorsaSession? {
        for dir in cfgDirectories(installRoot: installRoot, bottle: bottle) {
            let url = dir.appending(path: userSessionFileName)
            guard let data = try? Data(contentsOf: url),
                  let session = try? JSONDecoder().decode(AssettoCorsaSession.self, from: data)
            else { continue }
            return session
        }
        return nil
    }

    public static func resolved(
        declared: AssettoCorsaSession?,
        installRoot: URL,
        bottle: Bottle? = nil
    ) -> AssettoCorsaSession? {
        loadUser(installRoot: installRoot, bottle: bottle) ?? declared
    }

    /// Remember a pick without rewriting race.ini. Used when CLI flags change
    /// the session immediately before SteamLauncher writes the ini files.
    @discardableResult
    public static func persistUser(
        _ session: AssettoCorsaSession,
        installRoot: URL,
        bottle: Bottle? = nil
    ) -> [URL] {
        cfgDirectories(installRoot: installRoot, bottle: bottle).compactMap {
            persistUser(session, to: $0)
        }
    }

    static func cfgDirectories(installRoot: URL, bottle: Bottle?) -> [URL] {
        var dirs = [installRoot.appending(path: "cfg")]
        if let bottle {
            dirs.append(contentsOf: documentsCfgDirectories(in: bottle))
        }
        var seen = Set<String>()
        return dirs.filter { seen.insert($0.path(percentEncoded: false)).inserted }
    }

    static func persistUser(_ session: AssettoCorsaSession, to dir: URL) -> URL? {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: userSessionFileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(session) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    struct Prepared: Equatable {
        var session: AssettoCorsaSession
        var cars: Int
        var skins: [String]
        var raceIni: String
        var entryList: String
    }

    static func prepare(
        _ session: AssettoCorsaSession,
        installRoot: URL
    ) -> Prepared? {
        let trackDir = trackDirectory(session, installRoot: installRoot)
        let carDir = installRoot
            .appending(path: "content")
            .appending(path: "cars")
            .appending(path: session.car)
        let fm = FileManager.default
        guard fm.fileExists(atPath: trackDir.path(percentEncoded: false)),
              AssettoCorsaLibrary.carHasSimFiles(at: carDir)
        else {
            return nil
        }
        let skins = skinNames(in: carDir)
        let pits = pitboxes(in: trackDir)
        let cars = carCount(aiCount: session.aiCount, pitboxes: pits)
        return Prepared(
            session: session,
            cars: cars,
            skins: skins,
            raceIni: raceIni(session: session, cars: cars, skins: skins),
            entryList: entryList(session: session, cars: cars, skins: skins)
        )
    }

    static func carCount(aiCount: Int, pitboxes: Int) -> Int {
        let wanted = max(aiCount, 0) + 1
        let cap = max(pitboxes, 1)
        return min(wanted, cap)
    }

    static func clampedAggression(_ value: Int) -> Int {
        min(max(value, 0), 100)
    }

    static func raceIni(session: AssettoCorsaSession, cars: Int, skins: [String] = []) -> String {
        // TYPE=3 standing start is broken here: 6 Sep Monza log is
        // `Starting light should show. TTS: 1.#INF00` until the player quit.
        // Practice has no lights; the AI leave the pits.
        let aggression = clampedAggression(session.aiAggression)
        let carsIni = slots(cars: cars, skins: skins).map { slot in
            var lines = [
                "MODEL=-",
                "MODEL_CONFIG=",
                "SKIN=\(slot.skin)",
                "DRIVER_NAME=\(slot.driverName)",
                "NATIONALITY=\(slot.nationality)",
                "AI_LEVEL=90",
            ]
            if slot.isAI {
                lines.append("AI_AGGRESSION=\(aggression)")
            }
            return ("CAR_\(slot.index)", lines)
        }
        return ini([
            ("RACE", [
                "TRACK=\(session.track)",
                "CONFIG_TRACK=\(session.layout)",
                "MODEL=\(session.car)",
                "MODEL_CONFIG=",
                "CARS=\(cars)",
                "AI_LEVEL=90",
                "FIXED_SETUP=0",
                "PENALTIES=0",
            ]),
            ("SESSION_0", [
                "NAME=Practice",
                "TYPE=1",
                "DURATION_MINUTES=20",
                "SPAWN_SET=PIT",
            ]),
            ("GHOST_CAR", [
                "RECORDING=0",
                "PLAYING=0",
                "SECONDS_ADVANTAGE=0",
                "LOAD=0",
                "FILE=",
            ]),
            ("REPLAY", [
                "FILENAME=",
                "ACTIVE=0",
            ]),
            ("LIGHTING", [
                "SUN_ANGLE=-48",
                "TIME_MULT=1",
                "CLOUD_SPEED=0.2",
            ]),
            ("GROOVE", [
                "VIRTUAL_LAPS=10",
                "MAX_LAPS=30",
                "STARTING_LAPS=0",
            ]),
            ("DYNAMIC_TRACK", [
                "SESSION_START=100",
                "SESSION_TRANSFER=50",
                "RANDOMNESS=0",
                "LAP_GAIN=1",
            ]),
            ("REMOTE", [
                "ACTIVE=0",
                "SERVER_IP=",
                "SERVER_PORT=",
                "NAME=",
                "TEAM=",
                "GUID=",
                "REQUESTED_CAR=",
                "PASSWORD=",
            ]),
            ("LAP_INVALIDATOR", [
                "ALLOWED_TYRES_OUT=-1",
            ]),
            ("TEMPERATURE", [
                "AMBIENT=26",
                "ROAD=32",
            ]),
            ("WEATHER", [
                "NAME=4_mid_clear",
            ]),
        ] + carsIni)
    }

    static func entryList(session: AssettoCorsaSession, cars: Int, skins: [String]) -> String {
        let aggression = clampedAggression(session.aiAggression)
        return ini(slots(cars: cars, skins: skins).map { slot in
            var lines = [
                "MODEL=\(session.car)",
                "SKIN=\(slot.skin)",
                "DRIVER_NAME=\(slot.driverName)",
                "NATIONALITY=\(slot.nationality)",
                "AI=\(slot.isAI ? "1" : "0")",
                "AI_LEVEL=90",
                "BALLAST=0",
                "RESTRICTOR=0",
            ]
            if slot.isAI {
                lines.append("AI_AGGRESSION=\(aggression)")
            }
            return ("CAR_\(slot.index)", lines)
        })
    }

    private struct Slot {
        var index: Int
        var skin: String
        var driverName: String
        var nationality: String
        var isAI: Bool
    }

    private static func slots(cars: Int, skins: [String]) -> [Slot] {
        let playerSkin = preferredPlayerSkin(in: skins)
        let others = skins.filter { $0 != playerSkin }
        let pool = others.isEmpty ? skins : others
        return (0..<cars).map { index in
            let skin: String
            if index == 0 {
                skin = playerSkin
            } else {
                skin = pool.isEmpty ? "" : pool[(index - 1) % pool.count]
            }
            return Slot(
                index: index,
                skin: skin,
                driverName: index == 0 ? "Player" : "AI \(index)",
                nationality: index == 0 ? "ZAF" : "ITA",
                isAI: index != 0
            )
        }
    }

    static func preferredPlayerSkin(in skins: [String]) -> String {
        if let green = skins.first(where: { $0.caseInsensitiveCompare("0_racing_green") == .orderedSame }) {
            return green
        }
        return skins.first ?? ""
    }

    static func trackDirectory(_ session: AssettoCorsaSession, installRoot: URL) -> URL {
        let base = installRoot
            .appending(path: "content")
            .appending(path: "tracks")
            .appending(path: session.track)
        let layout = session.layout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !layout.isEmpty else { return base }
        let nested = base.appending(path: layout)
        if FileManager.default.fileExists(atPath: nested.path(percentEncoded: false)) {
            return nested
        }
        return base
    }

    static func pitboxes(in trackDir: URL) -> Int {
        let json = trackDir.appending(path: "ui").appending(path: "ui_track.json")
        guard let data = try? Data(contentsOf: json),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["pitboxes"]
        else {
            return 24
        }
        if let number = raw as? Int {
            return max(number, 1)
        }
        if let text = raw as? String, let number = Int(text) {
            return max(number, 1)
        }
        return 24
    }

    static func skinNames(in carDir: URL) -> [String] {
        let skins = carDir.appending(path: "skins")
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: skins,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        }
        .map(\.lastPathComponent)
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func documentsCfgDirectories(in bottle: Bottle) -> [URL] {
        let users = bottle.url.appending(path: "drive_c").appending(path: "users")
        let skipped: Set<String> = ["Public", "Default", "Default User", "All Users"]
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: users,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return dirs.compactMap { user in
            guard !skipped.contains(user.lastPathComponent) else { return nil }
            let cfg = user
                .appending(path: "Documents")
                .appending(path: "Assetto Corsa")
                .appending(path: "cfg")
            guard FileManager.default.fileExists(atPath: cfg.path(percentEncoded: false)) else {
                return nil
            }
            return cfg
        }
    }

    private static func write(_ prepared: Prepared, to cfg: URL) -> [URL] {
        let fm = FileManager.default
        try? fm.createDirectory(at: cfg, withIntermediateDirectories: true)
        let race = cfg.appending(path: "race.ini")
        let entry = cfg.appending(path: "entry_list.ini")
        let backup = cfg.appending(path: "race.ini.wynbak")
        if fm.fileExists(atPath: race.path(percentEncoded: false)),
           !fm.fileExists(atPath: backup.path(percentEncoded: false)) {
            try? fm.copyItem(at: race, to: backup)
        }
        guard writeAtomically(prepared.raceIni, to: race),
              writeAtomically(prepared.entryList, to: entry)
        else {
            return []
        }
        pinLauncherAggression(in: cfg, value: clampedAggression(prepared.session.aiAggression))
        return [race, entry]
    }

    /// The Kunos UI stores opponent hostility in `launcher.ini`, and the 22:33
    /// session logged that value as 0. Official events also put it on each AI
    /// car; both get written.
    static func pinLauncherAggression(in cfg: URL, value: Int) {
        let url = cfg.appending(path: "launcher.ini")
        guard var text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else {
            return
        }
        let line = "AI_AGGRESSION=\(value)"
        if let range = text.range(of: #"AI_AGGRESSION=\d+"#, options: .regularExpression) {
            text.replaceSubrange(range, with: line)
        } else if let saved = text.range(of: "[SAVED]") {
            let insert = text.index(saved.upperBound, offsetBy: 0)
            let breakChars = text[insert...].prefix(while: { $0 == "\r" || $0 == "\n" })
            let at = text.index(insert, offsetBy: breakChars.count)
            text.insert(contentsOf: "\(line)\(text.contains("\r\n") ? "\r\n" : "\n")", at: at)
        } else {
            return
        }
        _ = writeAtomically(text, to: url)
    }

    private static func writeAtomically(_ text: String, to url: URL) -> Bool {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    private static func ini(_ sections: [(String, [String])]) -> String {
        sections.map { name, lines in
            (["[\(name)]"] + lines).joined(separator: "\r\n")
        }
        .joined(separator: "\r\n\r\n")
        + "\r\n"
    }
}
