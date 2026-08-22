//
//  Bundle+Extension.swift
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

public extension Bundle {
    /// On-disk Application Support / Containers / Logs folder.
    /// Always `com.fly.gaming` — see `WynBrand.supportIdentifier`.
    static var wynSupportIdentifier: String {
        WynBrand.supportIdentifier
    }
}
