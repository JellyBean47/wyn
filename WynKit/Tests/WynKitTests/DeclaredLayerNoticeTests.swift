import Foundation
import Testing
@testable import WynKit

/// A bottle was created on 5 Sep 2026 specifically to test DXMT, and the launch
/// silently gave it D3DMetal instead — builtin-only overrides, so the native
/// DXMT DLLs in that bottle's system32 were never consulted. The crash that
/// followed was very nearly recorded as a DXMT result. Nothing in the output
/// said the declared layer had been overridden.
@Suite("Declared layer notice")
struct DeclaredLayerNoticeTests {

    /// The bug, exactly: dxmt bottle, game-host tree.
    @Test func aDxmtBottleOnTheGameHostTreeIsCalledOut() {
        let notice = DeclaredLayerNotice.message(declared: .dxmt, tree: .gameHost)
        let text = try? #require(notice)
        #expect(text?.contains("declares") == true)
        #expect(text?.lowercased().contains("adapter") == true)
    }

    @Test func aDxvkBottleOnTheGameHostTreeIsCalledOutToo() {
        #expect(DeclaredLayerNotice.message(declared: .dxvk, tree: .gameHost) != nil)
    }

    /// And the reverse: a d3dmetal bottle rolled back to frankea cannot get
    /// D3DMetal either, which is the trap the 5 Sep handover's §1 describes.
    @Test func aD3DMetalBottleOnFrankeaIsCalledOut() {
        #expect(DeclaredLayerNotice.message(declared: .d3dMetal, tree: .frankea) != nil)
    }

    /// Silence when they agree. A notice that prints on every launch stops
    /// being read, which is how the layer trap survived this long.
    @Test func matchingLayerAndTreeSayNothing() {
        #expect(DeclaredLayerNotice.message(declared: .d3dMetal, tree: .gameHost) == nil)
        #expect(DeclaredLayerNotice.message(declared: .dxmt, tree: .frankea) == nil)
        #expect(DeclaredLayerNotice.message(declared: .dxvk, tree: .frankea) == nil)
    }

    /// What each tree can deliver is a property of the filesystem — the unix
    /// d3d entries are one machine-wide pointer — not of any bottle. Pinned
    /// because it is the fact the whole notice rests on.
    @Test func theGameHostTreeOnlyEverGivesD3DMetal() {
        #expect(DeclaredLayerNotice.layers(on: .gameHost) == [.d3dMetal])
        #expect(DeclaredLayerNotice.layers(on: .frankea).contains(.dxmt))
        #expect(DeclaredLayerNotice.layers(on: .frankea).contains(.dxvk))
        #expect(!DeclaredLayerNotice.layers(on: .frankea).contains(.d3dMetal))
    }
}
