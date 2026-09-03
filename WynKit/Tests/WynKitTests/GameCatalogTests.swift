import Foundation
import Testing
@testable import WynKit

@Suite("Game catalog")
struct GameCatalogTests {
    private let backfillSlugs: Set<String> = [
        "ac-odyssey",
        "army-men-rts",
        "baldurs-gate-3",
        "cities-skylines",
        "control-ultimate",
        "cyberpunk-2077",
        "elden-ring",
        "fallout-4",
        "lethal-company",
        "no-mans-sky",
        "ready-or-not",
        "rv-there-yet",
        "satisfactory",
        "skyrim-se"
    ]

    private let batch1Slugs: Set<String> = [
        "dark-souls-3",
        "god-of-war",
        "hogwarts-legacy",
        "horizon-zero-dawn",
        "jedi-fallen-order",
        "rdr2",
        "sekiro",
        "spider-man-remastered",
        "valheim",
        "witcher-3"
    ]

    private let batch2Slugs: Set<String> = [
        "death-stranding",
        "doom-eternal",
        "ghost-of-tsushima",
        "gta-v",
        "hades",
        "hollow-knight",
        "monster-hunter-world",
        "palworld",
        "resident-evil-4",
        "stardew-valley"
    ]

    private let batch3Slugs: Set<String> = [
        "black-myth-wukong",
        "borderlands-3",
        "celeste",
        "deep-rock-galactic",
        "disco-elysium",
        "guardians-of-the-galaxy",
        "lies-of-p",
        "terraria",
        "the-last-of-us-part-1",
        "uncharted-legacy"
    ]

    private let batch4Slugs: Set<String> = [
        "a-plague-tale-requiem",
        "dead-space",
        "hades-2",
        "it-takes-two",
        "mgsv-phantom-pain",
        "outer-wilds",
        "persona-5-royal",
        "starfield",
        "superhot",
        "yakuza-0"
    ]

    private let batch5Slugs: Set<String> = [
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

    private let batch6Slugs: Set<String> = [
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

    private let batch7Slugs: Set<String> = [
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

    private let batch8Slugs: Set<String> = [
        "factorio",
        "rimworld",
        "cuphead",
        "slay-the-spire",
        "dead-cells",
        "vampire-survivors",
        "the-binding-of-isaac-rebirth",
        "risk-of-rain-2",
        "subnautica",
        "the-forest"
    ]

    private let batch9Slugs: Set<String> = [
        "detroit-become-human",
        "days-gone",
        "life-is-strange",
        "deathloop",
        "hi-fi-rush",
        "ori-and-the-will-of-the-wisps",
        "hollow-knight-silksong",
        "firewatch",
        "what-remains-of-edith-finch",
        "portal-2"
    ]

    private let batch10Slugs: Set<String> = [
        "left-4-dead-2",
        "dying-light-2",
        "sons-of-the-forest",
        "grounded",
        "enshrouded",
        "v-rising",
        "divinity-original-sin-2",
        "monster-hunter-rise",
        "dragons-dogma-2",
        "ff7-remake"
    ]

    private var laterBatchSlugs: Set<String> {
        batch1Slugs
            .union(batch2Slugs)
            .union(batch3Slugs)
            .union(batch4Slugs)
            .union(batch5Slugs)
            .union(batch6Slugs)
            .union(batch7Slugs)
            .union(batch8Slugs)
            .union(batch9Slugs)
            .union(batch10Slugs)
    }

    @Test func trackerLoadsFromBundle() {
        #expect(GameCatalog.resourceURL() != nil)
        let catalog = GameCatalog.load()
        #expect(catalog.schemaVersion == 1)
        #expect(!catalog.games.isEmpty)
    }

    @Test func uniquenessIsByGameNotVariant() {
        let catalog = GameCatalog.load()
        #expect(catalog.uniquenessIssues().isEmpty)

        let satisfactory = catalog.entry(slug: "satisfactory")
        #expect(satisfactory != nil)
        #expect((satisfactory?.profiles.count ?? 0) > 1)
        #expect(satisfactory?.profiles.contains("satisfactory-esync.json") == true)

        #expect(catalog.collision(slug: "elden-ring") == .slug("elden-ring"))
        #expect(catalog.collision(slug: "brand-new-game", steamAppId: 526870) == .steamAppId(526870))
        #expect(catalog.collision(slug: "brand-new-game", steamAppId: 1) == nil)
    }

    @Test func steamClientIsNotATrackedGame() {
        let catalog = GameCatalog.load()
        #expect(!catalog.contains(slug: "steam"))
        #expect(ProfileStore.profile(id: "steam") != nil)
        #expect(!GameLibrary.catalogProfiles().contains { $0.id == "steam" })
    }

    /// The catalog tracks the profiles Wyn *ships*, so that later batches do not
    /// duplicate a title. It says nothing about profiles the person added — and
    /// this test used to enumerate those too, so any added game failed it.
    @Test func everyBundledGameProfileIsTracked() {
        let catalog = GameCatalog.load()
        let listed = Set(catalog.games.flatMap(\.profiles))
        let userAdded = ProfileStore.userProfileIDs()
        let bundled = ProfileStore.loadAll().filter {
            $0.id != "steam" && !userAdded.contains($0.id)
        }

        for profile in bundled {
            let filename = "\(profile.id).json"
            #expect(listed.contains(filename), "profile \(filename) missing from game-catalog.json")
        }
    }

    @Test func everyCatalogEntryHasACanonicalProfile() {
        let catalog = GameCatalog.load()
        for game in catalog.games {
            let profile = ProfileStore.profile(id: game.slug)
            #expect(profile != nil, "missing profile for slug \(game.slug)")
            #expect(profile?.name == game.name)
            #expect(profile?.steamAppId == game.steamAppId)
            #expect(game.profiles.contains("\(game.slug).json"))
        }
    }

    /// Of the profiles Wyn ships, the library shows exactly the canonical slugs
    /// — one tile per game, variants hidden.
    ///
    /// Written originally as `shown == slugs`, which quietly made the catalog an
    /// allowlist: a profile the person added has no slug, so it could never be
    /// shown, and the whole add-a-game path was inert. Subtracting the added
    /// ones keeps the real invariant and lets people own their own library.
    @Test func catalogProfilesMatchCanonicalSlugs() {
        let catalog = GameCatalog.load()
        let shown = Set(GameLibrary.catalogProfiles().map(\.id))
        let userAdded = ProfileStore.userProfileIDs()
        #expect(shown.subtracting(userAdded) == Set(catalog.games.map(\.slug)))
        #expect(!shown.contains { $0.hasPrefix("satisfactory-") })
    }

    @Test func trackerIsNotDecodedAsAGameProfile() {
        #expect(ProfileStore.profile(id: "game-catalog") == nil)
        #expect(!ProfileStore.loadAll().contains { $0.id == "game-catalog" })
    }

    @Test func backfillAndFirstBatchArePresent() {
        let catalog = GameCatalog.load()
        let slugs = Set(catalog.games.map(\.slug))
        #expect(slugs.isSuperset(of: backfillSlugs))
        #expect(slugs.isSuperset(of: batch1Slugs))
        #expect(slugs.isSuperset(of: batch2Slugs))
        #expect(slugs.isSuperset(of: batch3Slugs))
        #expect(slugs.isSuperset(of: batch4Slugs))
        #expect(slugs.isSuperset(of: batch5Slugs))
        #expect(slugs.isSuperset(of: batch6Slugs))
        #expect(slugs.isSuperset(of: batch7Slugs))
        #expect(slugs.isSuperset(of: batch8Slugs))
        #expect(slugs.isSuperset(of: batch9Slugs))
        #expect(slugs.isSuperset(of: batch10Slugs))

        let batch0 = Set(catalog.games.filter { $0.batch == 0 }.map(\.slug))
        let batch1 = Set(catalog.games.filter { $0.batch == 1 }.map(\.slug))
        let batch2 = Set(catalog.games.filter { $0.batch == 2 }.map(\.slug))
        let batch3 = Set(catalog.games.filter { $0.batch == 3 }.map(\.slug))
        let batch4 = Set(catalog.games.filter { $0.batch == 4 }.map(\.slug))
        let batch5 = Set(catalog.games.filter { $0.batch == 5 }.map(\.slug))
        let batch6 = Set(catalog.games.filter { $0.batch == 6 }.map(\.slug))
        let batch7 = Set(catalog.games.filter { $0.batch == 7 }.map(\.slug))
        let batch8 = Set(catalog.games.filter { $0.batch == 8 }.map(\.slug))
        let batch9 = Set(catalog.games.filter { $0.batch == 9 }.map(\.slug))
        let batch10 = Set(catalog.games.filter { $0.batch == 10 }.map(\.slug))
        #expect(batch0 == backfillSlugs)
        #expect(batch1 == batch1Slugs)
        #expect(batch2 == batch2Slugs)
        #expect(batch3 == batch3Slugs)
        #expect(batch4 == batch4Slugs)
        #expect(batch5 == batch5Slugs)
        #expect(batch6 == batch6Slugs)
        #expect(batch7 == batch7Slugs)
        #expect(batch8 == batch8Slugs)
        #expect(batch9 == batch9Slugs)
        #expect(batch10 == batch10Slugs)
        #expect(batch1.count == 10)
        #expect(batch2.count == 10)
        #expect(batch3.count == 10)
        #expect(batch4.count == 10)
        #expect(batch5.count == 10)
        #expect(batch6.count == 10)
        #expect(batch7.count == 10)
        #expect(batch8.count == 10)
        #expect(batch9.count == 10)
        #expect(batch10.count == 10)
        #expect(catalog.games.count == 114)
    }

    @Test func newBatchProfilesLoad() {
        for slug in laterBatchSlugs {
            #expect(ProfileStore.profile(id: slug) != nil, "missing bundled profile \(slug)")
        }
    }
}
