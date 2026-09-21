//
//  QuitSteamTests.swift
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

/// `quitSteam` itself needs a live bottle, so what is tested here is the part
/// that decides whether Quit is even allowed to proceed: matching running
/// processes to library games.
///
/// Getting this wrong is quiet and bad in both directions — a false negative
/// force-quits Steam under someone mid-session, a false positive makes Quit
/// permanently refuse.
@Suite("Quit Steam — running game detection")
struct QuitSteamTests {

    private func profile(_ name: String, _ exes: [String]) -> GameProfile {
        GameProfile(id: name.lowercased(), name: name, exePatterns: exes)
    }

    // MARK: - Basename matching

    @Test func matchesGameExeInASteamPath() {
        let base = SteamLauncher.windowsExeBasename(
            fromCommand: #"C:\Program Files (x86)\Steam\steamapps\common\Satisfactory\FactoryGameSteam.exe -dx11"#
        )
        #expect(base == "factorygamesteam.exe")
    }

    /// Profiles are authored lowercase, but the match must not depend on it.
    @Test func matchingIsCaseInsensitiveOnBothSides() {
        let profiles = [profile("Satisfactory", ["FactoryGameSteam.EXE"])]
        var nameForExe: [String: String] = [:]
        for p in profiles {
            for pattern in p.exePatterns { nameForExe[pattern.lowercased()] = p.name }
        }
        let base = SteamLauncher.windowsExeBasename(
            fromCommand: #"C:\Games\FACTORYGAMESTEAM.EXE"#
        )
        #expect(base != nil)
        #expect(nameForExe[base!] == "Satisfactory")
    }

    // MARK: - What must never count as a running game

    /// A running Steam client is not a game. If it were, Quit would refuse to
    /// close the very thing it exists to close.
    @Test func steamClientIsNotAGame() {
        #expect(SteamLauncher.lineIsSteamClientExe(
            #"C:\Program Files (x86)\Steam\steam.exe -no-cef-sandbox"#
        ))
    }

    @Test func steamWebHelperIsNotAGame() {
        let command = #"C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper.exe --type=renderer"#
        #expect(command.lowercased().contains("steamwebhelper"))
        #expect(SteamLauncher.leftoverSessionCommands(matching: ["steamwebhelper.exe"]).isEmpty)
    }

    /// CrashReportClient can sit for hours after a session. Treating it as a
    /// live game would block Quit indefinitely.
    @Test func crashReportClientIsNotALiveGame() {
        #expect(!D3DMetalGpuSettle.leftoverIsLiveGame(
            basename: "crashreportclient.exe",
            gameExeNames: ["factorygamesteam.exe"]
        ))
    }

    @Test func theActualGameIsALiveGame() {
        #expect(D3DMetalGpuSettle.leftoverIsLiveGame(
            basename: "factorygamesteam.exe",
            gameExeNames: ["factorygamesteam.exe"]
        ))
    }

    // MARK: - Empty cases

    /// No profiles, or profiles with no exePatterns (Steam-library imports get
    /// `exePatterns: []`), must scan nothing rather than match everything.
    @Test func profilesWithoutExePatternsMatchNothing() {
        #expect(SteamLauncher.runningGameNames(among: []).isEmpty)
        #expect(SteamLauncher.runningGameNames(among: [profile("Imported", [])]).isEmpty)
    }

    @Test func emptyNameSetScansNothing() {
        #expect(SteamLauncher.leftoverSessionCommands(matching: []).isEmpty)
    }

    /// A name that cannot be running yields no false positive on a real `ps`.
    @Test func unrelatedGameIsNotReportedRunning() {
        let unlikely = "wyn-test-\(UUID().uuidString.prefix(8)).exe"
        #expect(SteamLauncher.runningGameNames(among: [profile("Ghost", [unlikely])]).isEmpty)
    }

    // MARK: - steam.exe detection (fast path added for the Play-button CPU spin)

    /// The predicate runs over every row of `ps -ax` on every poll, so it now
    /// rejects lines with a no-allocation ASCII prefilter before lowercasing.
    /// These pin the behaviour that prefilter must not change.

    @Test func bareSteamExeTokenStillMatches() {
        // Exercises the regex fallback, not the `\steam\steam.exe` fast path.
        #expect(SteamLauncher.lineIsSteamClientExe(#"steam.exe"#))
        #expect(SteamLauncher.lineIsSteamClientExe(#"C:\Games\steam.exe -foo"#))
        #expect(SteamLauncher.lineIsSteamClientExe(#"/opt/steam.exe"#))
    }

    @Test func detectionIsCaseInsensitive() {
        #expect(SteamLauncher.lineIsSteamClientExe(#"C:\Program Files (x86)\STEAM\STEAM.EXE"#))
        #expect(SteamLauncher.lineIsSteamClientExe(#"C:\Program Files (x86)\Steam\Steam.Exe -silent"#))
    }

    @Test func webHelperAndSteamPathAreRejected() {
        #expect(!SteamLauncher.lineIsSteamClientExe(
            #"C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper.exe --type=renderer"#
        ))
        #expect(!SteamLauncher.lineIsSteamClientExe(
            #"some.exe -steampath=C:\Program Files (x86)\Steam\steam.exe"#
        ))
    }

    /// The prefilter's reject path — the overwhelmingly common case.
    @Test func linesWithoutSteamAreRejected() {
        #expect(!SteamLauncher.lineIsSteamClientExe("/usr/libexec/logd"))
        #expect(!SteamLauncher.lineIsSteamClientExe(""))
        #expect(!SteamLauncher.lineIsSteamClientExe("/Applications/Safari.app/Contents/MacOS/Safari"))
        // A substring of the needle must not match.
        #expect(!SteamLauncher.lineIsSteamClientExe("/usr/bin/stea"))
    }

    /// Non-ASCII must not crash or false-negative the prefilter: the bytes of
    /// "steam" are single-byte UTF-8 wherever they appear.
    @Test func unicodeCommandLinesAreSafe() {
        #expect(SteamLauncher.lineIsSteamClientExe(#"C:\Jeux\Ünïcødé\steam.exe"#))
        #expect(!SteamLauncher.lineIsSteamClientExe("日本語のプロセス"))
    }

    /// A game exe that merely lives under a Steam folder is not the client.
    @Test func gameUnderSteamFolderIsNotTheClient() {
        #expect(!SteamLauncher.lineIsSteamClientExe(
            #"C:\Program Files (x86)\Steam\steamapps\common\Slip & Skid\Slip & Skid.exe"#
        ))
    }
}
