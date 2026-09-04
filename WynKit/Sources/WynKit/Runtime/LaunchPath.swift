//
//  LaunchPath.swift
//  WynKit
//
//  Which process actually starts the game — and why that is not obvious.
//
//  Choosing a translation layer silently chooses a launch mechanism. On
//  D3DMetal, Wyn runs the game executable itself. On DXVK and DXMT it goes
//  through `steam.exe -applaunch <appid>`, which hands the decision to Steam:
//  Steam picks which executable runs, and for some titles that is a small
//  prerequisite shim rather than the game.
//
//  That is not a footnote. On Solarpunk the shim threw a "Visual C++ 2015-2022
//  Redistributable" dialog that looked like a real missing dependency, on a
//  bottle where the redistributable was already installed. Switching layers to
//  test a graphics theory had quietly also switched who chooses the
//  executable, and nothing on screen or in the profile said so.
//
//  So the rule lives here once, and everything that needs to tell someone what
//  will happen reads it from here: the CLI before it launches, the app's status
//  strip, and the diagnostics bundle.
//

import Foundation

/// How Wyn will start a game, given its translation layer.
public enum LaunchPath: Sendable, Equatable {

    /// Wyn runs the game executable directly. Nothing else chooses for us.
    case directExecutable

    /// `steam.exe -applaunch <appid>`. Steam chooses the executable, which is
    /// what makes SteamAPI-based identity work and what lets a prerequisite
    /// shim get in the way.
    case steamApplaunch

    /// Also `-applaunch`, but for a different reason: the profile names no
    /// executable, so there is nothing to run directly whatever the layer says.
    ///
    /// `GameLibrary.installed` synthesises a `steam-<appid>` profile with empty
    /// `exePatterns` for any installed title Wyn has no profile for, and
    /// `launchGame` short-circuits on that *before* it looks at the translation
    /// layer. Reporting the layer's answer here would be a lie — and it is the
    /// lie that cost an hour: a game whose profile had been removed launched
    /// via Steam, Steam picked a 230 KB prerequisite shim over the 131 MB game
    /// binary, and the shim's "Visual C++ Redistributable" dialog looked like a
    /// missing runtime on a machine that had it installed.
    case noProfile

    /// The one rule, in one place.
    ///
    /// D3DMetal is always direct — `launchGame`'s `direct` flag is not consulted
    /// on that path, so a profile cannot opt out and the UI should not suggest
    /// it can.
    public static func forLayer(_ layer: TranslationLayer, direct: Bool = false) -> LaunchPath {
        switch layer {
        case .d3dMetal: return .directExecutable
        case .dxvk, .dxmt: return direct ? .directExecutable : .steamApplaunch
        }
    }

    /// The layer a profile will actually run under: its own override if it has
    /// one, otherwise whatever the bottle is set to.
    public static func effectiveLayer(profile: GameProfile, bottle: Bottle) -> TranslationLayer {
        profile.bottle?.translationLayer ?? bottle.settings.translationLayer
    }

    /// The answer for a real profile, which must check for an executable
    /// *before* the layer — that is the order `launchGame` uses.
    public static func forProfile(_ profile: GameProfile, in bottle: Bottle, direct: Bool = false) -> LaunchPath {
        guard !profile.exePatterns.isEmpty else { return .noProfile }
        return forLayer(effectiveLayer(profile: profile, bottle: bottle), direct: direct)
    }

    /// Short enough for a status strip.
    public var shortLabel: String {
        switch self {
        case .directExecutable: return "runs the game directly"
        case .steamApplaunch: return "launched by Steam"
        case .noProfile: return "no profile — Steam picks the executable"
        }
    }

    /// The version worth reading when something has gone wrong.
    public var explanation: String {
        switch self {
        case .directExecutable:
            return "Wyn starts the game's own executable. Steam is not asked to "
                + "choose, so a prerequisite installer cannot get in the way."
        case .steamApplaunch:
            return "Wyn asks Steam to launch the game (steam.exe -applaunch). "
                + "Steam picks the executable, which for some titles is a "
                + "prerequisite shim rather than the game itself."
        case .noProfile:
            return "Wyn has no profile for this game, so it does not know which "
                + "executable to run and asks Steam to launch it instead. Steam "
                + "picks, and for some titles it picks a small prerequisite "
                + "installer rather than the game — which then reports a missing "
                + "runtime whether or not one is actually missing. Adding a "
                + "profile puts the game back on the direct path."
        }
    }
}
