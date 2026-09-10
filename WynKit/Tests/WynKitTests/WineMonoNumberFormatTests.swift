//
//  WineMonoNumberFormatTests.swift
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

@Suite("Wine Mono NumberFormatInfo.VerifyWritable")
struct WineMonoNumberFormatTests {

    /// Captured from wine-mono 11.2.0 mscorlib `NumberFormatInfo.VerifyWritable`.
    private let body = Data([
        0x02, 0x7B, 0xBC, 0x3A, 0x00, 0x04, 0x2C, 0x10,
        0x72, 0xBE, 0x83, 0x01, 0x70, 0x28, 0xFC, 0x17,
        0x00, 0x06, 0x73, 0xD8, 0x0A, 0x00, 0x06, 0x7A, 0x2A
    ])

    @Test func findsTheVerifyWritableBody() {
        var blob = Data(repeating: 0x90, count: 64)
        blob.append(body)
        blob.append(Data(repeating: 0x00, count: 8))
        #expect(WineMono.verifyWritableILOffset(in: blob) == 64)
    }

    @Test func nopsVerifyWritableOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "wyn-mscorlib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dll = dir.appending(path: "mscorlib.dll")
        var blob = Data(repeating: 0x11, count: 32)
        blob.append(body)
        try blob.write(to: dll)

        #expect(WineMono.patchVerifyWritable(at: dll))
        let patched = try Data(contentsOf: dll)
        #expect(patched[32] == 0x2A)
        #expect(WineMono.verifyWritableILOffset(in: patched) == 32)
        #expect(!WineMono.patchVerifyWritable(at: dll), "second pass must be a no-op")
    }
}

@Suite("Kunos launcher sidecar")
struct KunosLauncherTests {
    @Test func prependsMonoPathWhenCEF3IsNextToTheExe() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "wyn-kunos-\(UUID().uuidString)")
        let support = root.appending(path: "launcher").appending(path: "support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data().write(to: support.appending(path: "CEF3.dll"))
        let exe = root.appending(path: "AssettoCorsa.exe")
        try Data().write(to: exe)
        let bottleDir = FileManager.default.temporaryDirectory
            .appending(path: "wyn-bottle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: bottleDir.appending(path: "drive_c"),
            withIntermediateDirectories: true
        )
        let bottle = Bottle(bottleUrl: bottleDir)
        var env: [String: String] = [:]
        KunosLauncher.prepare(executable: exe, bottle: bottle, environment: &env)
        let mono = try #require(env["MONO_PATH"])
        #expect(mono.lowercased().contains("launcher"))
        #expect(mono.lowercased().contains("support"))
        #expect(env["WINEPATH"] == support.path(percentEncoded: false))
    }
}
