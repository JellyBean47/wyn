import Foundation
import Testing
@testable import WynKit

@Suite("Game catalog batch 7")
struct GameCatalogBatch7Tests {
    private let expectedSlugs: [String] = [
        "ac-origins",
        "ac-valhalla",
        "far-cry-5",
        "watch-dogs-2",
        "hitman-woa",
        "batman-arkham-knight",
        "shadow-of-war",
        "mad-max",
        "sleeping-dogs-definitive",
        "mafia-definitive"
    ]

    @Test func batch7FragmentLoadsTenGames() throws {
        let url = try #require(batch7URL())
        let games = try JSONDecoder().decode([GameCatalogEntry].self, from: Data(contentsOf: url))

        #expect(games.count == 10)
        #expect(games.allSatisfy { $0.batch == 7 })
        #expect(Set(games.map(\.slug)) == Set(expectedSlugs))
        #expect(Set(games.compactMap(\.steamAppId)).count == 10)
        #expect(games.allSatisfy { $0.profiles == ["\($0.slug).json"] })
    }

    @Test func batch7ProfilesMatchFragment() throws {
        let url = try #require(batch7URL())
        let games = try JSONDecoder().decode([GameCatalogEntry].self, from: Data(contentsOf: url))

        for game in games {
            let profile = ProfileStore.profile(id: game.slug)
            #expect(profile != nil, "missing bundled profile \(game.slug)")
            #expect(profile?.name == game.name)
            #expect(profile?.steamAppId == game.steamAppId)
        }
    }

    @Test func batch7IsMergedIntoTracker() throws {
        let url = try #require(batch7URL())
        let games = try JSONDecoder().decode([GameCatalogEntry].self, from: Data(contentsOf: url))
        let catalog = GameCatalog.load()

        for game in games {
            let tracked = catalog.entry(slug: game.slug)
            #expect(tracked != nil, "batch 7 \(game.slug) missing from tracker")
            #expect(tracked?.batch == 7)
            #expect(tracked?.steamAppId == game.steamAppId)
        }
    }

    private func batch7URL() -> URL? {
        if let bundled = Bundle.module.url(
            forResource: "batch-7",
            withExtension: "json",
            subdirectory: "Catalog/batches"
        ) {
            return bundled
        }
        if let bundled = Bundle.module.url(forResource: "batch-7", withExtension: "json") {
            return bundled
        }
        let fromSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/WynKit/Resources/Catalog/batches/batch-7.json")
        return FileManager.default.fileExists(atPath: fromSource.path) ? fromSource : nil
    }
}
