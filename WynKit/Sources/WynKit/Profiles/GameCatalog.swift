//
//  GameCatalog.swift
//  WynKit
//
//  Canonical unique-game index. Runtime launch settings still live in
//  Resources/Profiles/*.json; this file is how we know a *game* is already
//  added so later batches never duplicate it. Profile variants (e.g.
//  satisfactory-esync) hang off the same slug and do not count as a new game.
//

import Foundation
import os.log

/// Bundled unique-game tracker (`Resources/Catalog/game-catalog.json`).
public enum GameCatalog {
    public static let resourceFileName = "game-catalog.json"
    public static let bundledDirectory = "Catalog"

    public static func resourceURL() -> URL? {
        Bundle.module.url(
            forResource: "game-catalog",
            withExtension: "json",
            subdirectory: bundledDirectory
        ) ?? Bundle.module.url(forResource: "game-catalog", withExtension: "json")
    }

    /// True for JSON that should decode as `GameProfile` (skips this tracker).
    public static func isProfileResource(_ url: URL) -> Bool {
        url.lastPathComponent != resourceFileName
    }

    public static func load() -> GameCatalogDocument {
        guard let url = resourceURL() else {
            Logger.wynKit.error("game-catalog.json is missing from the WynKit bundle")
            return GameCatalogDocument()
        }
        do {
            return try JSONDecoder().decode(GameCatalogDocument.self, from: Data(contentsOf: url))
        } catch {
            Logger.wynKit.error("Failed to decode game-catalog.json: \(error)")
            return GameCatalogDocument()
        }
    }

    public static func contains(slug: String) -> Bool {
        load().contains(slug: slug)
    }

    public static func contains(steamAppId: Int) -> Bool {
        load().contains(steamAppId: steamAppId)
    }
}

public struct GameCatalogDocument: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var uniqueness: String
    public var games: [GameCatalogEntry]

    public init(
        schemaVersion: Int = 1,
        uniqueness: String = "",
        games: [GameCatalogEntry] = []
    ) {
        self.schemaVersion = schemaVersion
        self.uniqueness = uniqueness
        self.games = games
    }

    public func contains(slug: String) -> Bool {
        games.contains { $0.slug == slug }
    }

    public func contains(steamAppId: Int) -> Bool {
        games.contains { $0.steamAppId == steamAppId }
    }

    public func entry(slug: String) -> GameCatalogEntry? {
        games.first { $0.slug == slug }
    }

    /// Collision against an already-tracked game. Variants of a tracked slug
    /// should reuse that slug rather than calling this with a new one.
    public func collision(
        slug: String,
        steamAppId: Int? = nil,
        epicId: String? = nil,
        gogId: String? = nil
    ) -> GameCatalogCollision? {
        for game in games {
            if game.slug == slug {
                return .slug(slug)
            }
            if let steamAppId, let existing = game.steamAppId, existing == steamAppId {
                return .steamAppId(steamAppId)
            }
            if let epicId, let existing = game.epicId, existing == epicId {
                return .epicId(epicId)
            }
            if let gogId, let existing = game.gogId, existing == gogId {
                return .gogId(gogId)
            }
        }
        return nil
    }

    /// Duplicate slugs / store IDs inside the tracker itself.
    public func uniquenessIssues() -> [String] {
        var issues: [String] = []
        var slugs: [String: Int] = [:]
        var steam: [Int: String] = [:]
        var epic: [String: String] = [:]
        var gog: [String: String] = [:]

        for game in games {
            if slugs[game.slug] != nil {
                issues.append("duplicate slug \(game.slug)")
            }
            slugs[game.slug] = game.batch

            if let id = game.steamAppId {
                if let other = steam[id] {
                    issues.append("duplicate steamAppId \(id) (\(other) and \(game.slug))")
                }
                steam[id] = game.slug
            }
            if let id = game.epicId, !id.isEmpty {
                if let other = epic[id] {
                    issues.append("duplicate epicId \(id) (\(other) and \(game.slug))")
                }
                epic[id] = game.slug
            }
            if let id = game.gogId, !id.isEmpty {
                if let other = gog[id] {
                    issues.append("duplicate gogId \(id) (\(other) and \(game.slug))")
                }
                gog[id] = game.slug
            }
        }
        return issues
    }
}

public struct GameCatalogEntry: Codable, Sendable, Identifiable, Equatable {
    public var slug: String
    public var name: String
    public var publisher: String?
    public var steamAppId: Int?
    public var epicId: String?
    public var gogId: String?
    /// Bundled profile filenames (`satisfactory.json`, variants included).
    public var profiles: [String]
    /// 0 = already in the tree when the tracker was created; 1+ = later batches of 10.
    public var batch: Int

    public var id: String { slug }

    public init(
        slug: String,
        name: String,
        publisher: String? = nil,
        steamAppId: Int? = nil,
        epicId: String? = nil,
        gogId: String? = nil,
        profiles: [String],
        batch: Int
    ) {
        self.slug = slug
        self.name = name
        self.publisher = publisher
        self.steamAppId = steamAppId
        self.epicId = epicId
        self.gogId = gogId
        self.profiles = profiles
        self.batch = batch
    }
}

public enum GameCatalogCollision: Equatable, Sendable {
    case slug(String)
    case steamAppId(Int)
    case epicId(String)
    case gogId(String)
}
