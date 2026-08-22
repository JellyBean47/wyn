//
//  ProfileApplicator.swift
//  WynKit
//

import Foundation

public enum ProfileApplicator {
    /// Apply a game profile's bottle overrides to an existing bottle (in-memory; persists via BottleSettings).
    public static func apply(profile: GameProfile, to bottle: Bottle) {
        guard let overrides = profile.bottle else { return }

        if let windowsVersion = overrides.windowsVersion {
            bottle.settings.windowsVersion = windowsVersion
        }
        if let layer = overrides.translationLayer {
            bottle.settings.translationLayer = layer
            bottle.settings.dxvk = layer == .dxvk
        }
        if let dxvk = overrides.dxvk {
            bottle.settings.dxvk = dxvk
        }
        if let dxvkAsync = overrides.dxvkAsync {
            bottle.settings.dxvkAsync = dxvkAsync
        }
        if let sync = overrides.enhancedSync {
            bottle.settings.enhancedSync = sync
        }
        if let dxr = overrides.dxrEnabled {
            bottle.settings.dxrEnabled = dxr
        }
        if let avx = overrides.avxEnabled {
            bottle.settings.avxEnabled = avx
        }
        if let hud = overrides.metalHud {
            bottle.settings.metalHud = hud
        }
    }

    /// Build the merged environment for launching with a profile.
    public static func launchEnvironment(
        profile: GameProfile?,
        program: Program
    ) -> [String: String] {
        var env = program.generateEnvironment()

        if let profile {
            if let layer = profile.bottle?.translationLayer {
                env.merge(
                    layer.environmentOverrides(
                        dxvkHud: program.bottle.settings.dxvkHud,
                        dxvkAsync: program.bottle.settings.dxvkAsync
                    ),
                    uniquingKeysWith: { _, new in new }
                )
            }
            env.merge(profile.environment, uniquingKeysWith: { _, new in new })
        }

        return env
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
