//
//  DeclaredLayerNotice.swift
//  WynKit
//
//  Say when a launch cannot give a bottle the layer it declares.
//
//  A bottle records a `translationLayer`. A launch picks a Wine *tree*, and the
//  tree decides what the game actually gets: the game-host tree's unix
//  `d3d11.so`/`dxgi.so`/`d3d12.so`/`d3d10.so` point at libd3dshared, so every
//  game on it renders through D3DMetal no matter what any bottle or profile
//  says. `wyn renderer` states this plainly — "if they disagree, the filesystem
//  wins" — but nothing said it at the moment it mattered.
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
    /// Deliberately not "what the bottle asked for": the unix d3d entries are a
    /// single machine-wide pointer, so this is a property of the filesystem, not
    /// of any bottle.
    public static func layers(on tree: Tree) -> [TranslationLayer] {
        switch tree {
        case .gameHost: return [.d3dMetal]
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
        \(tree.displayName) gives \(got). The d3d entries in that tree are a \
        machine-wide pointer and the bottle does not change them, so anything \
        started from here renders through \(got) whatever the bottle or profile \
        says. Check the adapter in the game's log before treating this run as \
        evidence about \(declared.displayName).
        """
    }
}
