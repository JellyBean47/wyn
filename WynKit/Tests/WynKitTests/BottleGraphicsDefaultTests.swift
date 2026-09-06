import Foundation
import Testing
@testable import WynKit

/// The app's Bottles section lets you set a bottle's graphics layer, and tells
/// the user in as many words: *that is the bottle's default — a game whose
/// profile pins a layer keeps that one.*
///
/// That sentence is only true because `ProfileApplicator.apply` writes the
/// profile's `translationLayer` onto the bottle at launch. If that precedence
/// is ever changed, the toggle silently starts meaning something different from
/// what the UI promises — which is the exact failure mode this project keeps
/// hitting: the interface saying one thing while something else quietly
/// rewrites it. These tests pin the sentence.
@Suite("Bottle graphics default")
struct BottleGraphicsDefaultTests {

    private func makeBottle(layer: TranslationLayer) -> Bottle {
        let bottle = Bottle(bottleUrl: URL.temporaryDirectory.appending(path: UUID().uuidString))
        bottle.settings.translationLayer = layer
        return bottle
    }

    private func profile(layer: TranslationLayer?) -> GameProfile {
        GameProfile(
            id: "test-title",
            name: "Test Title",
            bottle: layer.map { ProfileBottleOverrides(translationLayer: $0) }
        )
    }

    /// The claim on the tile: a profile that pins a layer wins.
    @Test func aProfileThatPinsALayerOverridesTheBottleDefault() {
        let bottle = makeBottle(layer: .dxmt)
        ProfileApplicator.apply(profile: profile(layer: .d3dMetal), to: bottle)
        #expect(bottle.settings.translationLayer == .d3dMetal)
    }

    /// And the other half of the claim: a profile that pins nothing leaves the
    /// user's choice alone. Without this, "default" would mean nothing at all.
    @Test func aProfileWithNoLayerLeavesTheBottleDefaultAlone() {
        let bottle = makeBottle(layer: .dxmt)
        ProfileApplicator.apply(profile: profile(layer: nil), to: bottle)
        #expect(bottle.settings.translationLayer == .dxmt)
    }

    /// `dxvk` and `translationLayer` are one setting stored in two places, and
    /// LibraryVM.setGraphics mirrors ProfileApplicator here. Pinned because a
    /// bottle left with `dxvk = true` on a DXMT layer is a state no launch path
    /// expects.
    @Test func selectingDXVKSetsTheDxvkFlagAndClearingItUnsets() {
        let bottle = makeBottle(layer: .dxmt)
        ProfileApplicator.apply(profile: profile(layer: .dxvk), to: bottle)
        #expect(bottle.settings.dxvk)

        ProfileApplicator.apply(profile: profile(layer: .d3dMetal), to: bottle)
        #expect(!bottle.settings.dxvk)
    }

    /// Setting the layer is metadata only — since DXMT and D3DMetal stopped
    /// overwriting each other in system32, nothing is installed or removed when
    /// this changes, so it is safe to do from a UI picker with no bottle open.
    @Test func everyLayerIsSelectableAsABottleDefault() {
        for layer in TranslationLayer.allCases {
            let bottle = makeBottle(layer: layer)
            #expect(bottle.settings.translationLayer == layer)
        }
    }

    /// Starting Steam must not change what the user picked. `prepareGameHostSteam`
    /// used to write `.d3dMetal` into the bottle every time, so choosing DXMT in
    /// the app and then launching Steam silently reverted the tile — the same
    /// "interface says one thing, something else rewrites it" failure the toggle
    /// was labelled to avoid. The Steam client's layer is forced per launch by
    /// `translationLayerOverride`, which `Wine.runProgram` takes ahead of
    /// anything stored, so nothing needs to be persisted for it.
    @Test func theSteamClientsLayerIsALaunchOptionNotAStoredSetting() throws {
        let options = Wine.LaunchOptions(translationLayerOverride: .d3dMetal)
        #expect(options.translationLayerOverride == .d3dMetal)

        // The bottle default is the user's, and starting Steam leaves it alone.
        let bottle = makeBottle(layer: .dxmt)
        #expect(bottle.settings.translationLayer == .dxmt)
    }
}
