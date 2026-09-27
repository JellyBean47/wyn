//
//  SteamTreeTests.swift
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

/// Is "frankea Steam" a separate Wine, or the game-host Wine under another name?
///
/// The answer decides whether Steam's window keeps the steamwebhelper shim. On
/// the 1.1 bundled runtime `Libraries.steam` is a symlink back to `Libraries`,
/// and treating it as a separate tree removed the shim: DOOM's Play (00:30:44)
/// and a D3DMetal rollback (00:46:49) both left Steam's window black, 28 Sep 2026.
@Suite("Steam's Wine tree")
struct SteamTreeTests {

    /// The 1.1 layout, exactly: `Libraries.steam -> Libraries`.
    @Test func aSymlinkBackToTheGameTreeIsTheSameTree() throws {
        let fixture = try TreeFixture()
        defer { fixture.cleanUp() }
        let game = try fixture.makeTree("Libraries")
        let steam = try fixture.link("Libraries.steam", to: game)
        #expect(WynWineInstaller.isSameTree(steam, game))
    }

    /// The 1.0 layout: frankea is a real, different tree. Its CEF draws without
    /// the shim, and that behaviour must not change.
    @Test func aSeparateFrankeaTreeIsNotTheSameTree() throws {
        let fixture = try TreeFixture()
        defer { fixture.cleanUp() }
        let game = try fixture.makeTree("Libraries")
        let frankea = try fixture.makeTree("Libraries.dxmt-wine11.0")
        let steam = try fixture.link("Libraries.steam", to: frankea)
        #expect(!WynWineInstaller.isSameTree(steam, game))
    }

    /// A trailing slash or a `..` hop must not turn one tree into two.
    @Test func spellingDoesNotMatter() throws {
        let fixture = try TreeFixture()
        defer { fixture.cleanUp() }
        let game = try fixture.makeTree("Libraries")
        let roundabout = game.appending(path: "Wine").appending(path: "..")
        #expect(WynWineInstaller.isSameTree(roundabout, game))
        #expect(WynWineInstaller.isSameTree(URL(fileURLWithPath: game.path + "/"), game))
    }
}

/// Under `$HOME`, never `/tmp`: `/tmp/Wyn*` trees are what the uninstaller sweeps.
private struct TreeFixture {
    let root: URL

    init() throws {
        root = URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: "Library/Caches/com.wyn.gaming/SteamTreeTests")
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func makeTree(_ name: String) throws -> URL {
        let tree = root.appending(path: name)
        try FileManager.default.createDirectory(
            at: tree.appending(path: "Wine").appending(path: "bin"),
            withIntermediateDirectories: true
        )
        return tree
    }

    func link(_ name: String, to target: URL) throws -> URL {
        let link = root.appending(path: name)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        return link
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}
