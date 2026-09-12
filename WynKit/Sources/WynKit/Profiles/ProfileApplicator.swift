//
//  ProfileApplicator.swift
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

public enum ProfileApplicator {
    /// The settings a launch should run with: the bottle's, with this profile's
    /// overrides layered on top.
    ///
    /// This returns a **value**. The bottle on disk is the user's default and a
    /// launch must not rewrite it — one bottle is shared by every game, so a
    /// persisted per-game layer becomes the next game's default. Measured
    /// 2026-09-11: New Vegas (declaring `dxvk`) left the bottle on `dxmt`,
    /// which Army Men — declaring no layer — would then have inherited.
    /// See `FINDING-20260911-taskb-legs.md`.
    public static func launchSettings(profile: GameProfile?, bottle: Bottle) -> BottleSettings {
        var settings = bottle.settings
        guard let overrides = profile?.bottle else { return settings }

        if let windowsVersion = overrides.windowsVersion {
            settings.windowsVersion = windowsVersion
        }
        // `dxvk` is the legacy boolean, and its setter rewrites the layer:
        // `false` on a `.dxvk` bottle sends it to `.dxmt`. A named layer is the
        // profile's answer; the boolean is only consulted when none is named.
        if let layer = overrides.translationLayer {
            settings.translationLayer = layer
        } else if let dxvk = overrides.dxvk {
            settings.dxvk = dxvk
        }
        if let dxvkAsync = overrides.dxvkAsync {
            settings.dxvkAsync = dxvkAsync
        }
        if let sync = overrides.enhancedSync {
            settings.enhancedSync = sync
        }
        if let dxr = overrides.dxrEnabled {
            settings.dxrEnabled = dxr
        }
        if let avx = overrides.avxEnabled {
            settings.avxEnabled = avx
        }
        if let hud = overrides.metalHud {
            settings.metalHud = hud
        }
        return settings
    }

    /// The layer to pass as `Wine.LaunchOptions.translationLayerOverride`, or
    /// `nil` when the profile names no graphics at all — then the bottle's
    /// default and the unix wiring decide, exactly as they do with no profile.
    public static func launchLayerOverride(profile: GameProfile?, bottle: Bottle) -> TranslationLayer? {
        guard let overrides = profile?.bottle else { return nil }
        if let layer = overrides.translationLayer { return layer }
        guard let dxvk = overrides.dxvk else { return nil }
        var settings = bottle.settings
        settings.dxvk = dxvk
        let coerced = settings.translationLayer
        // Only speak up when the legacy boolean actually moves the layer (the
        // `false` on a `.dxvk` bottle → `.dxmt` case). Returning an override
        // equal to the bottle's own layer is not a no-op: `Wine.deployLayer`
        // treats an explicit override as "the caller means it" and stops
        // coercing `.d3dMetal` → `.dxmt` on the Steam tree.
        return coerced == bottle.settings.translationLayer ? nil : coerced
    }

    /// Persist a profile's bottle overrides onto the bottle. This is the
    /// deliberate, user-asked write (`wyn profiles apply`) — **not** what a
    /// launch does. Launch paths use `launchSettings` / `launchLayerOverride`.
    public static func apply(profile: GameProfile, to bottle: Bottle) {
        guard profile.bottle != nil else { return }
        bottle.settings = launchSettings(profile: profile, bottle: bottle)
    }

    /// Build the merged environment for launching with a profile.
    public static func launchEnvironment(
        profile: GameProfile?,
        program: Program
    ) -> [String: String] {
        var env = program.generateEnvironment()

        // The profile's knobs reach the launch through the environment rather
        // than through a write to the shared bottle: layer overrides, sync,
        // AVX, the Metal HUD. `Wine.constructWineEnvironment` lays the bottle's
        // own values down first and this dictionary is merged over them.
        if profile != nil {
            let settings = launchSettings(profile: profile, bottle: program.bottle)
            settings.environmentVariables(wineEnv: &env)
        }

        if let profile {
            env.merge(profile.environment, uniquingKeysWith: { _, new in new })
        }

        return env
    }

    /// Put `fly-mvkshim` in front of MoltenVK in the trees a Vulkan-native
    /// title might launch on.
    ///
    /// id Tech asks Vulkan for `shaderCullDistance` and `depthBounds`; Metal has
    /// neither, so without the shim `vkCreateDevice` fails
    /// VK_ERROR_FEATURE_NOT_PRESENT and the game dies on "Startup failure: error
    /// while initializing the graphics driver" before a window appears.
    ///
    /// Keyed on `ProfileValidator.isVulkanNative`, so a profile asks for this by
    /// naming `vulkan-1` in `WINEDLLOVERRIDES` or setting an `MVK_` knob — no new
    /// schema field, and `doom-2016` / `wolfenstein-youngblood` already qualify.
    ///
    /// Both trees, because the launch path picks one later and the two titles
    /// disagree about which: DOOM must go through Steam `-applaunch` for its COM
    /// apartment while Youngblood runs `--direct`. Installing is idempotent and
    /// a tree that has no MoltenVK is skipped, so doing both is cheap.
    ///
    /// Never throws: a tree that will not take the shim should still launch and
    /// fail with the game's own diagnostics rather than one of ours.
    @discardableResult
    public static func prepareVulkanShim(profile: GameProfile?) -> Int {
        guard let profile, ProfileValidator.isVulkanNative(profile) else { return 0 }
        var installed = 0
        for tree in [WineTree.game, .steam] {
            let root = WynWineInstaller.libraryFolder(for: tree)
            if (try? WynWineInstaller.ensureVulkanFeatureShim(in: root)) == true { installed += 1 }
        }
        return installed
    }

    /// Resolve launch arguments from profile + program settings.
    /// Supports simple double-quoted tokens (e.g. `-ExecCmds="stat unit,stat fps"`).
    public static func launchArguments(profile: GameProfile?, program: Program) -> [String] {
        let raw = profile?.launchArgs ?? program.settings.arguments
        guard !raw.isEmpty else { return [] }
        return splitLaunchArgs(raw)
    }

    /// Whitespace split that keeps `"quoted sections"` as a single argument (quotes stripped).
    public static func splitLaunchArgs(_ raw: String) -> [String] {
        var args: [String] = []
        var current = ""
        var inQuotes = false
        for ch in raw {
            if ch == "\"" {
                inQuotes.toggle()
                continue
            }
            if ch.isWhitespace, !inQuotes {
                if !current.isEmpty {
                    args.append(current)
                    current = ""
                }
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty {
            args.append(current)
        }
        return args
    }
}
