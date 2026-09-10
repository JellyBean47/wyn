//
//  BottleFactory.swift
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
//  One place that creates a bottle, so the CLI and the app cannot drift.
//
//  Creation is metadata only: a directory, a BottleSettings, and an entry in
//  BottleData.paths. The Wine prefix itself is initialised lazily on first use,
//  the same way StoreInstaller.ensureBottle leaves it. That is deliberate —
//  running wineboot at create time is exactly what the game-host guardrails
//  say not to do, and it would make "New Bottle" a slow, failure-prone action
//  instead of an instant one.
//

import Foundation

public enum BottleFactory {
    public enum CreateError: LocalizedError, Equatable {
        case emptyName
        case duplicateName(String)

        public var errorDescription: String? {
            switch self {
            case .emptyName:
                return "A bottle needs a name."
            case .duplicateName(let name):
                return "A bottle called \"\(name)\" already exists. Pick another name."
            }
        }
    }

    /// Names that belong to bottles Wyn manages itself. Reusing one would make
    /// the storefront lookups resolve to a user's empty bottle.
    public static func isReservedName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed == SteamLauncher.defaultBottleName.lowercased() { return true }
        return PlatformKind.allCases.contains {
            ($0.dedicatedBottleName ?? "").lowercased() == trimmed && !trimmed.isEmpty
        }
    }

    /// Existing bottle names, for duplicate checks and UI validation.
    public static func existingNames() -> [String] {
        var data = BottleData()
        return data.loadBottles().map(\.settings.name)
    }

    /// Create a bottle and register it. Returns the new bottle.
    ///
    /// `graphics` sets both `translationLayer` and the `dxvk` flag, which have
    /// to agree — a bottle declaring dxvk without the layer launches games on
    /// the wrong backend.
    @discardableResult
    public static func create(
        name: String,
        windows: WinVersion = .win10,
        graphics: TranslationLayer = .dxmt
    ) throws -> Bottle {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CreateError.emptyName }

        var data = BottleData()
        let taken = data.loadBottles().map { $0.settings.name.lowercased() }
        guard !taken.contains(trimmed.lowercased()) else {
            throw CreateError.duplicateName(trimmed)
        }

        let bottleURL = BottleData.defaultBottleDir.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: bottleURL, withIntermediateDirectories: true)

        let bottle = Bottle(bottleUrl: bottleURL, inFlight: true)
        bottle.settings.name = trimmed
        bottle.settings.windowsVersion = windows
        bottle.settings.translationLayer = graphics
        bottle.settings.dxvk = graphics == .dxvk

        // Appending publishes BottleData through its didSet, which is what makes
        // the bottle visible to loadBottles() in this and every other process.
        data.paths.append(bottleURL)
        return bottle
    }
}
