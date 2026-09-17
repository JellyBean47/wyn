//
//  SteamLibraryRootsTests.swift
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

/// Extra Steam libraries live on mounted volumes. Wine Steam's own
/// `libraryfolders.vdf` often only lists C:\ — without a host scan, a game
/// already installed on an SSD never appears in Wyn.
@Suite("Steam library roots")
struct SteamLibraryRootsTests {

    private func makeTree() throws -> URL {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: "Library/Caches/com.wyn.gaming/SteamLibraryRootsTests")
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func hostVolumeScanFindsSteamLibraryOnAMountedVolume() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let steamapps = root
            .appending(path: "SSD1TB")
            .appending(path: "SteamLibrary")
            .appending(path: "steamapps")
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)

        let found = SteamLauncher.hostVolumeSteamappsRoots(volumesRoot: root)
        #expect(found.map { $0.standardizedFileURL.path } == [steamapps.standardizedFileURL.path])
    }

    @Test func steamappsRootsIncludesAHostSteamLibraryEvenWhenVDFOmitsIt() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let bottleURL = root.appending(path: "bottle")
        let defaultApps = bottleURL
            .appending(path: "drive_c/Program Files (x86)/Steam/steamapps")
        try FileManager.default.createDirectory(at: defaultApps, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: bottleURL.appending(path: "dosdevices"), withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: bottleURL.appending(path: "dosdevices/z:"),
            withDestinationURL: URL(fileURLWithPath: "/")
        )
        try FileManager.default.createSymbolicLink(
            at: bottleURL.appending(path: "dosdevices/c:"),
            withDestinationURL: bottleURL.appending(path: "drive_c")
        )

        let extra = root
            .appending(path: "volumes/SSD1TB/SteamLibrary/steamapps")
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)

        let bottle = Bottle(bottleUrl: bottleURL)
        let roots = SteamLauncher.steamappsRoots(
            in: bottle,
            hostVolumesRoot: root.appending(path: "volumes")
        )
        let paths = Set(roots.map { SteamLauncher.canonicalPath($0) })
        #expect(paths.contains(SteamLauncher.canonicalPath(defaultApps)))
        #expect(paths.contains(SteamLauncher.canonicalPath(extra)))
    }

    @Test func insertLibraryFolderIsIdempotent() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let vdf = root.appending(path: "libraryfolders.vdf")
        try """
        "libraryfolders"
        {
        	"0"
        	{
        		"path"		"C:\\\\Program Files (x86)\\\\Steam"
        		"apps"
        		{
        		}
        	}
        }
        """.write(to: vdf, atomically: true, encoding: .utf8)

        let extra = #"Z:\Volumes\SSD1TB\SteamLibrary"#
        #expect(SteamLauncher.insertLibraryFolder(at: vdf, windowsPath: extra))
        #expect(!SteamLauncher.insertLibraryFolder(at: vdf, windowsPath: extra))

        let text = try String(contentsOf: vdf, encoding: .utf8)
        let written = #""path"\#t\#t"Z:\\Volumes\\SSD1TB\\SteamLibrary""#
        #expect(text.components(separatedBy: written).count == 2)
    }

    /// The shape Steam itself writes. An unescaped comparison never matched it,
    /// so every launch with Steam closed appended the library again.
    @Test func aLibraryAlreadyWrittenBySteamIsNotAddedAgain() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let vdf = root.appending(path: "libraryfolders.vdf")
        let steamWritten = #"""
        "libraryfolders"
        {
        	"0"
        	{
        		"path"		"C:\\Program Files (x86)\\Steam"
        	}
        	"1"
        	{
        		"path"		"Z:\\Volumes\\SSD1TB\\SteamLibrary"
        		"apps"
        		{
        			"526870"		"0"
        		}
        	}
        }
        """#
        try steamWritten.write(to: vdf, atomically: true, encoding: .utf8)

        #expect(!SteamLauncher.insertLibraryFolder(at: vdf, windowsPath: #"Z:\Volumes\SSD1TB\SteamLibrary"#))
        #expect(try String(contentsOf: vdf, encoding: .utf8) == steamWritten)
    }

    @Test func vdfEscapingRoundTripsWindowsPaths() {
        let path = #"Z:\Volumes\SSD1TB\SteamLibrary"#
        #expect(SteamLauncher.vdfEscaped(path) == #"Z:\\Volumes\\SSD1TB\\SteamLibrary"#)
        #expect(SteamLauncher.vdfUnescaped(SteamLauncher.vdfEscaped(path)) == path)
    }

    @Test func windowsPathUsesZWhenZPointsAtRoot() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let bottleURL = root.appending(path: "bottle")
        try FileManager.default.createDirectory(
            at: bottleURL.appending(path: "dosdevices"), withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: bottleURL.appending(path: "dosdevices/z:"),
            withDestinationURL: URL(fileURLWithPath: "/")
        )
        let bottle = Bottle(bottleUrl: bottleURL)
        let mapped = SteamLauncher.windowsPath(
            forHostURL: URL(fileURLWithPath: "/Volumes/SSD1TB/SteamLibrary"),
            in: bottle
        )
        #expect(mapped == #"Z:\Volumes\SSD1TB\SteamLibrary"#)
    }

    @Test func canonicalPathStripsTheDirectoryTrailingSlashThatFileURLWithPathAdds() {
        let withSlash = URL(fileURLWithPath: "/Volumes/SSD1TB/SteamLibrary/steamapps")
        let appended = URL(fileURLWithPath: "/")
            .appending(path: "Volumes/SSD1TB/SteamLibrary")
            .appending(path: "steamapps")
        #expect(SteamLauncher.canonicalPath(withSlash) == SteamLauncher.canonicalPath(appended))
        #expect(!SteamLauncher.canonicalPath(withSlash).hasSuffix("/"))
    }

    @Test func aVDFLibraryAndAHostVolumeScanDoNotListTheSameGameTwice() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let bottleURL = root.appending(path: "bottle")
        try FileManager.default.createDirectory(
            at: bottleURL.appending(path: "dosdevices"), withIntermediateDirectories: true
        )
        let defaultApps = bottleURL
            .appending(path: "drive_c/Program Files (x86)/Steam/steamapps")
        try FileManager.default.createDirectory(at: defaultApps, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: bottleURL.appending(path: "dosdevices/z:"),
            withDestinationURL: URL(fileURLWithPath: "/")
        )
        try FileManager.default.createSymbolicLink(
            at: bottleURL.appending(path: "dosdevices/c:"),
            withDestinationURL: bottleURL.appending(path: "drive_c")
        )

        let volumes = root.appending(path: "volumes")
        let extraApps = volumes.appending(path: "SSD1TB/SteamLibrary/steamapps")
        try FileManager.default.createDirectory(
            at: extraApps.appending(path: "common/Ready Or Not"),
            withIntermediateDirectories: true
        )
        try Data("MZ".utf8).write(
            to: extraApps.appending(path: "common/Ready Or Not/ReadyOrNot.exe")
        )
        try """
        "AppState"
        {
        \t"appid"\t\t"1144200"
        \t"name"\t\t"Ready or Not"
        \t"installdir"\t\t"Ready Or Not"
        }
        """.write(
            to: extraApps.appending(path: "appmanifest_1144200.acf"),
            atomically: true,
            encoding: .utf8
        )

        let bottle = Bottle(bottleUrl: bottleURL)
        let libraryRoot = extraApps.deletingLastPathComponent()
        let windowsPath = try #require(SteamLauncher.windowsPath(forHostURL: libraryRoot, in: bottle))
        #expect(SteamLauncher.insertLibraryFolder(
            at: defaultApps.appending(path: "libraryfolders.vdf"),
            windowsPath: windowsPath
        ))

        let apps = SteamLauncher.installedApps(in: bottle, hostVolumesRoot: volumes)
        #expect(apps.filter { $0.appId == 1_144_200 }.count == 1)
    }
}
