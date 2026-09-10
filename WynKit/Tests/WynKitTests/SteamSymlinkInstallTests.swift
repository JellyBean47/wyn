//
//  SteamSymlinkInstallTests.swift
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

/// Wine Steam can list a game on `C:` whose `steamapps/common/<dir>` is only a
/// symlink to an extra library. `FileManager` enumerators do not enter those
/// links, so Wyn used to drop the tile (and `wyn play`) even though Steam
/// showed PLAY. Assetto Corsa on `/Volumes/SSD1TB`, 6 Sep 2026.
@Suite("Steam symlink installs")
struct SteamSymlinkInstallTests {

    private func makeTree() throws -> URL {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: "Library/Caches/com.wyn.gaming/SteamSymlinkInstallTests")
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

    /// The enumerator bug, isolated: a symlink-to-dir looks empty unless we resolve.
    @Test func aDirectorySymlinkStillCountsAsHavingAWindowsExe() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let real = root.appending(path: "real/assettocorsa")
        try writeExe(at: real.appending(path: "acs.exe"))
        let link = root.appending(path: "link/assettocorsa")
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        #expect(SteamLauncher.hasWindowsGameExecutable(in: link))
        let profile = GameProfile(
            id: "assetto-corsa-test",
            name: "Assetto Corsa",
            steamAppId: 244_210,
            exePatterns: ["acs.exe"]
        )
        let exe = SteamLauncher.findGameExecutable(matching: profile, under: link)
        #expect(exe?.lastPathComponent == "acs.exe")
    }

    /// C: holds the manifest + a symlink; the files live elsewhere. Wyn must
    /// still list the app and find `acs.exe` — that is the missing tile.
    @Test func aCDriveSymlinkInstallIsListedAndPlayable() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let bottle = try makeBottle(in: root)
        let steamapps = bottle.url.appending(path: "drive_c/Program Files (x86)/Steam/steamapps")
        let real = root.appending(path: "SSD1TB/SteamLibrary/steamapps/common/assettocorsa")
        try writeExe(at: real.appending(path: "acs.exe"))
        try writeManifest(appId: 9_002_442, name: "Assetto Corsa", installdir: "assettocorsa", in: steamapps)
        try FileManager.default.createSymbolicLink(
            at: steamapps.appending(path: "common/assettocorsa"),
            withDestinationURL: real
        )

        let emptyVolumes = root.appending(path: "no-volumes")
        try FileManager.default.createDirectory(at: emptyVolumes, withIntermediateDirectories: true)

        let apps = SteamLauncher.installedApps(in: bottle, hostVolumesRoot: emptyVolumes)
        #expect(apps.contains { $0.appId == 9_002_442 })

        let profile = GameProfile(
            id: "assetto-corsa-test",
            name: "Assetto Corsa",
            steamAppId: 9_002_442,
            exePatterns: ["acs.exe", "assettocorsa.exe"]
        )
        let exe = SteamLauncher.findGameExecutable(
            forAppId: 9_002_442,
            in: bottle,
            profile: profile,
            hostVolumesRoot: emptyVolumes
        )
        #expect(exe?.lastPathComponent == "acs.exe")
    }

    /// C: has a manifest and an empty folder (no EXE). The extra library has
    /// the files. Play must not stop at C:.
    @Test func anEmptyCDriveStagingFolderDoesNotHideTheRealInstall() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let bottle = try makeBottle(in: root)
        let cApps = bottle.url.appending(path: "drive_c/Program Files (x86)/Steam/steamapps")
        try writeManifest(appId: 9_002_443, name: "Assetto Corsa", installdir: "assettocorsa", in: cApps)
        try FileManager.default.createDirectory(
            at: cApps.appending(path: "common/assettocorsa"),
            withIntermediateDirectories: true
        )

        let extraApps = root.appending(path: "volumes/SSD1TB/SteamLibrary/steamapps")
        try writeManifest(appId: 9_002_443, name: "Assetto Corsa", installdir: "assettocorsa", in: extraApps)
        try writeExe(at: extraApps.appending(path: "common/assettocorsa/acs.exe"))

        let volumes = root.appending(path: "volumes")
        let dir = SteamLauncher.installDirectory(
            forAppId: 9_002_443,
            in: bottle,
            hostVolumesRoot: volumes
        )
        #expect(dir?.lastPathComponent == "assettocorsa")
        #expect(SteamLauncher.hasWindowsGameExecutable(in: try #require(dir)))

        let profile = GameProfile(
            id: "assetto-corsa-test",
            name: "Assetto Corsa",
            steamAppId: 9_002_443,
            exePatterns: ["acs.exe"]
        )
        let exe = SteamLauncher.findGameExecutable(
            forAppId: 9_002_443,
            in: bottle,
            profile: profile,
            hostVolumesRoot: volumes
        )
        #expect(exe?.lastPathComponent == "acs.exe")
    }
}
