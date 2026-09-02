//
//  BottleRowItem.swift
//  Wyn
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
    let url: URL
    /// False until something has run in the bottle and Wine has built the
    /// prefix. Worth showing, so an empty new bottle does not look broken.
    let isInitialised: Bool

    init(_ bottle: Bottle) {
        self.id = bottle.url
        self.name = bottle.settings.name
        self.windowsVersion = bottle.settings.windowsVersion.pretty()
        self.graphics = bottle.settings.translationLayer.rawValue.uppercased()
        self.url = bottle.url
        self.isInitialised = FileManager.default.fileExists(
            atPath: bottle.url.appending(path: "drive_c").path(percentEncoded: false)
        )
    }

    var subtitle: String {
        isInitialised ? "\(windowsVersion) · \(graphics)" : "\(windowsVersion) · not set up yet"
    }
}
