//
//  ProfileValidatorTests.swift
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

/// Profiles are cheap to write and expensive to be wrong about, and the two are
/// indistinguishable on the page. `a225167` added 100 in a single commit; 72 of
/// them turned MetalFX on and drew Metal's stat HUD over the game — the exact
/// combination `satisfactory.json` sets to "0" because MetalFX on crawls to
/// ~0.1–2 fps and then SIGILLs in D3DMCommandQueue::ExecuteCommandLists.
///
/// Nothing caught it because nothing was looking. `everyShippedProfileIsValid`
/// is the thing that looks, and it fails on that commit.
@Suite("Profile validation")
struct ProfileValidatorTests {

    private func profile(
        id: String = "test-game",
        name: String = "Test Game",
        environment: [String: String] = [:],
        bottle: ProfileBottleOverrides? = nil,
        launchArgs: String? = nil,
        notes: String? = "note",
        status: ProfileStatus = .guessed
    ) -> GameProfile {
        GameProfile(
            id: id,
            name: name,
            steamAppId: 1,
            exePatterns: ["test.exe"],
            bottle: bottle,
            environment: environment,
            launchArgs: launchArgs,
            notes: notes,
            status: status
        )
    }

    private func rules(_ findings: [ProfileValidator.Finding]) -> Set<String> {
        Set(findings.filter { $0.severity == .error }.map(\.rule))
    }

    // MARK: - The catalog

    /// The guard. Every profile Wyn ships must pass, so a batch of generated
    /// profiles cannot land broken again.
    @Test func everyShippedProfileIsValid() {
        let all = ProfileStore.loadAll()
        #expect(!all.isEmpty, "no profiles loaded — the test would pass vacuously")

        let errors = ProfileValidator.errors(in: all)
        #expect(errors.isEmpty, """
        \(errors.count) profile error(s):
        \(errors.map(\.description).joined(separator: "\n"))
        """)
    }

    /// Provenance must be stated, not inferred — and only what was actually
    /// measured may claim to have been. Each name here was played to a loaded
    /// map on this machine and the log kept; adding one without that is the
    /// failure this test exists to catch.
    ///
    /// `rv-there-yet` (11 Sep 2026) is the strongest: loaded map, 1514 frames,
    /// `LogExit: Exiting.`, no crash directory, and the layer confirmed twice —
    /// `lsof` on the live process holding the DXMT payload open, and the UE
    /// log's own adapter line ('Apple M4' through Forced RHI D3D11).
    ///
    /// `ac-odyssey` (10 Sep 2026) is a weak Unreal-less entry: played to a
    /// loaded map, layer confirmed by lsof, but no launch record and no frame
    /// count, because Wyn cannot time a Steam `-applaunch` title.
    ///
    /// `witcher-3` and `ready-or-not` are the no-engine-log pair. REDengine /
    /// shipping RoN write nothing Wyn can parse, so the evidence is in-world
    /// play plus lsof (Witcher 3: D3DMetal.framework on live witcher3.exe,
    /// dx12user.settings 1920x1080 VSync). If the bar is tightened to "a UE
    /// log with LoadMap and a frame count", those two come out first.
    @Test func onlyMeasuredProfilesClaimVerified() {
        let userAdded = ProfileStore.userProfileIDs()
        let verified = ProfileStore.loadAll()
            .filter { $0.status == .verified && !userAdded.contains($0.id) }
        #expect(verified.map(\.id).sorted() == [
            "ac-odyssey", "ready-or-not", "rv-there-yet", "satisfactory", "solarpunk",
            "witcher-3",
        ])
    }

    /// `launched` on a shipped profile is a catalog claim: this Mac ran the
    /// title and notes say what was seen. It is not §5 verified. The names
    /// here are the only bundled ids allowed to say it; adding one without
    /// that evidence is the failure this test exists to catch.
    @Test func onlyDocumentedProfilesClaimLaunched() {
        let expected = [
            // ac-odyssey graduated to `verified` on 10 Sep 2026.
            // witcher-3 graduated to `verified` on 11 Sep 2026 (Ready or Not
            // bar: in-world play, no engine log, lsof on D3DMetal).
            "army-men-rts",
            "assetto-corsa",
            "cities-skylines",
            "skyrim-se",
        ]
        let userAdded = ProfileStore.userProfileIDs()
        let launched = ProfileStore.loadAll()
            .filter { $0.status == .launched && !userAdded.contains($0.id) }
            .map(\.id)
        for id in expected {
            #expect(ProfileStore.profile(id: id)?.status == .launched, "\(id) should be launched")
        }
        #expect(Set(launched).subtracting(expected).isEmpty)
    }

    /// A profile with no `status` in its JSON is a guess. If this ever defaults
    /// the other way, every untested profile silently claims to be tested.
    @Test func absentStatusDecodesAsGuessed() throws {
        let json = #"{"id":"x","name":"X","exePatterns":["x.exe"]}"#
        let decoded = try JSONDecoder().decode(GameProfile.self, from: Data(json.utf8))
        #expect(decoded.status == .guessed)
    }

    // MARK: - Debug overlays

    /// 71 shipped profiles drew a developer overlay over the game.
    @Test func debugOverlaysAreAnError() {
        #expect(rules(ProfileValidator.validate(
            profile(environment: ["MTL_HUD_ENABLED": "1"])
        )).contains("debugOverlayOff"))

        #expect(rules(ProfileValidator.validate(
            profile(environment: ["D3DM_SHOW_HUD_STATS": "1"])
        )).contains("debugOverlayOff"))

        #expect(rules(ProfileValidator.validate(
            profile(bottle: ProfileBottleOverrides(metalHud: true))
        )).contains("debugOverlayOff"))
    }

    @Test func overlaysOffIsFine() {
        let findings = ProfileValidator.validate(
            profile(
                environment: ["MTL_HUD_ENABLED": "0", "D3DM_SHOW_HUD_STATS": "0"],
                bottle: ProfileBottleOverrides(metalHud: false)
            )
        )
        #expect(rules(findings).isEmpty)
    }

    /// "1" is not the only way to say on.
    @Test func truthyValuesAreAllCaught() {
        for value in ["1", "true", "TRUE", "yes", "on", " 1 "] {
            #expect(
                rules(ProfileValidator.validate(profile(environment: ["MTL_HUD_ENABLED": value])))
                    .contains("debugOverlayOff"),
                "\(value) should read as on"
            )
        }
    }

    // MARK: - Settings measured to break a real game

    @Test func metalFXOnAnUntestedProfileIsAnError() {
        #expect(rules(ProfileValidator.validate(
            profile(environment: ["D3DM_ENABLE_METALFX": "1"])
        )).contains("unmeasuredRiskSetting"))

        #expect(rules(ProfileValidator.validate(
            profile(environment: ["D3DM_ENABLE_ASYNC_COMMIT": "1"])
        )).contains("unmeasuredRiskSetting"))
    }

    /// The escape hatch is real, but it costs a deliberate claim plus evidence:
    /// a verified profile may enable it, and must say what it measured.
    @Test func averifiedProfileMayEnableItWithEvidence() {
        let findings = ProfileValidator.validate(
            profile(
                environment: ["D3DM_ENABLE_METALFX": "1"],
                notes: "Measured 60fps with MetalFX on, 40 sessions, no SIGILL.",
                status: .verified
            )
        )
        #expect(rules(findings).isEmpty)
    }

    @Test func verifiedWithoutEvidenceIsAnError() {
        #expect(rules(ProfileValidator.validate(
            profile(notes: nil, status: .verified)
        )).contains("verifiedNeedsEvidence"))
    }

    /// `launched` is not `verified` — running once proves nothing about MetalFX.
    @Test func launchedIsNotEnoughToEnableARiskSetting() {
        #expect(rules(ProfileValidator.validate(
            profile(environment: ["D3DM_ENABLE_METALFX": "1"], status: .launched)
        )).contains("unmeasuredRiskSetting"))
    }

    // MARK: - §8 guardrails

    @Test func settingsGuardrailsForbidAreAnError() {
        for banned in ["-ExecCmds \"r.Foo 1\"", "-dx11 -ExecCmds x"] {
            #expect(rules(ProfileValidator.validate(profile(launchArgs: banned)))
                .contains("bannedSetting"), "\(banned) should be refused")
        }
        #expect(rules(ProfileValidator.validate(
            profile(environment: ["WINEDLLOVERRIDES": "xinput1_3=d"])
        )).contains("bannedSetting"))
    }

    @Test func ordinaryLaunchArgsPass() {
        let findings = ProfileValidator.validate(
            profile(launchArgs: "-NO_EOS_OVERLAY -dx11 -USEALLAVAILABLECORES -Nosplash")
        )
        #expect(rules(findings).isEmpty)
    }

    // MARK: - Native-first D3D overrides

    /// On D3DMetal the d3d DLLs must be builtin. Native-first picks up whatever
    /// PE is in system32, which is what killed steamwebhelper.
    @Test func nativeFirstD3DOnD3DMetalIsAnError() {
        let findings = ProfileValidator.validate(
            profile(
                environment: ["WINEDLLOVERRIDES": "dxgi,d3d11,d3d10core=n,b"],
                bottle: ProfileBottleOverrides(translationLayer: .d3dMetal, dxvk: false)
            )
        )
        #expect(rules(findings).contains("nativeFirstD3DOverride"))
    }

    /// Under DXMT those PEs *are* the translation layer, so native-first is
    /// correct — and three shipped profiles rely on it. Flagging them would be
    /// the rule being wrong, not the profiles.
    @Test func nativeFirstD3DOnDXMTIsCorrectAndAllowed() {
        let findings = ProfileValidator.validate(
            profile(
                environment: ["WINEDLLOVERRIDES": "dxgi,d3d11,d3d10core=n,b"],
                bottle: ProfileBottleOverrides(translationLayer: .dxmt)
            )
        )
        #expect(!rules(findings).contains("nativeFirstD3DOverride"))
    }

    /// winmm is a normal native override and is not in the D3D family.
    @Test func nonD3DNativeOverridesArePermitted() {
        let findings = ProfileValidator.validate(
            profile(
                environment: ["WINEDLLOVERRIDES": "winmm=n,b"],
                bottle: ProfileBottleOverrides(translationLayer: .d3dMetal, dxvk: false)
            )
        )
        #expect(!rules(findings).contains("nativeFirstD3DOverride"))
    }

    @Test func builtinD3DOverridesPass() {
        let findings = ProfileValidator.validate(
            profile(
                environment: ["WINEDLLOVERRIDES": "d3d11,dxgi,d3d12,d3d10,nvapi64=b"],
                bottle: ProfileBottleOverrides(translationLayer: .d3dMetal, dxvk: false)
            )
        )
        #expect(rules(findings).isEmpty)
    }

    // MARK: - Coherence and shape

    @Test func layerAndDxvkMustAgree() {
        #expect(rules(ProfileValidator.validate(profile(
            bottle: ProfileBottleOverrides(translationLayer: .dxvk, dxvk: false)
        ))).contains("layerCoherence"))

        #expect(rules(ProfileValidator.validate(profile(
            bottle: ProfileBottleOverrides(translationLayer: .d3dMetal, dxvk: true)
        ))).contains("layerCoherence"))
    }

    /// DOOM Eternal, Enshrouded, Detroit and No Man's Sky call Vulkan
    /// themselves: there is no D3D to translate, so `dxvk: false` is right and
    /// the layer just means "MoltenVK, not D3DMetal".
    ///
    /// The coherence rule flagged all four on its first run and all four were
    /// correct — the rule was wrong. This test is here so nobody tightens it
    /// again and "fixes" four good profiles by flipping dxvk to true.
    @Test func vulkanNativeProfilesAreCoherent() {
        let vulkanNative = profile(
            environment: [
                "WINEDLLOVERRIDES": "vulkan-1=b",
                "MVK_CONFIG_USE_METAL_PRIVATE_API": "1"
            ],
            bottle: ProfileBottleOverrides(translationLayer: .dxvk, dxvk: false)
        )
        #expect(!rules(ProfileValidator.validate(vulkanNative)).contains("layerCoherence"))
        #expect(ProfileValidator.isVulkanNative(vulkanNative))
    }

    /// The exemption must be earned. A dxvk profile with dxvk off and nothing
    /// saying it speaks Vulkan is still incoherent.
    @Test func theVulkanExemptionIsNotAFreePass() {
        let bare = profile(bottle: ProfileBottleOverrides(translationLayer: .dxvk, dxvk: false))
        #expect(!ProfileValidator.isVulkanNative(bare))
        #expect(rules(ProfileValidator.validate(bare)).contains("layerCoherence"))
    }

    /// And the four in the catalog really are the exempted shape, not merely
    /// passing because the rule got loosened for everyone.
    @Test func theShippedVulkanProfilesAreTheOnesExempted() {
        let all = ProfileStore.loadAll()
        let exempt = all.filter {
            $0.bottle?.translationLayer == .dxvk
                && $0.bottle?.dxvk == false
        }
        #expect(exempt.map(\.id).sorted()
                == ["detroit-become-human", "doom-eternal", "enshrouded", "no-mans-sky"])
        for profile in exempt {
            #expect(ProfileValidator.isVulkanNative(profile), "\(profile.id)")
        }
    }

    @Test func aProfileThatCanNeverMatchIsAnError() {
        let orphan = GameProfile(id: "x", name: "X", exePatterns: [], notes: "n")
        #expect(rules(ProfileValidator.validate(orphan)).contains("requiredFields"))
    }

    @Test func emptyIdOrNameIsAnError() {
        #expect(rules(ProfileValidator.validate(profile(id: "  "))).contains("requiredFields"))
        #expect(rules(ProfileValidator.validate(profile(name: " "))).contains("requiredFields"))
    }

    @Test func nonPositiveSteamAppIdIsAnError() {
        var bad = profile()
        bad.steamAppId = 0
        #expect(rules(ProfileValidator.validate(bad)).contains("requiredFields"))
    }

    // MARK: - Non-vacuity

    /// If the validator returned nothing for everything, every test above would
    /// pass. Prove it actually rejects the shape that shipped.
    @Test func theValidatorRejectsTheProfileThatShipped() {
        let asShipped = profile(
            environment: [
                "WINEDLLOVERRIDES": "d3d11,dxgi,d3d12,d3d10,atidxx64,nvapi64,nvngx=b",
                "MTL_HUD_ENABLED": "1",
                "D3DM_ENABLE_METALFX": "1",
                "D3DM_SHOW_HUD_STATS": "1"
            ],
            bottle: ProfileBottleOverrides(
                translationLayer: .d3dMetal, dxvk: false, metalHud: true
            ),
            notes: "Asobo DX12 → D3DMetal (Control class)."
        )
        let found = rules(ProfileValidator.validate(asShipped))
        #expect(found.contains("debugOverlayOff"))
        #expect(found.contains("unmeasuredRiskSetting"))
    }
}
