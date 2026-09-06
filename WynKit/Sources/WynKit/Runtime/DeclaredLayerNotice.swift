//
//  DeclaredLayerNotice.swift
//  WynKit
//
//  Say when a launch cannot give a bottle the layer it declares.
//
//  A bottle records a `translationLayer`. A launch picks a Wine *tree*, and the
//  tree bounds what the game can get.
//
//  On 5 September a bottle was created specifically to test DXMT:
//
//      wyn create Steam-DXMT --graphics dxmt
//      wyn steam launch --bottle Steam-DXMT
//
//  and the launch log read:
//
//      Bottle Name:       Steam-DXMT
//      Translation Layer: d3dmetal
//      WINEDLLOVERRIDES = "d3d11,dxgi,d3d12,d3d10,...=b"
//
//  Builtin-only overrides, so the native DXMT DLLs sitting in that bottle's
//  system32 were never even consulted — `=b` means do not look at native DLLs.
//  The game came up on D3DMetal and crashed, and the crash was recorded against
//  DXMT until someone read the adapter string. An entire test measured the
//  wrong thing.
//
//  CORRECTED 6 September 2026. This file used to say the game-host tree gives
//  D3DMetal and nothing else, because its unix `d3d11.so`/`dxgi.so` point at
//  libd3dshared. That is true of the *builtin* path and was mistaken for a
//  property of the tree. DXMT ships native PEs, which `=n` selects without
//  consulting a single `.so`, so one tree serves both layers and the override
//  string alone decides. Solarpunk ran on the same tree, same bottle and same
//  files forty minutes apart: `AMD Compatibility Mode` / `1002` under
//  `d3d11,dxgi,…=b`, and `Apple M4` / `106b` under `dxgi,d3d11,d3d10core=n,b`.
//
//  What defeated `=n` before was not the tree. DXMT's meson `wine_builtin_dll`
//  defaults to true, stamping `"Wine builtin DLL"` at offset 0x40, and Wine's
//  `load_builtin()` rewrites `=n,b` into `=b,n` when it sees that marker — so
//  D3DMetal won and the tree took the blame. Built with
//  `-Dwine_builtin_dll=false`, `=n` matches.
//
//  So the notice below now fires on genuinely unavailable combinations only,
//  and DXMT on the game-host tree is no longer one of them.
//
//  This is the same failure as LayerReality (#49), from the other direction.
//  That guard asks whether a d3dmetal profile is about to be silently
//  downgraded on a live frankea Steam. This one asks whether a dxmt or dxvk
//  bottle is about to be silently upgraded to D3DMetal by the tree it launches
//  on. Neither of them makes the launch do something different — they make it
//  say what it is doing.
//

import Foundation

public enum DeclaredLayerNotice {

    /// The Wine tree a launch will use.
    public enum Tree: Sendable, Equatable {
        /// GPTK-aware `Libraries/` — d3d*.so point at libd3dshared.
        case gameHost
        /// `Libraries.steam` (frankea) — wine-native d3d, so DXMT/DXVK.
        case frankea

        public var displayName: String {
            switch self {
            case .gameHost: return "game-host Wine (Libraries/)"
            case .frankea: return "frankea Wine (Libraries.steam)"
            }
        }
    }

    /// What a tree can actually deliver.
    ///
    /// Deliberately not "what the bottle asked for": this is a property of what
    /// is on disk, not of any bottle.
    ///
    /// The game-host tree delivers **both** D3DMetal and DXMT — its builtins are
    /// libd3dshared, and DXMT's natives sit in the bottle's `system32`
    /// alongside, selected by `=n`. Demonstrated end to end on 6 Sep 2026.
    ///
    /// DXVK stays off this list for the game-host tree because it has not been
    /// demonstrated there, not because it is known to fail — an unproven
    /// combination is exactly what this notice exists to flag.
    public static func layers(on tree: Tree) -> [TranslationLayer] {
        switch tree {
        case .gameHost: return [.d3dMetal, .dxmt]
        case .frankea: return [.dxmt, .dxvk]
        }
    }

    /// A sentence to print when the tree cannot give the bottle what it
    /// declares, or nil when they agree.
    ///
    /// Returning nil for the healthy case on purpose: a warning that fires on
    /// every launch is one nobody reads.
    public static func message(declared: TranslationLayer, tree: Tree) -> String? {
        let available = layers(on: tree)
        guard !available.contains(declared) else { return nil }

        let got = available.map(\.displayName).joined(separator: " or ")
        return """
        NOTE: this bottle declares \(declared.displayName), but launching on \
        \(tree.displayName) gives \(got) — that tree has no \
        \(declared.displayName) payload to select, so the override string cannot \
        reach one. Check the adapter in the game's log before treating this run \
        as evidence about \(declared.displayName).
        """
    }
}
