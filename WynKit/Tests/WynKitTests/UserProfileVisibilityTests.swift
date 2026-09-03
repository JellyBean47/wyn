import Foundation
import Testing
@testable import WynKit

/// A profile the person added must reach the library.
///
/// The catalog from #40 keeps one tile per game across the profiles Wyn ships —
/// `satisfactory-esync` and friends share a slug and stay hidden. It had become
/// an allowlist, so anything without a shipped catalog slug was filtered out,
/// and every profile the MCP server writes is exactly that.
///
/// Found end-to-end: Solarpunk validated, saved, was readable by get_profile,
/// and the library still reported "no profile". The whole add-a-game feature
/// was inert and nothing failed loudly.
@Suite("User profile visibility")
struct UserProfileVisibilityTests {

    private func withUserProfile(
        id: String,
        steamAppId: Int?,
        _ body: () throws -> Void
    ) throws {
        let directory = ProfileStore.userProfilesDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(id).json")
        let existed = FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        defer { if !existed { try? FileManager.default.removeItem(at: url) } }

        try ProfileStore.save(
            profile: GameProfile(
                id: id,
                name: "Test Added Game",
                steamAppId: steamAppId,
                exePatterns: ["\(id).exe"],
                notes: "n"
            )
        )
        try body()
    }

    /// The regression itself.
    @Test func aProfileTheUserAddedAppearsInTheCatalog() throws {
        let id = "user-added-\(UUID().uuidString.prefix(8))"
        try withUserProfile(id: id, steamAppId: 999_001) {
            #expect(ProfileStore.userProfileIDs().contains(id))
            #expect(ProfileStore.profile(id: id) != nil, "loadAll must see it")
            #expect(
                GameLibrary.catalogProfiles().contains { $0.id == id },
                "a profile the person added is not in the shipped catalog, and must not be filtered out for it"
            )
        }
    }

    /// The filter still has to do its actual job: shipped variants stay hidden
    /// so one game is one tile.
    @Test func shippedVariantsAreStillDeduplicated() {
        let ids = Set(GameLibrary.catalogProfiles().map(\.id))
        #expect(ids.contains("satisfactory"))
        for variant in ["satisfactory-esync", "satisfactory-nosync", "satisfactory-perf"] {
            #expect(!ids.contains(variant), "\(variant) is a variant and should stay hidden")
        }
    }

    /// Steam's plumbing profile is not a game.
    @Test func theSteamProfileIsNeverAGame() {
        #expect(!GameLibrary.catalogProfiles().contains { $0.id == "steam" })
    }

    /// The user's directory is not a way to smuggle a bad profile past the
    /// rules — the validator still applies to everything in the library.
    @Test func addedProfilesAreStillValidated() throws {
        let id = "user-added-valid-\(UUID().uuidString.prefix(8))"
        try withUserProfile(id: id, steamAppId: 999_002) {
            let added = GameLibrary.catalogProfiles().first { $0.id == id }
            #expect(added != nil)
            if let added {
                #expect(ProfileValidator.errors(in: [added]).isEmpty)
                // And it is a guess: nothing has run it.
                #expect(LaunchRecordStore.effectiveStatus(for: added, in: []) == .guessed)
            }
        }
    }
}
