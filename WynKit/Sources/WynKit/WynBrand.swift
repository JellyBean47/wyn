//
//  WynBrand.swift
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

/// Product identity. "wyn" is Afrikaans/Dutch for wine — same alcohol-naming
/// family as Whisky, the Wine wrapper this tree started from.
public enum WynBrand {
    public static let name = "Wyn"
    public static let command = "wyn"

    /// Logger / future app id. The CLI has no bundle identifier of its own.
    public static let bundleIdentifier = "com.wyn.gaming"

    /// Frozen on-disk folder name. Bottles, Wine trees, logs, and Tools scripts
    /// live here. Do not change — renaming would orphan the Steam bottle and
    /// multi-GB `Libraries/` trees already installed under `com.fly.gaming`.
    public static let supportIdentifier = "com.fly.gaming"
}
