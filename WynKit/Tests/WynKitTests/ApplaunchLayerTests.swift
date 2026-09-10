import Foundation
import Testing
@testable import WynKit

/// Three ways a game's declared layer used to be lost on the way to the
/// prefix. Each one was measured, not guessed — see
/// `wyn-handovers/FINDING-20260911-tree-switch-corrupts-prefix.md`.
@Suite("A game's declared layer survives to the prefix")
struct ApplaunchLayerTests {

    private func makeBottle(layer: TranslationLayer) -> Bottle {
        let bottle = Bottle(bottleUrl: URL.temporaryDirectory.appending(path: UUID().uuidString))
        bottle.settings.translationLayer = layer
        return bottle
    }

    private func profile(_ overrides: ProfileBottleOverrides) -> GameProfile {
        GameProfile(id: "test-title", name: "Test Title", bottle: overrides)
    }

    // MARK: - ProfileApplicator

    /// `BottleSettings.dxvk`'s setter rewrites the layer: `false` on a `.dxvk`
    /// bottle sends it to `.dxmt`. `apply` wrote `translationLayer` and then
    /// `dxvk`, so a profile naming DXVK while carrying `dxvk: false` undid its
    /// own choice. Four shipped profiles are shaped exactly like this.
    @Test func aProfileNamingDXVKKeepsItWhenTheLegacyFlagSaysFalse() {
        let bottle = makeBottle(layer: .d3dMetal)
        ProfileApplicator.apply(
            profile: profile(ProfileBottleOverrides(translationLayer: .dxvk, dxvk: false)),
            to: bottle
        )
        #expect(bottle.settings.translationLayer == .dxvk)
    }

    /// The boolean is still the answer when the profile names no layer — that
    /// is the only case it was ever for.
    @Test func theLegacyFlagStillDecidesWhenNoLayerIsNamed() {
        let bottle = makeBottle(layer: .dxmt)
        ProfileApplicator.apply(profile: profile(ProfileBottleOverrides(dxvk: true)), to: bottle)
        #expect(bottle.settings.translationLayer == .dxvk)
    }

    /// The guard that catches the next one: every shipped profile that names a
    /// layer must still be on that layer after `apply`. `no-mans-sky`,
    /// `doom-eternal`, `detroit-become-human` and `enshrouded` all failed this.
    @Test func everyShippedProfileKeepsTheLayerItNames() {
        for profile in ProfileStore.loadAll() {
            guard let declared = profile.bottle?.translationLayer else { continue }
            let bottle = makeBottle(layer: declared == .dxmt ? .d3dMetal : .dxmt)
            ProfileApplicator.apply(profile: profile, to: bottle)
            #expect(
                bottle.settings.translationLayer == declared,
                "\(profile.id) declares \(declared.rawValue) but applied \(bottle.settings.translationLayer.rawValue)"
            )
        }
    }

    // MARK: - Wine.deployLayer

    /// A layer named for this launch is final. `launchGameViaSteam` named none,
    /// so a DXVK title on a `.d3dMetal` bottle had the DXMT payload written
    /// into `system32` under it.
    @Test func anExplicitOverrideIsNeverCoerced() {
        for layer in TranslationLayer.allCases {
            let deployed = Wine.deployLayer(
                resolved: layer, tree: .steam, hasExplicitOverride: true, useWineBuiltinD3D: false
            )
            #expect(deployed == layer)
        }
    }

    /// The safety net stays: frankea Wine has no D3DMetal stubs, so a bottle
    /// default of `.d3dMetal` reaching the Steam tree unnamed still lands on DXMT.
    @Test func anUnnamedD3DMetalBottleStillFallsBackToDXMTOnTheSteamTree() {
        let deployed = Wine.deployLayer(
            resolved: .d3dMetal, tree: .steam, hasExplicitOverride: false, useWineBuiltinD3D: false
        )
        #expect(deployed == .dxmt)
    }

    /// And it is scoped to that one case — DXVK and DXMT are not touched, and
    /// the game tree is not touched at all.
    @Test func nothingElseIsCoerced() {
        #expect(
            Wine.deployLayer(
                resolved: .dxvk, tree: .steam, hasExplicitOverride: false, useWineBuiltinD3D: false
            ) == .dxvk
        )
        #expect(
            Wine.deployLayer(
                resolved: .d3dMetal, tree: .game, hasExplicitOverride: false, useWineBuiltinD3D: false
            ) == .d3dMetal
        )
    }

    /// `useWineBuiltinD3D` deploys nothing, so it never coerces either.
    @Test func wineBuiltinD3DDeploysWhatItWasGiven() {
        #expect(
            Wine.deployLayer(
                resolved: .d3dMetal, tree: .steam, hasExplicitOverride: false, useWineBuiltinD3D: true
            ) == .d3dMetal
        )
    }
}
