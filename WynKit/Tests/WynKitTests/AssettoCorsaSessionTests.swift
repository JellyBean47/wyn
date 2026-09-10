//
//  AssettoCorsaSessionTests.swift
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

@Suite("Assetto Corsa session files")
struct AssettoCorsaSessionTests {

    @Test func bundledProfileAsksForMonzaAndSevenAI() throws {
        let profile = try #require(ProfileStore.profile(id: "assetto-corsa"))
        let session = try #require(profile.assettoCorsa)
        #expect(session.track == "monza")
        #expect(session.layout.isEmpty)
        #expect(session.car == "lotus_elise_sc")
        #expect(session.aiCount == 7)
        #expect(session.aiAggression == 100)
    }

    @Test func raceIniIsAPracticeGridOnTheChosenTrack() throws {
        let session = AssettoCorsaSession.playableDefault
        let skins = ["0_racing_green", "black_metallic"]
        let text = AssettoCorsaSession.raceIni(session: session, cars: 8, skins: skins)
        #expect(text.contains("TRACK=monza"))
        #expect(text.contains("MODEL=lotus_elise_sc"))
        #expect(text.contains("CARS=8"))
        #expect(text.contains("[SESSION_0]"))
        #expect(text.contains("TYPE=1"))
        #expect(text.contains("SPAWN_SET=PIT"))
        #expect(text.contains("[CAR_0]"))
        #expect(text.contains("[CAR_7]"))
        #expect(text.contains("DRIVER_NAME=Player"))
        #expect(!text.contains("TRACK=magione"))
        #expect(!text.contains("TYPE=3"), "standing start lights are stuck at TTS inf")
        #expect(text.contains("AI_AGGRESSION=100"))
    }

    @Test func entryListMarksThePlayerThenAI() {
        let session = AssettoCorsaSession.playableDefault
        let skins = [
            "0_racing_green", "black_metallic", "blue_metallic", "grey_metallic",
            "orange_metallic", "signature_grey", "silver_metallic", "solid_red",
        ]
        let text = AssettoCorsaSession.entryList(session: session, cars: 8, skins: skins)
        #expect(text.contains("[CAR_0]"))
        #expect(text.contains("[CAR_7]"))
        #expect(!text.contains("[CAR_8]"))
        #expect(text.contains("DRIVER_NAME=Player"))
        #expect(text.contains("DRIVER_NAME=AI 7"))
        #expect(text.contains("AI=0"))
        #expect(text.contains("AI=1"))
        #expect(text.contains("SKIN=0_racing_green"))
        #expect(text.contains("SKIN=solid_red"))
        #expect(text.contains("AI_AGGRESSION=100"))
    }

    @Test func launcherIniOpponentSliderIsPinnedToMax() throws {
        let cfg = FileManager.default.temporaryDirectory
            .appending(path: "wyn-ac-launcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cfg, withIntermediateDirectories: true)
        try "[SAVED]\r\nAI_AGGRESSION=0\r\nTRACK=magione\r\n".write(
            to: cfg.appending(path: "launcher.ini"),
            atomically: true,
            encoding: .utf8
        )
        AssettoCorsaSession.pinLauncherAggression(in: cfg, value: 100)
        let text = try String(contentsOf: cfg.appending(path: "launcher.ini"), encoding: .utf8)
        #expect(text.contains("AI_AGGRESSION=100"))
        #expect(!text.contains("AI_AGGRESSION=0"))
    }

    @Test func carCountRespectsPitboxes() {
        #expect(AssettoCorsaSession.carCount(aiCount: 7, pitboxes: 26) == 8)
        #expect(AssettoCorsaSession.carCount(aiCount: 40, pitboxes: 18) == 18)
        #expect(AssettoCorsaSession.carCount(aiCount: -3, pitboxes: 18) == 1)
    }

    @Test func writeLeavesExistingFilesWhenTheTrackIsMissing() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "wyn-ac-missing-\(UUID().uuidString)")
        let cfg = root.appending(path: "cfg")
        try FileManager.default.createDirectory(at: cfg, withIntermediateDirectories: true)
        let race = cfg.appending(path: "race.ini")
        try "TRACK=magione\nCARS=1\n".write(to: race, atomically: true, encoding: .utf8)

        let written = AssettoCorsaSession.write(
            .playableDefault,
            installRoot: root
        )
        #expect(written.isEmpty)
        #expect(try String(contentsOf: race, encoding: .utf8).contains("TRACK=magione"))
        #expect(
            !FileManager.default.fileExists(
                atPath: cfg.appending(path: "entry_list.ini").path(percentEncoded: false)
            )
        )
    }

    @Test func writeLeavesExistingFilesWhenTheCarIsADLCStub() throws {
        let root = try fakeInstall()
        let stub = root.appending(path: "content/cars/ks_nissan_skyline_r34/ui")
        try FileManager.default.createDirectory(at: stub, withIntermediateDirectories: true)
        try #"{ "name": "Nissan Skyline GT-R R34" }"#.write(
            to: stub.appending(path: "dlc_ui_car.json"),
            atomically: true,
            encoding: .utf8
        )
        let written = AssettoCorsaSession.write(
            AssettoCorsaSession(
                track: "monza",
                car: "ks_nissan_skyline_r34",
                aiCount: 1
            ),
            installRoot: root
        )
        #expect(written.isEmpty)
        let race = try String(
            contentsOf: root.appending(path: "cfg/race.ini"),
            encoding: .utf8
        )
        #expect(race.contains("TRACK=magione"))
    }

    @Test func writePutsAMonzaGridNextToTheSim() throws {
        let root = try fakeInstall()
        let written = AssettoCorsaSession.write(.playableDefault, installRoot: root)
        #expect(written.count == 2)

        let race = try String(
            contentsOf: root.appending(path: "cfg/race.ini"),
            encoding: .utf8
        )
        let entry = try String(
            contentsOf: root.appending(path: "cfg/entry_list.ini"),
            encoding: .utf8
        )
        #expect(race.contains("TRACK=monza"))
        #expect(race.contains("CARS=8"))
        #expect(race.contains("TYPE=1"))
        #expect(race.contains("DRIVER_NAME=Player"))
        #expect(entry.contains("[CAR_7]"))
        #expect(entry.contains("MODEL=lotus_elise_sc"))

        let backup = root.appending(path: "cfg/race.ini.wynbak")
        #expect(FileManager.default.fileExists(atPath: backup.path(percentEncoded: false)))
        #expect(try String(contentsOf: backup, encoding: .utf8).contains("TRACK=magione"))
    }

    @Test func writeMirrorsIntoBottleDocumentsCfg() throws {
        let root = try fakeInstall()
        let bottleDir = FileManager.default.temporaryDirectory
            .appending(path: "wyn-ac-bottle-\(UUID().uuidString)")
        let docs = bottleDir
            .appending(path: "drive_c/users/crossover/Documents/Assetto Corsa/cfg")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try "TRACK=magione\n".write(
            to: docs.appending(path: "race.ini"),
            atomically: true,
            encoding: .utf8
        )
        let bottle = Bottle(bottleUrl: bottleDir)

        let written = AssettoCorsaSession.write(
            .playableDefault,
            installRoot: root,
            bottle: bottle
        )
        #expect(written.count == 4)
        let docsRace = try String(
            contentsOf: docs.appending(path: "race.ini"),
            encoding: .utf8
        )
        #expect(docsRace.contains("TRACK=monza"))
        #expect(docsRace.contains("CARS=8"))
    }

    @Test func aSessionChangeIsPartOfTheLaunchFingerprint() {
        var a = GameProfile(id: "assetto-corsa", name: "AC", exePatterns: ["acs.exe"])
        var b = a
        a.assettoCorsa = .playableDefault
        b.assettoCorsa = AssettoCorsaSession(
            track: "magione",
            car: "lotus_elise_sc",
            aiCount: 0
        )
        #expect(a.settingsFingerprint != b.settingsFingerprint)
    }

    @Test func aRememberedPickOutranksTheBundledProfile() throws {
        let root = try fakeInstall()
        let remembered = AssettoCorsaSession(
            track: "monza",
            car: "lotus_elise_sc",
            aiCount: 11,
            aiAggression: 80
        )
        let urls = AssettoCorsaSession.persistUser(remembered, installRoot: root)
        #expect(!urls.isEmpty)
        let resolved = AssettoCorsaSession.resolved(
            declared: .playableDefault,
            installRoot: root
        )
        #expect(resolved?.aiCount == 11)
        #expect(resolved?.aiAggression == 80)
        #expect(resolved?.car == "lotus_elise_sc")
    }

    private func fakeInstall() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "wyn-ac-install-\(UUID().uuidString)")
        let track = root.appending(path: "content/tracks/monza/ui")
        let skins = root.appending(path: "content/cars/lotus_elise_sc/skins")
        try FileManager.default.createDirectory(at: track, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skins, withIntermediateDirectories: true)
        try #"""
        { "name": "Monza", "pitboxes": "26" }
        """#.write(
            to: track.appending(path: "ui_track.json"),
            atomically: true,
            encoding: .utf8
        )
        for name in [
            "0_racing_green", "black_metallic", "blue_metallic", "grey_metallic",
            "orange_metallic", "signature_grey", "silver_metallic", "solid_red",
        ] {
            try FileManager.default.createDirectory(
                at: skins.appending(path: name),
                withIntermediateDirectories: true
            )
        }
        try Data().write(to: skins.deletingLastPathComponent().appending(path: "data.acd"))
        let cfg = root.appending(path: "cfg")
        try FileManager.default.createDirectory(at: cfg, withIntermediateDirectories: true)
        try "TRACK=magione\nCARS=1\n".write(
            to: cfg.appending(path: "race.ini"),
            atomically: true,
            encoding: .utf8
        )
        return root
    }
}
