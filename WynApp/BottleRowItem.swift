//
//  BottleRowItem.swift
//  Wyn
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
//  A value snapshot of a Bottle for the Bottles section.
//
//  Bottle is a reference type with @Published settings; rendering a grid
//  straight from it means the whole section redraws whenever any bottle's
//  settings change. This captures only what the tile shows.
//

import Foundation
import WynKit

struct BottleRowItem: Identifiable, Hashable {
    let id: URL
    let name: String
    let windowsVersion: String
    let graphics: String
    /// The same value as `graphics`, unstringified, so the tile's Graphics
    /// picker has something to bind to.
    let layer: TranslationLayer
    let url: URL
    /// False until something has run in the bottle and Wine has built the
    /// prefix. Worth showing, so an empty new bottle does not look broken.
    let isInitialised: Bool
    /// Whether launches in this bottle run inside Wine's own desktop — the
    /// answer to a game that goes black or dies on alt-tab.
    let virtualDesktop: Bool

    init(_ bottle: Bottle) {
        self.id = bottle.url
        self.name = bottle.settings.name
        self.windowsVersion = bottle.settings.windowsVersion.pretty()
        self.graphics = bottle.settings.translationLayer.rawValue.uppercased()
        self.layer = bottle.settings.translationLayer
        self.url = bottle.url
        self.isInitialised = FileManager.default.fileExists(
            atPath: bottle.url.appending(path: "drive_c").path(percentEncoded: false)
        )
        self.virtualDesktop = bottle.settings.virtualDesktop
    }

    var subtitle: String {
        isInitialised ? "\(windowsVersion) · \(graphics)" : "\(windowsVersion) · not set up yet"
    }
}
