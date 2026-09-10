//
//  AssettoCorsaLibraryTests.swift
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

@Suite("Assetto Corsa car/track listing")
struct AssettoCorsaLibraryTests {

    @Test func listsCarsAndLayoutsFromTheInstall() throws {
        let root = try fakeInstall()
        let cars = AssettoCorsaLibrary.cars(in: root)
        #expect(cars.map(\.id) == ["lotus_2_eleven", "lotus_elise_sc", "tatuusfa1"])
        #expect(cars.allSatisfy { $0.playable })
        #expect(cars.contains { $0.displayName.contains("Elise") })

        let tracks = AssettoCorsaLibrary.tracks(in: root)
        #expect(tracks.contains { $0.id == "spa" && $0.layout.isEmpty })
        #expect(tracks.contains {
            $0.id == "ks_nurburgring" && $0.layout == "layout_gp_a"
        })
        #expect(AssettoCorsaLibrary.matchCar("elise", in: cars)?.id == "lotus_elise_sc")
        #expect(
            AssettoCorsaLibrary.matchTrack("ks_nurburgring/layout_gp_a", in: tracks)?.layout
                == "layout_gp_a"
        )
        #expect(AssettoCorsaLibrary.matchTrack("spa", in: tracks)?.id == "spa")
    }

    @Test func applyingOverridesPinsTheChosenCarAndTrack() throws {
        let root = try fakeInstall()
        var profile = try #require(ProfileStore.profile(id: "assetto-corsa"))
        profile = try AssettoCorsaLibrary.applyingOverrides(
            to: profile,
            installRoot: root,
            car: "elise",
            track: "ks_nurburgring/layout_gp_a",
            aiCount: 11,
            aiAggression: 100
        )
        let session = try #require(profile.assettoCorsa)
        #expect(session.car == "lotus_elise_sc")
        #expect(session.track == "ks_nurburgring")
        #expect(session.layout == "layout_gp_a")
        #expect(session.aiCount == 11)
    }

    @Test func unknownCarIsAnError() throws {
        let root = try fakeInstall()
        let profile = try #require(ProfileStore.profile(id: "assetto-corsa"))
        #expect(throws: AssettoCorsaLibrary.PickError.self) {
            try AssettoCorsaLibrary.applyingOverrides(
                to: profile,
                installRoot: root,
                car: "not-a-car",
                track: nil,
                aiCount: nil,
                aiAggression: nil
            )
        }
    }

    @Test func ambiguousCarNamesAskForTheId() throws {
        let root = try fakeInstall()
        let profile = try #require(ProfileStore.profile(id: "assetto-corsa"))
        do {
            _ = try AssettoCorsaLibrary.applyingOverrides(
                to: profile,
                installRoot: root,
                car: "lotus",
                track: nil,
                aiCount: nil,
                aiAggression: nil
            )
            Issue.record("expected ambiguous car")
        } catch let error as AssettoCorsaLibrary.PickError {
            guard case .ambiguousCar(let query, let ids) = error else {
                Issue.record("expected ambiguousCar, got \(error)")
                return
            }
            #expect(query == "lotus")
            #expect(Set(ids) == ["lotus_elise_sc", "lotus_2_eleven"])
        }
    }

    @Test func aDlcStubIsRefused() throws {
        let root = try fakeInstall()
        try writeCar(
            root,
            id: "ks_nissan_skyline_r34",
            name: "Nissan Skyline GT-R R34",
            brand: "Nissan",
            jsonName: "dlc_ui_car.json",
            installed: false
        )
        let profile = try #require(ProfileStore.profile(id: "assetto-corsa"))
        do {
            _ = try AssettoCorsaLibrary.applyingOverrides(
                to: profile,
                installRoot: root,
                car: "skyline",
                track: nil,
                aiCount: nil,
                aiAggression: nil
            )
            Issue.record("expected DLC stub")
        } catch let error as AssettoCorsaLibrary.PickError {
            guard case .dlcCar(let id) = error else {
                Issue.record("expected dlcCar, got \(error)")
                return
            }
            #expect(id == "ks_nissan_skyline_r34")
        }
    }

    private func fakeInstall() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "wyn-ac-lib-\(UUID().uuidString)")
        try writeCar(root, id: "lotus_elise_sc", name: "Lotus Elise SC", brand: "Lotus")
        try writeCar(root, id: "lotus_2_eleven", name: "Lotus 2-Eleven", brand: "Lotus")
        try writeCar(root, id: "tatuusfa1", name: "Tatuus FA1", brand: "Tatuus")
        try writeTrack(root, id: "spa", layout: nil, name: "Spa")
        try writeTrack(root, id: "ks_nurburgring", layout: "layout_gp_a", name: "Nurburgring - GP")
        return root
    }

    @Test func dlcCarsReadTheAlternateUiFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "wyn-ac-dlc-\(UUID().uuidString)")
        try writeCar(
            root,
            id: "ks_lotus_25",
            name: "Lotus Type 25",
            brand: "Lotus",
            jsonName: "dlc_ui_car.json",
            installed: false
        )
        let car = try #require(AssettoCorsaLibrary.cars(in: root).first)
        #expect(car.id == "ks_lotus_25")
        #expect(car.displayName.contains("Type 25"))
        #expect(!car.playable)
    }

    private func writeCar(
        _ root: URL,
        id: String,
        name: String,
        brand: String,
        jsonName: String = "ui_car.json",
        installed: Bool = true
    ) throws {
        let ui = root.appending(path: "content/cars/\(id)/ui")
        try FileManager.default.createDirectory(at: ui, withIntermediateDirectories: true)
        try """
        { "name": "\(name)", "brand": "\(brand)" }
        """.write(to: ui.appending(path: jsonName), atomically: true, encoding: .utf8)
        if installed {
            try Data().write(to: ui.deletingLastPathComponent().appending(path: "data.acd"))
        }
    }

    private func writeTrack(_ root: URL, id: String, layout: String?, name: String) throws {
        let ui: URL
        if let layout {
            ui = root.appending(path: "content/tracks/\(id)/ui/\(layout)")
        } else {
            ui = root.appending(path: "content/tracks/\(id)/ui")
        }
        try FileManager.default.createDirectory(at: ui, withIntermediateDirectories: true)
        try """
        { "name": "\(name)", "pitboxes": "24" }
        """.write(to: ui.appending(path: "ui_track.json"), atomically: true, encoding: .utf8)
    }
}
