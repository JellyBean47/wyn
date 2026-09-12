//
//  SteamSessionEnvTests.swift
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

/// A game started by `steam.exe -applaunch` inherits the Steam **client's**
/// environment and nothing else. So reusing a client that was started for
/// another profile hands this game the other one's D3DMetal settings.
///
/// Measured, 12 Sep 2026: satisfactory launched into a Steam client that was
/// already up, inherited `D3DM_ENABLE_METALFX=1` (the
/// `gameHostSteamEnvironment` default) over its profile's `"0"`, reached the
/// main menu, ticked 421 times where 1000 were expected, and died at 33 seconds
/// with no `LogExit`, no UE crash handler and no macOS crash report — the
/// SIGILL its notes warn about. Relaunched so `wyn play` owned the client, the
/// same build loaded `Persistent_Level` and kept running.
@Suite("Steam session environment")
struct SteamSessionEnvTests {

    private func makeBottle() throws -> Bottle {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "SteamSessionEnvTests")
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Bottle(bottleUrl: root)
    }

    private func profile(
        id: String = "satisfactory",
        environment: [String: String] = [:]
    ) -> GameProfile {
        GameProfile(
            id: id,
            name: "Test",
            steamAppId: 526_870,
            exePatterns: ["FactoryGameSteam-Win64-Shipping.exe"],
            bottle: nil,
            environment: environment,
            launchArgs: nil,
            notes: "note",
            status: .verified
        )
    }

    /// The case that mattered: a client is up, nothing recorded what it was
    /// started with, and macOS will not let the environment be read. Guessing it
    /// is compatible is what cost a session, so an unrecorded client is a
    /// mismatch.
    @Test func anUnrecordedClientIsAMismatch() throws {
        let bottle = try makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle.url) }

        let wanted = ["D3DM_ENABLE_METALFX": "0", "CX_GRAPHICS_BACKEND": "d3dmetal"]
        let mismatch = SteamLauncher.steamSessionEnvMismatch(
            wanted: wanted, profile: profile(), in: bottle
        )
        #expect(mismatch == ["CX_GRAPHICS_BACKEND", "D3DM_ENABLE_METALFX"])
    }

    @Test func aRecordedClientWithTheSameEnvironmentIsReused() throws {
        let bottle = try makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle.url) }

        let wanted = ["D3DM_ENABLE_METALFX": "0", "D3DM_ENABLE_ASYNC_COMMIT": "0"]
        SteamLauncher.recordSteamSessionEnv(wanted, profileId: "satisfactory", in: bottle)

        #expect(SteamLauncher.steamSessionEnvMismatch(
            wanted: wanted, profile: profile(), in: bottle
        ).isEmpty)
    }

    /// The exact failure. A client started for a profile that wants MetalFX on,
    /// then `wyn play satisfactory`, which needs it off.
    @Test func metalFXDisagreementIsCaughtAndNamed() throws {
        let bottle = try makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle.url) }

        SteamLauncher.recordSteamSessionEnv(
            ["D3DM_ENABLE_METALFX": "1", "CX_GRAPHICS_BACKEND": "d3dmetal"],
            profileId: "solarpunk",
            in: bottle
        )
        let mismatch = SteamLauncher.steamSessionEnvMismatch(
            wanted: ["D3DM_ENABLE_METALFX": "0", "CX_GRAPHICS_BACKEND": "d3dmetal"],
            profile: profile(),
            in: bottle
        )
        #expect(mismatch == ["D3DM_ENABLE_METALFX"])
    }

    /// `WINEDLLOVERRIDES` is deliberately *different* on the client than on the
    /// game — `steamSafeOverrides` strips the d3d/dxgi entries because on the
    /// client they reach steamwebhelper and kill CEF. Comparing it would report a
    /// mismatch on every single launch and restart Steam forever.
    @Test func clientOnlyDifferencesDoNotForceARestart() throws {
        let bottle = try makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle.url) }

        SteamLauncher.recordSteamSessionEnv(
            [
                "D3DM_ENABLE_METALFX": "0",
                "WINEDLLOVERRIDES": "gameoverlayrenderer64=d",
                "SteamAppId": "526870",
                "SteamGameId": "526870"
            ],
            profileId: "satisfactory",
            in: bottle
        )
        let mismatch = SteamLauncher.steamSessionEnvMismatch(
            wanted: [
                "D3DM_ENABLE_METALFX": "0",
                "WINEDLLOVERRIDES": "d3d11=b;dxgi=b;gameoverlayrenderer64=d",
                "SteamAppId": "1234",
                "SteamGameId": "1234"
            ],
            profile: profile(),
            in: bottle
        )
        #expect(mismatch.isEmpty)
    }

    /// A knob the running session set and this profile does not must still count:
    /// leaving a stale `MVK_` or `D3DM_` value in place is the same bug in the
    /// other direction.
    @Test func aLeftoverKnobFromTheOtherProfileIsAMismatch() throws {
        let bottle = try makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle.url) }

        SteamLauncher.recordSteamSessionEnv(
            ["D3DM_ENABLE_METALFX": "0", "MVK_CONFIG_LOG_LEVEL": "3"],
            profileId: "doom-2016",
            in: bottle
        )
        let mismatch = SteamLauncher.steamSessionEnvMismatch(
            wanted: ["D3DM_ENABLE_METALFX": "0"],
            profile: profile(),
            in: bottle
        )
        #expect(mismatch == ["MVK_CONFIG_LOG_LEVEL"])
    }

    /// Whatever a profile declares is game-visible by definition, even without a
    /// `D3DM_` / `MTL_` / `MVK_` prefix.
    @Test func profileDeclaredKeysAreCompared() throws {
        let bottle = try makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle.url) }

        SteamLauncher.recordSteamSessionEnv(
            ["FACTORYGAME_CUSTOM": "off"], profileId: "other", in: bottle
        )
        let mismatch = SteamLauncher.steamSessionEnvMismatch(
            wanted: ["FACTORYGAME_CUSTOM": "on"],
            profile: profile(environment: ["FACTORYGAME_CUSTOM": "on"]),
            in: bottle
        )
        #expect(mismatch == ["FACTORYGAME_CUSTOM"])
    }

    /// Quitting the client forgets the record, so the next launch does not judge
    /// a fresh client by the old one's environment.
    @Test func forgettingMakesTheNextClientUnrecorded() throws {
        let bottle = try makeBottle()
        defer { try? FileManager.default.removeItem(at: bottle.url) }

        let wanted = ["D3DM_ENABLE_METALFX": "0"]
        SteamLauncher.recordSteamSessionEnv(wanted, profileId: "satisfactory", in: bottle)
        #expect(SteamLauncher.steamSessionEnvMismatch(
            wanted: wanted, profile: profile(), in: bottle
        ).isEmpty)

        SteamLauncher.forgetSteamSessionEnv(in: bottle)
        #expect(!SteamLauncher.steamSessionEnvMismatch(
            wanted: wanted, profile: profile(), in: bottle
        ).isEmpty)
    }

    /// The shipped satisfactory profile is the one this exists for: it must
    /// actually declare MetalFX off, or the check has nothing to catch.
    @Test func theShippedSatisfactoryProfileStillTurnsMetalFXOff() throws {
        let satisfactory = try #require(
            ProfileStore.loadBundledProfiles().first { $0.id == "satisfactory" }
        )
        #expect(satisfactory.environment["D3DM_ENABLE_METALFX"] == "0")
        #expect(satisfactory.bottle?.metalHud != true)
    }
}
