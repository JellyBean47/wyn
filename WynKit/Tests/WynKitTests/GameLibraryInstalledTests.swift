//
//  GameLibraryInstalledTests.swift
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

/// Games already installed on a host `SteamLibrary` must show up as their
/// catalog profile (Ready or Not, not `steam-1144200`) so Play can run them.
@Suite("Game library installed listing")
struct GameLibraryInstalledTests {

    private func makeTree() throws -> URL {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: "Library/Caches/com.wyn.gaming/GameLibraryInstalledTests")
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeBottle(in root: URL) throws -> Bottle {
        let bottleURL = root.appending(path: "bottle")
        try FileManager.default.createDirectory(
            at: bottleURL.appending(path: "dosdevices"), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: bottleURL.appending(path: "drive_c/Program Files (x86)/Steam/steamapps/common"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: bottleURL.appending(path: "dosdevices/z:"),
            withDestinationURL: URL(fileURLWithPath: "/")
        )
        try FileManager.default.createSymbolicLink(
            at: bottleURL.appending(path: "dosdevices/c:"),
            withDestinationURL: bottleURL.appending(path: "drive_c")
        )
        return Bottle(bottleUrl: bottleURL)
    }

    private func writeManifest(appId: Int, name: String, installdir: String, in steamapps: URL) throws {
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)
        let body = """
        "AppState"
        {
        \t"appid"\t\t"\(appId)"
        \t"name"\t\t"\(name)"
        \t"installdir"\t\t"\(installdir)"
        }
        """
        try body.write(
            to: steamapps.appending(path: "appmanifest_\(appId).acf"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func writeExe(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("MZ".utf8).write(to: url)
    }

    @Test func aHostLibraryCatalogTitleUsesItsProfileNotASyntheticSteamId() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let bottle = try makeBottle(in: root)
        let volumes = root.appending(path: "volumes")
        let steamapps = volumes.appending(path: "SSD1TB/SteamLibrary/steamapps")
        try writeManifest(
            appId: 1_144_200,
            name: "Ready or Not",
            installdir: "Ready Or Not",
            in: steamapps
        )
        try writeExe(
            at: steamapps.appending(
                path: "common/Ready Or Not/ReadyOrNot/Binaries/Win64/ReadyOrNotSteam-Win64-Shipping.exe"
            )
        )
        try writeManifest(
            appId: 9_001_144,
            name: "Unprofiled Title",
            installdir: "Unprofiled",
            in: steamapps
        )
        try writeExe(at: steamapps.appending(path: "common/Unprofiled/game.exe"))

        let items = GameLibrary.installed(in: bottle, hostVolumesRoot: volumes)
        #expect(items.contains { $0.profile.id == "ready-or-not" })
        #expect(items.contains { $0.profile.id == "steam-9001144" })
        #expect(!items.contains { $0.profile.id == "steam-1144200" })

        let report = GameLibrary.describeInstalled(in: bottle, hostVolumesRoot: volumes)
        #expect(report.contains("Ready or Not"))
        #expect(report.contains("profile=ready-or-not"))
        // The catalog column carries the bundled claim, so read the claim from
        // the profile instead of pinning a status here: `ready-or-not` went
        // guessed → verified and broke this test, which is about the listing,
        // not about the ladder. `onlyMeasuredProfilesClaimVerified` is where a
        // verified claim is deliberately enumerated by name.
        let readyOrNot = try #require(ProfileStore.loadAll().first { $0.id == "ready-or-not" })
        #expect(report.contains("profile=ready-or-not  catalog=\(readyOrNot.status.rawValue)"))
        #expect(report.contains("profile=none"))
        #expect(report.contains("thisMac=no profile"))
    }
}
