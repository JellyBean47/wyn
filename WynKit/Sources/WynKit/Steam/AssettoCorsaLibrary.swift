//
//  AssettoCorsaLibrary.swift
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

/// Cars and tracks on disk. The Kunos menu that normally lists them
/// (`AssettoCorsa.exe`) does not stay up, so Play writes a session from this.
public struct AssettoCorsaCar: Sendable, Equatable {
    public var id: String
    public var name: String
    public var brand: String?
    /// False for Steam DLC shop windows: `ui/` only, no `data.acd` / `.kn5`.
    public var playable: Bool

    public var displayName: String {
        if let brand, !brand.isEmpty, !name.lowercased().hasPrefix(brand.lowercased()) {
            return "\(brand) \(name)"
        }
        return name
    }
}

public struct AssettoCorsaTrack: Sendable, Equatable {
    public var id: String
    public var layout: String
    public var name: String

    public var token: String {
        layout.isEmpty ? id : "\(id)/\(layout)"
    }
}

public enum AssettoCorsaLibrary {
    public static func cars(in installRoot: URL) -> [AssettoCorsaCar] {
        let root = installRoot.appending(path: "content").appending(path: "cars")
        let dirs = directories(in: root)
        return dirs.map { dir in
            let ui = dir.appending(path: "ui")
            let json = ui.appending(path: "ui_car.json")
            let dlc = ui.appending(path: "dlc_ui_car.json")
            let name = jsonString(json, key: "name")
                ?? jsonString(dlc, key: "name")
                ?? dir.lastPathComponent
            let brand = jsonString(json, key: "brand") ?? jsonString(dlc, key: "brand")
            return AssettoCorsaCar(
                id: dir.lastPathComponent,
                name: name,
                brand: brand,
                playable: carHasSimFiles(at: dir)
            )
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public static func tracks(in installRoot: URL) -> [AssettoCorsaTrack] {
        let root = installRoot.appending(path: "content").appending(path: "tracks")
        var result: [AssettoCorsaTrack] = []
        for dir in directories(in: root) {
            let ui = dir.appending(path: "ui")
            let defaultJSON = ui.appending(path: "ui_track.json")
            let layouts = directories(in: ui).filter {
                FileManager.default.fileExists(
                    atPath: $0.appending(path: "ui_track.json").path(percentEncoded: false)
                )
            }
            if FileManager.default.fileExists(atPath: defaultJSON.path(percentEncoded: false)) {
                let name = jsonString(defaultJSON, key: "name") ?? dir.lastPathComponent
                result.append(AssettoCorsaTrack(id: dir.lastPathComponent, layout: "", name: name))
            }
            for layoutDir in layouts {
                let json = layoutDir.appending(path: "ui_track.json")
                let name = jsonString(json, key: "name") ?? layoutDir.lastPathComponent
                result.append(
                    AssettoCorsaTrack(
                        id: dir.lastPathComponent,
                        layout: layoutDir.lastPathComponent,
                        name: name
                    )
                )
            }
        }
        return result.sorted { $0.token.localizedCaseInsensitiveCompare($1.token) == .orderedAscending }
    }

    public static func matchCar(_ query: String, in cars: [AssettoCorsaCar]) -> AssettoCorsaCar? {
        match(query, in: cars, id: \.id, names: { [$0.id, $0.name, $0.displayName] })
    }

    public static func matchTrack(_ query: String, in tracks: [AssettoCorsaTrack]) -> AssettoCorsaTrack? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("/") {
            let parts = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            let id = String(parts[0])
            let layout = parts.count > 1 ? String(parts[1]) : ""
            if let exact = tracks.first(where: {
                $0.id.caseInsensitiveCompare(id) == .orderedSame
                    && $0.layout.caseInsensitiveCompare(layout) == .orderedSame
            }) {
                return exact
            }
        }
        return match(query, in: tracks, id: \.token, names: { [$0.token, $0.id, $0.name] })
    }

    public static func session(
        from base: AssettoCorsaSession,
        car: AssettoCorsaCar? = nil,
        track: AssettoCorsaTrack? = nil,
        aiCount: Int? = nil,
        aiAggression: Int? = nil
    ) -> AssettoCorsaSession {
        var next = base
        if let car { next.car = car.id }
        if let track {
            next.track = track.id
            next.layout = track.layout
        }
        if let aiCount { next.aiCount = aiCount }
        if let aiAggression { next.aiAggression = aiAggression }
        return next
    }

    private static func match<T>(
        _ query: String,
        in items: [T],
        id: (T) -> String,
        names: (T) -> [String]
    ) -> T? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        if let exact = items.first(where: { id($0).caseInsensitiveCompare(q) == .orderedSame }) {
            return exact
        }
        let hits = items.filter { item in
            names(item).contains { $0.localizedCaseInsensitiveContains(q) }
        }
        if hits.count == 1 { return hits[0] }
        if let exactName = hits.first(where: {
            names($0).contains { $0.caseInsensitiveCompare(q) == .orderedSame }
        }) {
            return exactName
        }
        return nil
    }

    private static func directories(in root: URL) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path(percentEncoded: false)) else {
            return []
        }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        }
        .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func jsonString(_ url: URL, key: String) -> String? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = object[key] as? String,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        let pattern = "\"\(NSRegularExpression.escapedPattern(for: key))\"\\s*:\\s*\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let valueRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        let value = String(text[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    public enum PickError: Error, LocalizedError, Equatable {
        case unknownCar(String)
        case unknownTrack(String)
        case ambiguousCar(String, [String])
        case ambiguousTrack(String, [String])
        case dlcCar(String)
        case notAssettoCorsa

        public var errorDescription: String? {
            switch self {
            case .unknownCar(let query):
                return "No Assetto Corsa car matches \"\(query)\". Try: wyn ac list-cars --query \(query)"
            case .unknownTrack(let query):
                return "No Assetto Corsa track matches \"\(query)\". Try: wyn ac list-tracks"
            case .ambiguousCar(let query, let ids):
                let shown = ids.prefix(12).joined(separator: ", ")
                return "Several cars match \"\(query)\": \(shown). Pass the id from: wyn ac list-cars --query \(query)"
            case .ambiguousTrack(let query, let ids):
                let shown = ids.prefix(12).joined(separator: ", ")
                return "Several tracks match \"\(query)\": \(shown). Pass id or id/layout from: wyn ac list-tracks"
            case .dlcCar(let id):
                return "\(id) is a Steam DLC stub (no meshes). Install it in Steam, or pick from: wyn ac list-cars"
            case .notAssettoCorsa:
                return "That profile is not Assetto Corsa."
            }
        }
    }

    public static func applyingOverrides(
        to profile: GameProfile,
        installRoot: URL,
        car: String?,
        track: String?,
        aiCount: Int?,
        aiAggression: Int?
    ) throws -> GameProfile {
        guard profile.id == "assetto-corsa" || profile.assettoCorsa != nil else {
            throw PickError.notAssettoCorsa
        }
        var next = profile
        var session = profile.assettoCorsa ?? .playableDefault
        if let car {
            session.car = try requireCar(car, in: cars(in: installRoot)).id
        }
        if let track {
            let resolved = try requireTrack(track, in: tracks(in: installRoot))
            session.track = resolved.id
            session.layout = resolved.layout
        }
        if let aiCount { session.aiCount = aiCount }
        if let aiAggression { session.aiAggression = aiAggression }
        next.assettoCorsa = session
        return next
    }

    static func requireCar(_ query: String, in cars: [AssettoCorsaCar]) throws -> AssettoCorsaCar {
        let installed = cars.filter(\.playable)
        if let resolved = matchCar(query, in: installed) {
            return resolved
        }
        let playableHits = namedHits(query, in: installed, names: { [$0.id, $0.name, $0.displayName] })
        if playableHits.count > 1 {
            throw PickError.ambiguousCar(query, playableHits.map(\.id))
        }
        let stubs = cars.filter { !$0.playable }
        if let stub = matchCar(query, in: stubs) {
            throw PickError.dlcCar(stub.id)
        }
        let stubHits = namedHits(query, in: stubs, names: { [$0.id, $0.name, $0.displayName] })
        if stubHits.count == 1 {
            throw PickError.dlcCar(stubHits[0].id)
        }
        if stubHits.count > 1 {
            throw PickError.dlcCar(query)
        }
        throw PickError.unknownCar(query)
    }

    /// Real sim files, not a Kunos shop-window folder (`ui/` + `dlc_ui_car.json`).
    public static func carHasSimFiles(at dir: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appending(path: "data.acd").path(percentEncoded: false)) {
            return true
        }
        var isDir: ObjCBool = false
        if fm.fileExists(
            atPath: dir.appending(path: "data").path(percentEncoded: false),
            isDirectory: &isDir
        ), isDir.boolValue {
            return true
        }
        let urls = (try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.contains { $0.pathExtension.lowercased() == "kn5" }
    }

    static func requireTrack(_ query: String, in tracks: [AssettoCorsaTrack]) throws -> AssettoCorsaTrack {
        if let resolved = matchTrack(query, in: tracks) {
            return resolved
        }
        let hits = namedHits(query, in: tracks, names: { [$0.token, $0.id, $0.name] })
        if hits.count > 1 {
            throw PickError.ambiguousTrack(query, hits.map(\.token))
        }
        throw PickError.unknownTrack(query)
    }

    private static func namedHits<T>(_ query: String, in items: [T], names: (T) -> [String]) -> [T] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return items.filter { item in
            names(item).contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }
}
