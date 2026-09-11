import Foundation
import Testing
@testable import WynKit

/// One bottle is shared by every game, so anything a launch writes into it
/// becomes the next game's default. Measured 2026-09-11: Fallout: New Vegas
/// declared `dxvk`, launched as `dxvk`, and left the bottle on `dxmt` — the
/// Steam client profile's layer, applied to the same bottle by the cold
/// restart. Army Men, which declares no layer, would then have inherited it.
/// See `wyn-handovers/FINDING-20260911-taskb-legs.md`.
@Suite("A launch does not redefine the bottle's default")
struct BottleKeepsItsDefaultTests {

    private func makeBottle(layer: TranslationLayer, windows: WinVersion = .win10) -> Bottle {
        let bottle = Bottle(bottleUrl: URL.temporaryDirectory.appending(path: UUID().uuidString))
        bottle.settings.translationLayer = layer
        bottle.settings.windowsVersion = windows
        return bottle
    }

    private func profile(_ overrides: ProfileBottleOverrides, id: String = "test-title") -> GameProfile {
        GameProfile(id: id, name: "Test Title", bottle: overrides)
    }

    // MARK: - The layer

    @Test func aProfilesLayerReachesTheLaunchWithoutTouchingTheBottle() {
        let bottle = makeBottle(layer: .d3dMetal)
        let dxvkTitle = profile(ProfileBottleOverrides(translationLayer: .dxvk))

        let settings = ProfileApplicator.launchSettings(profile: dxvkTitle, bottle: bottle)

        #expect(settings.translationLayer == .dxvk)
        #expect(bottle.settings.translationLayer == .d3dMetal)
    }

    @Test func theLayerIsPassedToWineAsALaunchOverride() {
        let bottle = makeBottle(layer: .d3dMetal)
        let override = ProfileApplicator.launchLayerOverride(
            profile: profile(ProfileBottleOverrides(translationLayer: .dxvk)),
            bottle: bottle
        )
        #expect(override == .dxvk)
    }

    /// The measured regression, in one test: the game's layer must not survive
    /// the game. Two profiles in a row on one bottle, neither leaves a mark.
    @Test func twoGamesInARowBothStartFromTheUsersDefault() {
        let bottle = makeBottle(layer: .d3dMetal)

        let newVegas = profile(ProfileBottleOverrides(translationLayer: .dxvk), id: "fallout-new-vegas")
        _ = ProfileApplicator.launchSettings(profile: newVegas, bottle: bottle)
        #expect(bottle.settings.translationLayer == .d3dMetal)

        // Army Men names no layer, so it takes the bottle's — which must still
        // be what the user chose, not what New Vegas ran with.
        let armyMen = profile(ProfileBottleOverrides(dxvk: false), id: "army-men-rts")
        let armySettings = ProfileApplicator.launchSettings(profile: armyMen, bottle: bottle)
        #expect(armySettings.translationLayer == .d3dMetal)
        #expect(bottle.settings.translationLayer == .d3dMetal)
    }

    /// `steam.json` names `dxmt` for the client. That is this launch's layer,
    /// not a new default for every game in the bottle.
    @Test func theSteamClientProfileDoesNotBecomeTheBottlesDefault() throws {
        let bottle = makeBottle(layer: .dxvk)
        let steam = try #require(ProfileStore.profile(id: "steam"))

        let override = ProfileApplicator.launchLayerOverride(profile: steam, bottle: bottle)

        #expect(override == .dxmt)
        #expect(bottle.settings.translationLayer == .dxvk)
    }

    // MARK: - Everything else the profile carries

    @Test func windowsVersionIsLaunchScopedToo() {
        let bottle = makeBottle(layer: .d3dMetal, windows: .win10)
        let armyMen = profile(ProfileBottleOverrides(windowsVersion: .winXP), id: "army-men-rts")

        let settings = ProfileApplicator.launchSettings(profile: armyMen, bottle: bottle)

        #expect(settings.windowsVersion == .winXP)
        #expect(bottle.settings.windowsVersion == .win10)
    }

    /// The profile's knobs still have to reach Wine — they travel in the
    /// environment now instead of through a write to the bottle.
    @Test func theProfilesSyncChoiceStillReachesTheEnvironment() {
        let bottle = makeBottle(layer: .d3dMetal)
        bottle.settings.enhancedSync = .none
        let program = Program(url: URL(fileURLWithPath: "/tmp/game.exe"), bottle: bottle)

        let env = ProfileApplicator.launchEnvironment(
            profile: profile(ProfileBottleOverrides(enhancedSync: .msync)),
            program: program
        )

        #expect(env["WINEMSYNC"] == "1")
        #expect(bottle.settings.enhancedSync == .none)
    }

    @Test func theProfilesLayerOverridesReachTheEnvironment() {
        let bottle = makeBottle(layer: .d3dMetal)
        let program = Program(url: URL(fileURLWithPath: "/tmp/game.exe"), bottle: bottle)

        let env = ProfileApplicator.launchEnvironment(
            profile: profile(ProfileBottleOverrides(translationLayer: .dxvk)),
            program: program
        )
        let expected = TranslationLayer.dxvk.environmentOverrides(
            dxvkHud: bottle.settings.dxvkHud, dxvkAsync: bottle.settings.dxvkAsync
        )

        for (key, value) in expected {
            #expect(env[key] == value, "\(key) should carry the profile's layer")
        }
    }

    /// A profile's own `environment` block is the last word, as before.
    @Test func theProfileEnvironmentStillWinsOverTheLayerDefaults() {
        let bottle = makeBottle(layer: .d3dMetal)
        let program = Program(url: URL(fileURLWithPath: "/tmp/game.exe"), bottle: bottle)
        let pinned = GameProfile(
            id: "test-title",
            name: "Test Title",
            bottle: ProfileBottleOverrides(translationLayer: .dxvk),
            environment: ["WINEDLLOVERRIDES": "d3d9=b"]
        )

        let env = ProfileApplicator.launchEnvironment(profile: pinned, program: program)

        #expect(env["WINEDLLOVERRIDES"] == "d3d9=b")
    }

    // MARK: - The one write that is still deliberate

    /// `wyn profiles apply <profile> <bottle>` is a user asking for the write.
    @Test func profilesApplyStillPersists() {
        let bottle = makeBottle(layer: .d3dMetal)
        ProfileApplicator.apply(
            profile: profile(ProfileBottleOverrides(translationLayer: .dxvk)),
            to: bottle
        )
        #expect(bottle.settings.translationLayer == .dxvk)
    }

    /// A profile that names no layer must not hand Wine an override: an
    /// explicit one stops `deployLayer` coercing `.d3dMetal` → `.dxmt` on the
    /// Steam tree, which is not what a silent profile asked for.
    @Test func aProfileNamingNoLayerHandsWineNoOverride() {
        let bottle = makeBottle(layer: .d3dMetal)
        let armyMen = profile(ProfileBottleOverrides(dxvk: false), id: "army-men-rts")
        #expect(ProfileApplicator.launchLayerOverride(profile: armyMen, bottle: bottle) == nil)
        #expect(ProfileApplicator.launchLayerOverride(profile: nil, bottle: bottle) == nil)
    }

    /// …but the legacy boolean still moves the layer when it genuinely differs.
    @Test func theLegacyFlagStillSpeaksWhenItActuallyChangesTheLayer() {
        let bottle = makeBottle(layer: .dxvk)
        let noDXVK = profile(ProfileBottleOverrides(dxvk: false))
        #expect(ProfileApplicator.launchLayerOverride(profile: noDXVK, bottle: bottle) == .dxmt)
    }
}
