//
//  LaunchProgress.swift
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
//  Stdout plus an optional TaskLocal sink so the library overlay can show
//  SteamLauncher / ConnectLauncher steps while a launch is in flight.
//

import Foundation

public enum LaunchProgress: Sendable {
    @TaskLocal public static var sink: (@Sendable (String) -> Void)?

    public static func emit(_ message: String) {
        print(message)
        fflush(stdout)
        sink?(message)
    }
}
