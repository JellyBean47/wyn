//
//  LayerReality.swift
//  WynKit
//
//  Whether the bottle can actually give a game the translation layer its
//  profile asks for — right now, in the state the machine is in.
//
//  A profile naming `d3dmetal` does not make D3DMetal happen. The layer is
//  decided by which Wine tree the game's process ends up inside, and that is
//  decided by whichever wineserver is already running for the bottle. Wyn
//  adopts a live Steam session rather than restarting it, so a Steam that was
//  started on the frankea tree quietly keeps every later launch on frankea.
//
//  Measured, 4 September: a two-hour Solarpunk session ran entirely on DXVK
//  while its profile said d3dmetal and its DLL overrides were written
//  correctly. `WINEDLLOVERRIDES=d3d11=b` asks for *builtin*, and builtin is
//  D3DMetal only in the game-host tree; in the frankea tree the bottle's own
//  native DXVK d3d11.dll (3.9 MB in system32) won instead. Nothing anywhere
//  said so. The only trace was one line in the game's own log:
//
//      D3DMetal ->  "AMD Compatibility Mode"    VendorId 0x1002
//      DXVK     ->  "NVIDIA GeForce 6800"       VendorId 0x10de
//
//  Cost: 45 fps median at an effective 576x324 on an M4, plus 126,296 DXVK
//  error and warning lines written to disk during play, and a warm Mac that
//  was the only symptom anyone noticed.
//
//  This type answers the question before the launch instead of after it.
//
//  It is deliberately narrow. The one rule encoded here is the one that was
//  measured — D3DMetal needs the game-host tree — and nothing is claimed about
//  DXVK or DXMT, which reach a game through native DLLs in the bottle and may
//  well work under either tree. Guessing about the other direction is how the
//  bugs this file exists to catch got written in the first place.
//

import Foundation

public enum LayerReality {

    /// A profile asking for a layer the live Wine tree cannot provide.
    public struct Mismatch: Sendable, Equatable {
        /// What the profile asked for.
        public let requested: TranslationLayer
        /// The tree the bottle's wineserver is actually running from.
        public let runningTree: WineTree

        /// One line, for a status strip or the top of a launch.
        public var summary: String {
            "\(requested.displayName) was asked for, but this bottle is running "
                + "on the \(runningTree.displayName) Wine tree, which cannot provide it."
        }

        /// What to do about it. The remedy is cheap and safe, which is why it
        /// is worth interrupting someone for.
        public var remedy: String {
            "Quit Steam (`wyn steam quit`, or Steam's own Exit — never kill the "
                + "bottle) and launch again. Wyn starts the right tree when nothing "
                + "is already running in the bottle."
        }

        /// How to confirm which layer really ran, after the fact. Worth
        /// carrying around: it is the only reliable check.
        public var howToVerify: String {
            "The game's own log names the adapter each layer pretends to be — "
                + "D3DMetal reports \"AMD Compatibility Mode\" (VendorId 0x1002), "
                + "DXVK reports \"NVIDIA GeForce 6800\" (0x10de)."
        }
    }

    /// The layer this profile will really get, or nil when there is no problem.
    ///
    /// Returns nil when nothing is running in the bottle: the launch is then
    /// free to start whichever tree it wants, and predicting a mismatch would
    /// be inventing one.
    public static func mismatch(profile: GameProfile, in bottle: Bottle) -> Mismatch? {
        mismatch(
            requested: LaunchPath.effectiveLayer(profile: profile, bottle: bottle),
            in: bottle
        )
    }

    public static func mismatch(requested: TranslationLayer, in bottle: Bottle) -> Mismatch? {
        // Only D3DMetal is checked. See the file comment: it is the case that
        // was measured, and the only one where the tree alone decides.
        guard requested == .d3dMetal else { return nil }

        // Nothing running means nothing to be wrong about yet.
        guard let running = runningTree(in: bottle) else { return nil }
        guard running != .game else { return nil }

        return Mismatch(requested: requested, runningTree: running)
    }

    /// Which Wyn Wine tree the bottle's live wineserver came from, or nil when
    /// the bottle has no wineserver (or it belongs to no tree Wyn manages).
    public static func runningTree(in bottle: Bottle) -> WineTree? {
        WineTree.allCases.first {
            SteamLauncher.isBottleWineserverFromTree(in: bottle, tree: $0)
        }
    }
}
