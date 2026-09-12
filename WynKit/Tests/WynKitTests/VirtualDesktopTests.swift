//
//  VirtualDesktopTests.swift
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

/// Running inside Wine's own desktop is the answer to a title that goes black or
/// dies when macOS focus changes. Measured on DOOM (2016), 12 Sep 2026: alt-tab
/// wrote a second `Created 2 swapchain images … WineMetalView (0x60000388aac0)`
/// beside the startup view `(0x600003891f20)` with no errors at all, and the
/// game carried on rendering at 206% CPU into the view that was no longer on
/// screen. Inside a Wine desktop there is no native surface to lose.
@Suite("Wine virtual desktop")
struct VirtualDesktopTests {

    private let exe = URL(fileURLWithPath: "/Volumes/SSD1TB/SteamLibrary/steamapps/common/DOOM/DOOMx64.exe")

    // MARK: - Size parsing

    @Test func sizesAreNormalised() {
        #expect(Wine.parseVirtualDesktopSize("1920x1080") == "1920x1080")
        #expect(Wine.parseVirtualDesktopSize(" 1920X1080 ") == "1920x1080")
        #expect(Wine.parseVirtualDesktopSize("1024x768") == "1024x768")
    }

    /// Rejected rather than corrected: a desktop silently sized 0x0 is worse
    /// than a launch that says the setting is wrong.
    @Test func nonsenseSizesAreRejected() {
        for bad in ["", "x", "0x0", "1920", "1920x", "x1080", "-1920x1080",
                    "99999x1080", "1920x99999", "abcxdef", "1920 1080", "1920,1080"] {
            #expect(Wine.parseVirtualDesktopSize(bad) == nil, "should reject \(bad)")
        }
    }

    // MARK: - Desktop naming

    /// The name reaches a registry key and a window title, so it stays boring —
    /// and it is derived from the executable so two games get two desktops
    /// instead of fighting over one.
    @Test func namesAreDerivedFromTheExecutable() {
        #expect(Wine.virtualDesktopName(for: exe) == "doomx64")
        // Capped at 24, so this one is truncated — see namesAreLengthCapped.
        #expect(Wine.virtualDesktopName(
            for: URL(fileURLWithPath: "/x/FactoryGameSteam-Win64-Shipping.exe")
        ) == "factorygamesteamwin64shi")
        #expect(Wine.virtualDesktopName(for: URL(fileURLWithPath: "/x/Army Men RTS.exe")) == "armymenrts")
        #expect(Wine.virtualDesktopName(for: URL(fileURLWithPath: "/x/---.exe")) == "wyn")
    }

    @Test func namesAreLengthCapped() {
        let long = URL(fileURLWithPath: "/x/\(String(repeating: "a", count: 80)).exe")
        #expect(Wine.virtualDesktopName(for: long).count == 24)
    }

    // MARK: - The argument vector

    @Test func withoutADesktopTheVectorIsUnchanged() {
        let vector = Wine.launchArgumentVector(
            exe: exe, args: ["+set", "r_fullscreen", "0"],
            workDirWin: #"C:\game"#, virtualDesktop: nil
        )
        #expect(vector == [
            "start", "/d", #"C:\game"#, "/unix",
            "/Volumes/SSD1TB/SteamLibrary/steamapps/common/DOOM/DOOMx64.exe",
            "+set", "r_fullscreen", "0"
        ])
    }

    /// The regression this function exists to prevent. The obvious way to write
    /// it — swap `start` for `explorer` — drops `start /d`, and with it the
    /// working directory. Unreal and most Windows games resolve content through
    /// GetCurrentDirectory, so that is how a game comes up unable to find its
    /// own .uproject. `start /d` must survive *inside* the desktop.
    @Test func aDesktopWrapsTheLaunchAndKeepsTheWorkingDirectory() {
        let vector = Wine.launchArgumentVector(
            exe: exe, args: ["-novid"],
            workDirWin: #"C:\game"#,
            virtualDesktop: Wine.VirtualDesktop(name: "doomx64", size: "1920x1080")
        )
        #expect(vector == [
            "explorer", "/desktop=doomx64,1920x1080",
            "start", "/d", #"C:\game"#, "/unix",
            "/Volumes/SSD1TB/SteamLibrary/steamapps/common/DOOM/DOOMx64.exe",
            "-novid"
        ])
        #expect(vector.contains("/d"))
        #expect(vector[vector.firstIndex(of: "/d")! + 1] == #"C:\game"#)
    }

    // MARK: - Resolving the setting

    @Test func offByDefaultSoNobodyLosesExclusiveFullscreen() {
        let settings = BottleSettings()
        #expect(settings.virtualDesktop == false)
        #expect(Wine.virtualDesktop(for: settings, exe: exe) == nil)
    }

    @Test func enablingItUsesTheConfiguredSize() {
        var settings = BottleSettings()
        settings.virtualDesktop = true
        settings.virtualDesktopSize = "1024x768"
        #expect(Wine.virtualDesktop(for: settings, exe: exe)
                == Wine.VirtualDesktop(name: "doomx64", size: "1024x768"))
    }

    /// An unparseable or empty size must not disable the setting the person
    /// asked for — fall back to the display and still give them a desktop.
    @Test func abadSizeFallsBackToTheDisplayRatherThanOff() {
        var settings = BottleSettings()
        settings.virtualDesktop = true
        for size in ["", "garbage", "0x0"] {
            settings.virtualDesktopSize = size
            let resolved = Wine.virtualDesktop(for: settings, exe: exe)
            #expect(resolved != nil, "\(size) must still produce a desktop")
            #expect(Wine.parseVirtualDesktopSize(resolved?.size ?? "") != nil)
        }
    }

    // MARK: - Profile override and persistence

    @Test func aProfileCanAskForADesktop() {
        let bottle = Bottle(bottleUrl: URL(fileURLWithPath: "/tmp/vd-\(UUID().uuidString)"))
        let profile = GameProfile(
            id: "doom-2016", name: "DOOM", steamAppId: 379_720,
            exePatterns: ["doomx64.exe"],
            bottle: ProfileBottleOverrides(virtualDesktop: true, virtualDesktopSize: "1920x1080"),
            environment: [:], launchArgs: nil, notes: "note", status: .verified
        )
        let settings = ProfileApplicator.launchSettings(profile: profile, bottle: bottle)
        #expect(settings.virtualDesktop)
        #expect(settings.virtualDesktopSize == "1920x1080")
    }

    @Test func aProfileThatSaysNothingLeavesTheBottleAlone() {
        let bottle = Bottle(bottleUrl: URL(fileURLWithPath: "/tmp/vd-\(UUID().uuidString)"))
        bottle.settings.virtualDesktop = true
        bottle.settings.virtualDesktopSize = "1280x720"
        let profile = GameProfile(
            id: "x", name: "X", steamAppId: 1, exePatterns: ["x.exe"],
            bottle: ProfileBottleOverrides(avxEnabled: false),
            environment: [:], launchArgs: nil, notes: "note", status: .guessed
        )
        let settings = ProfileApplicator.launchSettings(profile: profile, bottle: bottle)
        #expect(settings.virtualDesktop)
        #expect(settings.virtualDesktopSize == "1280x720")
    }

    /// Bottles written before this setting existed must keep working, and must
    /// not come back with a desktop switched on.
    @Test func olderBottleJSONDecodesWithItOff() throws {
        let json = #"{"windowsVersion":"win10","enhancedSync":"msync"}"#
        let config = try JSONDecoder().decode(BottleWineConfig.self, from: Data(json.utf8))
        #expect(config.virtualDesktop == false)
        #expect(config.virtualDesktopSize.isEmpty)
    }
}
