import Foundation
import Testing
@testable import WynKit

@Suite("Game catalog batch 5")
struct GameCatalogBatch5Tests {
    private let expectedSlugs: [String] = [
        "god-of-war-ragnarok",
        "horizon-forbidden-west",
        "spider-man-miles-morales",
        "spider-man-2",
        "returnal",
        "ratchet-clank-rift-apart",
        "the-last-of-us-part-2",
        "jedi-survivor",
        "resident-evil-village",
        "resident-evil-2"
    ]

    @Test func batch5FragmentLoadsTenGames() throws {
        let url = try #require(batch5URL())
        let games = try JSONDecoder().decode([GameCatalogEntry].self, from: Data(contentsOf: url))

        #expect(games.count == 10)
        #expect(games.allSatisfy { $0.batch == 5 })
        #expect(Set(games.map(\.slug)) == Set(expectedSlugs))
        #expect(Set(games.compactMap(\.steamAppId)).count == 10)
        #expect(games.allSatisfy { $0.profiles == ["\($0.slug).json"] })
    }

    @Test func batch5ProfilesMatchFragment() throws {
        let url = try #require(batch5URL())
        let games = try JSONDecoder().decode([GameCatalogEntry].self, from: Data(contentsOf: url))

        for game in games {
            let profile = ProfileStore.profile(id: game.slug)
            #expect(profile != nil, "missing bundled profile \(game.slug)")
            #expect(profile?.name == game.name)
            #expect(profile?.steamAppId == game.steamAppId)
        }
    }

    private func batch5URL() -> URL? {
        if let bundled = Bundle.module.url(
            forResource: "batch-5",
            withExtension: "json",
            subdirectory: "Catalog/batches"
        ) {
            return bundled
        }
        if let bundled = Bundle.module.url(forResource: "batch-5", withExtension: "json") {
            return bundled
        }
        let fromSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/WynKit/Resources/Catalog/batches/batch-5.json")
        return FileManager.default.fileExists(atPath: fromSource.path) ? fromSource : nil
    }
}
