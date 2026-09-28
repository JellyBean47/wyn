//
//  ExecutableSubstitutionTests.swift
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

/// DOOM (2016)'s OpenGL `DOOMx64.exe` cannot run here and its Vulkan build can.
/// Steam launches the first and restores it whenever it checks the install,
/// so Wyn puts the second in its place at every launch. 28 Sep 2026: a fresh
/// Steam client's "update" at the same BuildID rewrote the file and DOOM died
/// with `wglCreateContextAttribsARB failed`.
@Suite("Executable substitutions")
struct ExecutableSubstitutionTests {
    static let doom = ExecutableSubstitution(replace: "DOOMx64.exe", with: "DOOMx64vk.exe")
    static let openGL = Data("opengl-build".utf8)
    static let vulkan = Data("vulkan-build-which-is-larger".utf8)

    @Test func theStoresFileIsReplacedAndKept() throws {
        let game = try GameFolder()
        defer { game.cleanUp() }
        try game.write("DOOMx64.exe", Self.openGL)
        try game.write("DOOMx64vk.exe", Self.vulkan)

        let outcome = ExecutableSubstitutions.apply([Self.doom], in: game.root)

        #expect(outcome == [.substituted("DOOMx64.exe")])
        #expect(try game.read("DOOMx64.exe") == Self.vulkan)
        #expect(try game.read("DOOMx64.exe.wyn-bak") == Self.openGL)
        #expect(!game.exists(".DOOMx64.exe.wyn-staging"))
    }

    @Test func applyingTwiceChangesNothing() throws {
        let game = try GameFolder()
        defer { game.cleanUp() }
        try game.write("DOOMx64.exe", Self.openGL)
        try game.write("DOOMx64vk.exe", Self.vulkan)
        ExecutableSubstitutions.apply([Self.doom], in: game.root)

        let second = ExecutableSubstitutions.apply([Self.doom], in: game.root)

        #expect(second == [.alreadyInPlace("DOOMx64.exe")])
        #expect(try game.read("DOOMx64.exe.wyn-bak") == Self.openGL)
    }

    /// The case this exists for: Steam repairs the file, Wyn re-applies. And
    /// when Steam's file is a newer build, the backup follows it rather than
    /// keeping a stale one.
    @Test func aSteamRepairIsUndoneAndTheBackupTracksSteam() throws {
        let game = try GameFolder()
        defer { game.cleanUp() }
        try game.write("DOOMx64.exe", Self.openGL)
        try game.write("DOOMx64vk.exe", Self.vulkan)
        ExecutableSubstitutions.apply([Self.doom], in: game.root)

        let patched = Data("opengl-build-patched".utf8)
        try game.write("DOOMx64.exe", patched)   // Steam "repairs" it
        let outcome = ExecutableSubstitutions.apply([Self.doom], in: game.root)

        #expect(outcome == [.substituted("DOOMx64.exe")])
        #expect(try game.read("DOOMx64.exe") == Self.vulkan)
        #expect(try game.read("DOOMx64.exe.wyn-bak") == patched)
    }

    @Test func aMissingSourceLeavesTheGameAlone() throws {
        let game = try GameFolder()
        defer { game.cleanUp() }
        try game.write("DOOMx64.exe", Self.openGL)

        let outcome = ExecutableSubstitutions.apply([Self.doom], in: game.root)

        guard case .skipped("DOOMx64.exe", _) = outcome.first else {
            Issue.record("expected a skip, got \(outcome)")
            return
        }
        #expect(try game.read("DOOMx64.exe") == Self.openGL)
        #expect(!game.exists("DOOMx64.exe.wyn-bak"))
    }

    /// A profile is data anyone can write. It must not reach outside the game.
    @Test func pathsCannotLeaveTheInstallFolder() throws {
        let root = URL(fileURLWithPath: "/games/DOOM")
        #expect(ExecutableSubstitutions.contained("../../etc/x", in: root) == nil)
        #expect(ExecutableSubstitutions.contained("/etc/x", in: root) == nil)
        #expect(ExecutableSubstitutions.contained("bin\\x.exe", in: root) == nil)
        #expect(ExecutableSubstitutions.contained("", in: root) == nil)
        #expect(ExecutableSubstitutions.contained("bin/./x.exe", in: root) == nil)
        #expect(ExecutableSubstitutions.contained("bin/x.exe", in: root)?.path == "/games/DOOM/bin/x.exe")
    }

    /// The shipped DOOM profile declares it, and older profiles without the
    /// key still decode (to none).
    @Test func doomDeclaresItAndOthersDefaultToNone() throws {
        let doom = try #require(ProfileStore.profile(id: "doom-2016"))
        #expect(doom.executableSubstitutions == [Self.doom])

        let bare = #"{"id":"x","name":"X"}"#
        let decoded = try JSONDecoder().decode(GameProfile.self, from: Data(bare.utf8))
        #expect(decoded.executableSubstitutions.isEmpty)
    }
}

/// Under `$HOME`, never `/tmp`: `/tmp/Wyn*` trees are what the uninstaller sweeps.
private struct GameFolder {
    let root: URL

    init() throws {
        root = URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: "Library/Caches/com.wyn.gaming/ExecutableSubstitutionTests")
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ name: String, _ data: Data) throws { try data.write(to: root.appending(path: name)) }
    func read(_ name: String) throws -> Data { try Data(contentsOf: root.appending(path: name)) }
    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: name).path(percentEncoded: false))
    }
    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}
