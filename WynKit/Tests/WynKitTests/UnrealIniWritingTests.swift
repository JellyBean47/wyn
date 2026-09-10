//
//  UnrealIniWritingTests.swift
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

/// UE ini writing used to splice keys onto the section header line:
///
///     [SystemSettings]r.GPUStats=0
///     [/Script/WindowsTargetPlatform.WindowsTargetSettings]DefaultGraphicsRHI=DefaultGraphicsRHI_DX11
///
/// Both were found in a live bottle's Engine.ini. UE does not parse a key that
/// is glued to its header, so `DefaultGraphicsRHI_DX11` — the D3D11 pin that
/// exists because D3D12 is unavailable under DXMT — was never actually applied
/// by config. Satisfactory only got D3D11 because its profile passes `-dx11`.
///
/// Cause: `(?m)^\s*KEY\s*=.*$`. `\s` matches newlines, so `^\s*` reached back
/// over the line break before the key and the replacement landed against the
/// header. There was already a "repair the smash" step, but this same regex
/// re-smashed the line on the next pass, so the file never converged.
@Suite("Unreal ini writing")
struct UnrealIniWritingTests {
    private func tempIni(_ contents: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "wyn-ini-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "Engine.ini")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - The smash

    @Test("key never lands on the section header line")
    func keyStaysOnItsOwnLine() throws {
        let url = try tempIni("[Foo]\nBar=1\n\n[SystemSettings]\nr.Other=2\n")
        try UnrealCompatibility.upsertKey(
            in: url, section: "[SystemSettings]", key: "r.GPUStats", value: "0"
        )
        let out = try read(url)
        // A new key appends after the section's existing keys, so assert the
        // invariant that actually matters: it is on a line of its own and the
        // header is still followed by a break.
        #expect(!out.contains("[SystemSettings]r.GPUStats"))
        #expect(out.contains("\nr.GPUStats=0"))
        #expect(out.contains("[SystemSettings]\n"))
        #expect(out.contains("r.Other=2"), "must not disturb sibling keys")
    }

    @Test("an existing key is replaced in place, not glued to the header")
    func replacesExistingKeyInPlace() throws {
        let url = try tempIni("[SystemSettings]\nr.GPUStats=1\n")
        try UnrealCompatibility.upsertKey(
            in: url, section: "[SystemSettings]", key: "r.GPUStats", value: "0"
        )
        let out = try read(url)
        #expect(out.contains("[SystemSettings]\nr.GPUStats=0"))
        #expect(!out.contains("r.GPUStats=1"))
        #expect(!out.contains("[SystemSettings]r.GPUStats"))
    }

    @Test("a file already smashed on disk is repaired")
    func repairsExistingSmash() throws {
        let url = try tempIni("[Foo]\nBar=1\n[SystemSettings]r.GPUStats=0\n")
        try UnrealCompatibility.upsertKey(
            in: url, section: "[SystemSettings]", key: "r.GPUStats", value: "0"
        )
        let out = try read(url)
        #expect(!out.contains("[SystemSettings]r.GPUStats"), "the repair must actually stick")
        #expect(out.contains("[SystemSettings]\nr.GPUStats=0"))
    }

    @Test("the real pinDX11 section header survives")
    func windowsTargetSettingsHeaderSurvives() throws {
        let section = "[/Script/WindowsTargetPlatform.WindowsTargetSettings]"
        let url = try tempIni("[Foo]\nBar=1\n")
        try UnrealCompatibility.upsertKey(
            in: url, section: section, key: "DefaultGraphicsRHI", value: "DefaultGraphicsRHI_DX11"
        )
        try UnrealCompatibility.upsertKey(
            in: url, section: section, key: "DefaultGraphicsRHI", value: "DefaultGraphicsRHI_DX11"
        )
        let out = try read(url)
        #expect(!out.contains("\(section)DefaultGraphicsRHI"))
        #expect(out.contains("\(section)\nDefaultGraphicsRHI=DefaultGraphicsRHI_DX11"))
    }

    // MARK: - Convergence

    @Test("writing the same value twice is a no-op")
    func isIdempotent() throws {
        let url = try tempIni("[SystemSettings]\nr.GPUStats=1\n")
        try UnrealCompatibility.upsertKey(
            in: url, section: "[SystemSettings]", key: "r.GPUStats", value: "0"
        )
        let first = try read(url)
        try UnrealCompatibility.upsertKey(
            in: url, section: "[SystemSettings]", key: "r.GPUStats", value: "0"
        )
        #expect(try read(url) == first, "repeated writes must converge, not drift")
    }

    // MARK: - CRLF

    @Test("CRLF files keep CRLF")
    func preservesCRLF() throws {
        let url = try tempIni("[Foo]\r\nBar=1\r\n\r\n[SystemSettings]\r\nr.Other=2\r\n")
        try UnrealCompatibility.upsertKey(
            in: url, section: "[SystemSettings]", key: "r.GPUStats", value: "0"
        )
        let out = try read(url)
        #expect(!out.contains("[SystemSettings]r.GPUStats"))
        #expect(out.contains("[SystemSettings]\r\n"), "header must keep its CRLF")
        #expect(out.contains("r.GPUStats=0"))
        // No bare LF anywhere: every \n must be preceded by \r.
        let bareLF = zip(out, out.dropFirst()).contains { $0 != "\r" && $1 == "\n" }
        #expect(!bareLF, "no bare LF may be spliced into a CRLF file")
    }

    @Test("replacing a key in a CRLF file does not strip that line's CR")
    func crlfKeyReplacementKeepsCR() throws {
        let url = try tempIni("[SystemSettings]\r\nr.GPUStats=1\r\nr.Other=2\r\n")
        try UnrealCompatibility.upsertKey(
            in: url, section: "[SystemSettings]", key: "r.GPUStats", value: "0"
        )
        let out = try read(url)
        #expect(out.contains("r.GPUStats=0\r\n"), "`.*$` used to eat the CR")
        #expect(out.contains("r.Other=2\r\n"))
    }

    @Test("appending a new section to a CRLF file keeps CRLF")
    func appendsWithFileLineEnding() throws {
        let url = try tempIni("[Foo]\r\nBar=1\r\n")
        try UnrealCompatibility.upsertKey(
            in: url, section: "[SystemSettings]", key: "r.GPUStats", value: "0"
        )
        let out = try read(url)
        #expect(out.contains("Bar=1\r\n"), "the last existing line must keep its own ending")
        #expect(out.contains("[SystemSettings]\r\nr.GPUStats=0"))
    }

    // MARK: - removeKey

    @Test("removeKey deletes only its own line")
    func removeKeyDoesNotMergeLines() throws {
        let url = try tempIni("[SystemSettings]\nr.Keep=1\nr.RHICmdBypass=1\nr.AlsoKeep=2\n")
        try UnrealCompatibility.removeKey(
            in: url, section: "[SystemSettings]", key: "r.RHICmdBypass"
        )
        let out = try read(url)
        #expect(!out.contains("r.RHICmdBypass"))
        #expect(out.contains("r.Keep=1\n"), "the line above must not be merged away")
        #expect(out.contains("r.AlsoKeep=2"))
        #expect(out.contains("[SystemSettings]\nr.Keep=1"))
    }

    @Test("removeKey on the first key in a section keeps the header intact")
    func removeFirstKeyKeepsHeader() throws {
        let url = try tempIni("[SystemSettings]\nr.RHIThread.Enable=1\nr.Keep=1\n")
        try UnrealCompatibility.removeKey(
            in: url, section: "[SystemSettings]", key: "r.RHIThread.Enable"
        )
        let out = try read(url)
        #expect(!out.contains("r.RHIThread.Enable"))
        #expect(out.contains("[SystemSettings]\nr.Keep=1"))
    }

    // MARK: - lineEnding

    @Test("line ending detection")
    func detectsLineEnding() {
        #expect(UnrealCompatibility.lineEnding(of: "a\r\nb") == "\r\n")
        #expect(UnrealCompatibility.lineEnding(of: "a\nb") == "\n")
        #expect(UnrealCompatibility.lineEnding(of: "") == "\n")
    }

    // MARK: - Playable scalability (opt out of Low+40)

    @Test("gameUserSettingsSections finds every *GameUserSettings header")
    func findsAllUserSettingsSections() {
        let contents = """
        [/Script/ReadyOrNot.FGGameUserSettings]
        FrameRateLimit=40.000000

        [/Script/ReadyOrNot.ReadyOrNotGameUserSettings]
        FrameRateLimit=0.000000

        [/Script/Engine.GameUserSettings]
        bUseVSync=False
        """
        let sections = UnrealCompatibility.gameUserSettingsSections(
            in: contents, projectName: "ReadyOrNot"
        )
        #expect(sections.contains("[/Script/ReadyOrNot.FGGameUserSettings]"))
        #expect(sections.contains("[/Script/ReadyOrNot.ReadyOrNotGameUserSettings]"))
        #expect(sections.contains("[/Script/Engine.GameUserSettings]"))
        #expect(sections.count == 3)
    }

    @Test("resolutionFromLaunchArgs reads ResX and ResY")
    func resolutionFromLaunchArgs() {
        let parsed = UnrealCompatibility.resolutionFromLaunchArgs([
            "-dx11", "-windowed", "-ResX=1920", "-ResY=1080", "-log"
        ])
        #expect(parsed?.width == 1920)
        #expect(parsed?.height == 1080)
        #expect(UnrealCompatibility.resolutionFromLaunchArgs(["-dx11"]) == nil)
        #expect(UnrealCompatibility.resolutionFromLaunchArgs(["-ResX=1920"]) == nil)
    }

    @Test("absent GameUserSettings falls back to the FG section")
    func emptyFileFallsBackToFG() {
        let sections = UnrealCompatibility.gameUserSettingsSections(
            in: "", projectName: "ReadyOrNot"
        )
        #expect(sections == ["[/Script/ReadyOrNot.FGGameUserSettings]"])
    }

    @Test("pinPlayableScalability clears leftover Low+40 in every section")
    func pinPlayableClearsLowCap() throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let bottleURL = root.appending(path: "bottle")
        let config = bottleURL.appending(
            path: "drive_c/users/crossover/AppData/Local/ReadyOrNot/Saved/Config/Windows"
        )
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let ini = config.appending(path: "GameUserSettings.ini")
        try """
        [/Script/ReadyOrNot.FGGameUserSettings]
        FrameRateLimit=40.000000
        bUseVSync=False

        [/Script/ReadyOrNot.ReadyOrNotGameUserSettings]
        FrameRateLimit=40.000000
        ViewDistanceQuality=0

        [ScalabilityGroups]
        sg.ViewDistanceQuality=0
        sg.ResolutionQuality=50
        """.write(to: ini, atomically: true, encoding: .utf8)

        let bottle = Bottle(bottleUrl: bottleURL)
        let written = try UnrealCompatibility.pinPlayableScalability(
            in: bottle, projectName: "ReadyOrNot"
        )
        #expect(!written.isEmpty)
        let out = try read(ini)
        #expect(!out.contains("FrameRateLimit=40"))
        #expect(out.contains("FrameRateLimit=0.000000"))
        #expect(out.contains("bUseVSync=True"))
        #expect(out.contains("sg.ViewDistanceQuality=2"))
        #expect(out.contains("sg.ResolutionQuality=100"))
        #expect(out.contains("ViewDistanceQuality=2"))
        #expect(out.contains("FullscreenMode=2"))
    }
}
