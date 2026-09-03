import Foundation
import Testing
@testable import WynKit

@Suite("Game catalog batch 6")
struct GameCatalogBatch6Tests {
    private let expectedSlugs: [String] = [
        "dark-souls-remastered",
        "dark-souls-2-scholar",
        "armored-core-6",
        "nioh-2",
        "devil-may-cry-5",
        "nier-automata",
        "fallout-new-vegas",
        "oblivion",
        "kotor",
        "mass-effect-legendary-edition"
    ]

    @Test func batch6FragmentLoadsTenGames() throws {
        let url = try #require(batch6URL())
        let games = try JSONDecoder().decode([GameCatalogEntry].self, from: Data(contentsOf: url))

        #expect(games.count == 10)
        #expect(games.allSatisfy { $0.batch == 6 })
        #expect(Set(games.map(\.slug)) == Set(expectedSlugs))
        #expect(Set(games.compactMap(\.steamAppId)).count == 10)
        #expect(games.allSatisfy { $0.profiles == ["\($0.slug).json"] })
    }

    @Test func batch6ProfilesMatchFragment() throws {
        let url = try #require(batch6URL())
        let games = try JSONDecoder().decode([GameCatalogEntry].self, from: Data(contentsOf: url))

        for game in games {
            let profile = ProfileStore.profile(id: game.slug)
            #expect(profile != nil, "missing bundled profile \(game.slug)")
            #expect(profile?.name == game.name)
            #expect(profile?.steamAppId == game.steamAppId)
        }
    }

    private func batch6URL() -> URL? {
        if let bundled = Bundle.module.url(
            forResource: "batch-6",
            withExtension: "json",
            subdirectory: "Catalog/batches"
        ) {
            return bundled
        }
        if let bundled = Bundle.module.url(forResource: "batch-6", withExtension: "json") {
            return bundled
        }
        let fromSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/WynKit/Resources/Catalog/batches/batch-6.json")
        return FileManager.default.fileExists(atPath: fromSource.path) ? fromSource : nil
    }
}
