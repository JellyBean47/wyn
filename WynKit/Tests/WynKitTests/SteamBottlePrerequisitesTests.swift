//
//  SteamBottlePrerequisitesTests.swift
//  WynKitTests
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

@Suite("Steam bottle prerequisites")
struct SteamBottlePrerequisitesTests {

    /// A fresh bottle, 29 Sep 2026: no Connect, and Assassin's Creed Odyssey
    /// needs it. Once it is in, launches install nothing.
    @Test func connectIsInstalledOnlyWhenNeededAndAbsent() {
        #expect(SteamBottlePrerequisites.needsConnectInstall(needsConnect: true, connectInstalled: false))
        #expect(!SteamBottlePrerequisites.needsConnectInstall(needsConnect: true, connectInstalled: true))
        #expect(!SteamBottlePrerequisites.needsConnectInstall(needsConnect: false, connectInstalled: false))
    }

    /// The shipped Odyssey profile is the one that failed: it must ask for Connect.
    @Test func acOdysseyNeedsConnect() throws {
        let profile = try #require(ProfileStore.profile(id: "ac-odyssey"))
        #expect(profile.needsUbisoftConnectPlay)
    }

    /// The fallback installer is the copy Ubisoft games ship next to the exe.
    @Test func theGamesOwnInstallerIsTheFallback() throws {
        let dir = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(SteamBottlePrerequisites.localConnectInstaller(in: dir) == nil)
        let installer = dir.appending(path: "UbisoftConnectInstaller.exe")
        FileManager.default.createFile(atPath: installer.path(percentEncoded: false), contents: Data([0x4d, 0x5a]))
        #expect(SteamBottlePrerequisites.localConnectInstaller(in: dir)?.lastPathComponent == "UbisoftConnectInstaller.exe")
    }
}
