//
//  ProfileValidator.swift
//  WynKit
//
//  What a profile is allowed to say.
//
//  Profiles are cheap to write and expensive to be wrong about, and the two are
//  indistinguishable on the page: a guessed profile and a measured one are both
//  plausible JSON with confident notes. `a225167` added 100 of them in a single
//  commit; 72 turned MetalFX on and drew Metal's debug HUD over the game, which
//  is the exact combination `satisfactory.json` sets to "0" because MetalFX on
//  crawls to ~0.1–2 fps and then SIGILLs in
//  D3DMCommandQueue::ExecuteCommandLists. Nothing caught it, because nothing
//  was looking.
//
//  So this is the thing that looks. It encodes the handover's §8 guardrails —
//  the rules that each cost days to learn — as assertions a profile must pass,
//  and `ProfileCatalogValidationTests` runs it over every profile Wyn ships.
//
//  It is deliberately conservative about anything unproven. A profile that has
//  never been launched may not turn on a setting that was measured to break the
//  one game we have actually tested; it may only do that once it says it has
//  been verified, which is a claim a person has to make on purpose.
//

import Foundation

public enum ProfileValidator {

    public enum Severity: String, Sendable {
        /// Ships broken, or does something a guardrail forbids. Fails the build.
        case error
        /// Suspicious, or missing something a good profile has.
        case warning
    }

    public struct Finding: Sendable, Equatable, CustomStringConvertible {
        public let profileID: String
        public let severity: Severity
        /// Short stable name, so a finding can be talked about and suppressed.
        public let rule: String
        public let message: String

        public var description: String {
            "[\(severity.rawValue)] \(profileID): \(rule) — \(message)"
        }
    }

    /// Environment variables that draw developer overlays on top of the game.
    /// Not a matter of taste: a person launching a game does not want Metal's
    /// stat HUD over it, and 71 shipped profiles had it on.
    static let debugOverlayVariables = ["MTL_HUD_ENABLED", "D3DM_SHOW_HUD_STATS"]

    /// D3DMetal knobs measured to change whether a game runs at all. Satisfactory
    /// SIGILLs with MetalFX on; async commit is in the same family and was set to
    /// "0" by the same measurement. Neither may be enabled by a profile that has
    /// not been launched.
    static let measuredRiskVariables = ["D3DM_ENABLE_METALFX", "D3DM_ENABLE_ASYNC_COMMIT"]

    /// Substrings the handover forbids outright (§8). These cost days each.
    static let bannedSubstrings = [
        "-execcmds",        // no -ExecCmds, ever
        "xinput1_3=d",      // no xinput*=d
        "xinput9_1_0=d",
        "fg.inputmode",     // no exclusive-KBM pin on play
        "forcemouse",
        "wineserver -k",    // never
        "wineboot -u"
    ]

    /// The Direct3D DLL family whose override mode decides which translation
    /// layer actually loads.
    static let d3dOverrideNames = ["d3d11", "d3d10core", "d3d12", "dxgi"]

    public static func validate(_ profile: GameProfile) -> [Finding] {
        var findings: [Finding] = []
        func fail(_ rule: String, _ severity: Severity, _ message: String) {
            findings.append(
                Finding(profileID: profile.id, severity: severity, rule: rule, message: message)
            )
        }

        // MARK: Shape

        if profile.id.trimmingCharacters(in: .whitespaces).isEmpty {
            fail("requiredFields", .error, "id is empty")
        }
        if profile.name.trimmingCharacters(in: .whitespaces).isEmpty {
            fail("requiredFields", .error, "name is empty")
        }
        if profile.exePatterns.isEmpty {
            fail("requiredFields", .error, "no exePatterns — nothing can ever match this profile")
        }
        for pattern in profile.exePatterns where !pattern.lowercased().hasSuffix(".exe") {
            fail("exePatternShape", .warning, "exe pattern \"\(pattern)\" does not end in .exe")
        }
        if let appId = profile.steamAppId, appId <= 0 {
            fail("requiredFields", .error, "steamAppId \(appId) is not a Steam app id")
        }

        // MARK: Debug overlays

        for key in debugOverlayVariables where isTruthy(profile.environment[key]) {
            fail(
                "debugOverlayOff", profile.status == .verified ? .warning : .error,
                "\(key)=\(profile.environment[key] ?? "") draws a developer overlay over the game"
            )
        }
        if profile.bottle?.metalHud == true {
            fail(
                "debugOverlayOff", profile.status == .verified ? .warning : .error,
                "metalHud draws Metal's stat overlay over the game"
            )
        }

        // MARK: Settings measured to break a real game

        for key in measuredRiskVariables where isTruthy(profile.environment[key]) {
            if profile.status == .verified { continue }
            fail(
                "unmeasuredRiskSetting", .error,
                """
                \(key)=1 on a profile that has never been launched. Satisfactory \
                measured this family at ~0.1–2 fps then SIGILL in \
                D3DMCommandQueue::ExecuteCommandLists. Leave it "0" until a real \
                launch says otherwise, then mark the profile verified.
                """
            )
        }

        // MARK: Guardrails that cost days

        let haystack = ((profile.launchArgs ?? "") + " "
                        + profile.environment.values.joined(separator: " ")).lowercased()
        for banned in bannedSubstrings where haystack.contains(banned) {
            fail("bannedSetting", .error, "contains \"\(banned)\", which §8 forbids")
        }

        // MARK: Translation layer coherence

        let layer = profile.bottle?.translationLayer
        let dxvk = profile.bottle?.dxvk

        // `dxvk` layer with `dxvk: false` looks incoherent and usually is — but
        // not for a Vulkan-native game. DOOM Eternal, Enshrouded, Detroit and
        // No Man's Sky all call Vulkan themselves, so there is no D3D to
        // translate: the layer means "the MoltenVK path, not D3DMetal", and
        // installing DXVK's D3D→Vulkan DLLs would be pointless. They announce
        // it with `vulkan-1=b` and MoltenVK tuning. This rule flagged all four
        // on its first run, and all four were right — so the exemption is the
        // fix, and `vulkanNativeProfilesAreCoherent` keeps anyone from
        // "correcting" them by flipping dxvk to true.
        if layer == .dxvk, dxvk == false, !isVulkanNative(profile) {
            fail(
                "layerCoherence", .error,
                """
                translationLayer is dxvk but dxvk is false, and nothing says this \
                game speaks Vulkan natively. Either enable dxvk or declare the \
                Vulkan path (vulkan-1 override / MVK_ tuning).
                """
            )
        }
        if layer == .d3dMetal, dxvk == true {
            fail("layerCoherence", .error, "translationLayer is d3dmetal but dxvk is true")
        }

        // MARK: Native-first D3D overrides
        //
        // `n,b` means *native first*, so the d3d DLLs sitting in system32 win.
        // Under DXMT those PEs *are* the translation layer and native-first is
        // exactly right. Under D3DMetal they are not, and loading them into a
        // process that expects builtin is what killed steamwebhelper (see
        // Wine.applyD3DMetalSteamIsolation). So this is only a fault on
        // D3DMetal — scoped, or it would flag the DXMT profiles for doing the
        // correct thing.
        if layer == .d3dMetal, let overrides = profile.environment["WINEDLLOVERRIDES"] {
            for clause in overrides.split(separator: ";") {
                let parts = clause.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let names = parts[0].lowercased().split(separator: ",").map(String.init)
                let mode = parts[1].lowercased()
                guard mode.hasPrefix("n") else { continue }
                let clashing = names.filter { d3dOverrideNames.contains($0) }
                if !clashing.isEmpty {
                    fail(
                        "nativeFirstD3DOverride", .error,
                        """
                        WINEDLLOVERRIDES sets \(clashing.joined(separator: ", ")) to \
                        "\(mode)" (native first) on a D3DMetal profile. These must be \
                        builtin ("b") — native first picks up whatever PE is in \
                        system32.
                        """
                    )
                }
            }
        }

        // MARK: Provenance

        if profile.status == .verified, (profile.notes ?? "").isEmpty {
            fail(
                "verifiedNeedsEvidence", .error,
                "claims to be verified but has no notes saying what was measured"
            )
        }

        return findings
    }

    public static func validate(_ profiles: [GameProfile]) -> [Finding] {
        profiles.flatMap(validate)
    }

    public static func errors(in profiles: [GameProfile]) -> [Finding] {
        validate(profiles).filter { $0.severity == .error }
    }

    /// The game renders through Vulkan itself, so nothing is translating D3D.
    /// Read from what the profile already says rather than a new schema field:
    /// these profiles override `vulkan-1` to builtin and tune MoltenVK.
    static func isVulkanNative(_ profile: GameProfile) -> Bool {
        if profile.environment.keys.contains(where: { $0.hasPrefix("MVK_") }) { return true }
        let overrides = profile.environment["WINEDLLOVERRIDES"]?.lowercased() ?? ""
        return overrides.contains("vulkan-1")
    }

    /// Steam writes "1"/"0"; be generous about what counts as on.
    private static func isTruthy(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespaces).lowercased() else {
            return false
        }
        return ["1", "true", "yes", "on"].contains(value)
    }
}
