//
//  DeclaredLayerNoticeTests.swift
//  WynKit
//
//  This file is part of Wyn.
//
//  Wyn is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Wyn is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Wyn.
//  If not, see https://www.gnu.org/licenses/.
//

import Foundation
import Testing
@testable import WynKit

/// A bottle was created on 5 Sep 2026 specifically to test DXMT, and the launch
/// silently gave it D3DMetal instead — builtin-only overrides, so the native
/// DXMT DLLs in that bottle's system32 were never consulted. The crash that
/// followed was very nearly recorded as a DXMT result. Nothing in the output
/// said the declared layer had been overridden.
///
/// The notice was right about that run and wrong about the reason. It blamed
/// the game-host tree, and the tree was never the obstacle: DXMT's meson
/// `wine_builtin_dll` default stamped its DLLs as builtins, so Wine's
/// `load_builtin()` rewrote `=n,b` into `=b,n` and searched the tree first.
/// Rebuilt with `-Dwine_builtin_dll=false`, both layers run on that one tree —
/// Solarpunk did, on the same bottle and files, forty minutes apart. These
/// tests are updated to the corrected fact.
@Suite("Declared layer notice")
struct DeclaredLayerNoticeTests {

    /// The 6 Sep correction, pinned. One tree, one bottle, one Steam install,
    /// layer chosen per launch by WINEDLLOVERRIDES — so this combination is no
    /// longer worth a warning, and a warning that fires on a working setup is
    /// how the real ones stop being read.
    @Test func aDxmtBottleOnTheGameHostTreeIsFine() {
        #expect(DeclaredLayerNotice.message(declared: .dxmt, tree: .gameHost) == nil)
    }

    /// Still called out: DXVK on the game-host tree has never been
    /// demonstrated. Unproven is exactly what this notice is for.
    @Test func aDxvkBottleOnTheGameHostTreeIsCalledOut() {
        let notice = DeclaredLayerNotice.message(declared: .dxvk, tree: .gameHost)
        let text = try? #require(notice)
        #expect(text?.contains("declares") == true)
        #expect(text?.lowercased().contains("adapter") == true)
    }

    /// And the reverse: a d3dmetal bottle rolled back to frankea cannot get
    /// D3DMetal either, which is the trap the 5 Sep handover's §1 describes.
    @Test func aD3DMetalBottleOnFrankeaIsCalledOut() {
        #expect(DeclaredLayerNotice.message(declared: .d3dMetal, tree: .frankea) != nil)
    }

    /// Silence when they agree.
    @Test func matchingLayerAndTreeSayNothing() {
        #expect(DeclaredLayerNotice.message(declared: .d3dMetal, tree: .gameHost) == nil)
        #expect(DeclaredLayerNotice.message(declared: .dxmt, tree: .frankea) == nil)
        #expect(DeclaredLayerNotice.message(declared: .dxvk, tree: .frankea) == nil)
    }

    /// What each tree can deliver. The game-host entry is the whole point of
    /// the 6 Sep work: it carries both, and `=b` versus `=n` picks one.
    @Test func theGameHostTreeCarriesBothD3DMetalAndDXMT() {
        #expect(DeclaredLayerNotice.layers(on: .gameHost).contains(.d3dMetal))
        #expect(DeclaredLayerNotice.layers(on: .gameHost).contains(.dxmt))
        #expect(!DeclaredLayerNotice.layers(on: .gameHost).contains(.dxvk))
        #expect(DeclaredLayerNotice.layers(on: .frankea).contains(.dxmt))
        #expect(DeclaredLayerNotice.layers(on: .frankea).contains(.dxvk))
        #expect(!DeclaredLayerNotice.layers(on: .frankea).contains(.d3dMetal))
    }
}
