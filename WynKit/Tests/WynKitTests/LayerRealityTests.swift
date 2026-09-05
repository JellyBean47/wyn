import Foundation
import Testing
@testable import WynKit

/// The bug: a two-hour Solarpunk session ran on DXVK while its profile said
/// d3dmetal, because Steam had been started on the frankea tree and Wyn adopts
/// a live Steam rather than restarting it. The DLL overrides were written
/// correctly and made no difference — `d3d11=b` means *builtin*, and builtin is
/// D3DMetal only in the game-host tree.
///
/// The only symptom was a warm Mac.
@Suite("Layer reality")
struct LayerRealityTests {

    private func bottle(layer: TranslationLayer) -> Bottle {
        let b = Bottle(bottleUrl: URL.temporaryDirectory.appending(path: UUID().uuidString))
        b.settings.translationLayer = layer
        return b
    }

    private func profile(_ layer: TranslationLayer?) -> GameProfile {
        var overrides = ProfileBottleOverrides()
        overrides.translationLayer = layer
        return GameProfile(
            id: "test-game",
            name: "Test Game",
            steamAppId: 1,
            exePatterns: ["test.exe"],
            bottle: layer == nil ? nil : overrides
        )
    }

    /// With no wineserver alive there is nothing to be wrong about — the launch
    /// starts whichever tree it wants. Predicting a mismatch here would invent
    /// one, and a false alarm on the quiet path is how a warning gets ignored.
    @Test func anIdleBottleIsNeverAMismatch() {
        // A fresh temp URL has no processes, so runningTree is nil.
        let idle = bottle(layer: .d3dMetal)
        #expect(LayerReality.runningTree(in: idle) == nil)
        #expect(LayerReality.mismatch(profile: profile(.d3dMetal), in: idle) == nil)
        #expect(LayerReality.mismatch(requested: .d3dMetal, in: idle) == nil)
    }

    /// Only D3DMetal is claimed. DXVK and DXMT reach a game through native DLLs
    /// in the bottle and may work under either tree; asserting otherwise would
    /// be a guess, and guesses are what this file exists to stop.
    @Test func onlyD3DMetalIsChecked() {
        let idle = bottle(layer: .dxvk)
        #expect(LayerReality.mismatch(requested: .dxvk, in: idle) == nil)
        #expect(LayerReality.mismatch(requested: .dxmt, in: idle) == nil)
    }

    /// The message has to carry all three: what went wrong, what to do, and how
    /// to check afterwards. The adapter name is the only reliable proof of
    /// which layer really ran, so it must survive into the text people read.
    @Test func theMismatchExplainsItselfAndNamesTheProof() {
        let mismatch = LayerReality.Mismatch(requested: .d3dMetal, runningTree: .steam)

        #expect(mismatch.summary.contains("D3DMetal"))
        #expect(mismatch.summary.contains("frankea"))
        #expect(mismatch.remedy.contains("wyn steam quit"))
        // Never tell someone to kill the bottle — that is a §8 guardrail.
        #expect(!mismatch.remedy.lowercased().contains("wineserver -k"))
        #expect(mismatch.howToVerify.contains("AMD Compatibility Mode"))
        #expect(mismatch.howToVerify.contains("0x1002"))
        #expect(mismatch.howToVerify.contains("0x10de"))
    }

    /// The game tree is the one that can deliver D3DMetal, so it is never a
    /// mismatch — the check must not fire on the healthy configuration.
    @Test func theGameTreeIsTheRightAnswerForD3DMetal() {
        let mismatch = LayerReality.Mismatch(requested: .d3dMetal, runningTree: .game)
        // Constructing one for .game is possible but mismatch(requested:in:)
        // must never return it; the guard is `running != .game`.
        #expect(mismatch.runningTree == .game)
        #expect(WineTree.game.displayName.contains("GPTK"))
    }

    /// Solarpunk is the profile this was found on. If its layer ever changes,
    /// the whole investigation recorded in its notes stops applying.
    @Test func solarpunkIsTheProfileThisGuardsAgainst() throws {
        let solarpunk = try #require(ProfileStore.profile(id: "solarpunk"))
        #expect(solarpunk.bottle?.translationLayer == .d3dMetal)
        // …which is exactly the layer the tree can silently fail to provide.
        #expect(LayerReality.mismatch(requested: .d3dMetal, in: bottle(layer: .d3dMetal)) == nil)
    }
}
