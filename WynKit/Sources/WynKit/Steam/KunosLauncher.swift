//
//  KunosLauncher.swift
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

/// Assetto Corsa's 32-bit .NET launcher (`AssettoCorsa.exe`) does not search
/// `launcher/support` on its own. Wine Mono then dies with "could not load
/// CEF3" before any window. The same process later mutates a read-only
/// `NumberFormatInfo` (Wine Mono) and shows "retire from the race".
enum KunosLauncher {
    static func prepare(
        executable: URL,
        bottle: Bottle,
        environment: inout [String: String]
    ) {
        let support = executable
            .deletingLastPathComponent()
            .appending(path: "launcher")
            .appending(path: "support")
        let cef = support.appending(path: "CEF3.dll")
        if FileManager.default.fileExists(atPath: cef.path(percentEncoded: false)) {
            let windows = Wine.windowsPath(for: support, in: bottle)
            prepend(&environment, key: "MONO_PATH", value: windows, separator: ";")
            prepend(
                &environment,
                key: "WINEPATH",
                value: support.path(percentEncoded: false),
                separator: ":"
            )
        }
        if executable.lastPathComponent.lowercased() == "assettocorsa.exe" {
            _ = WineMono.allowMutatingReadOnlyNumberFormat(in: bottle)
        }
    }

    private static func prepend(
        _ environment: inout [String: String],
        key: String,
        value: String,
        separator: String
    ) {
        if let existing = environment[key], !existing.isEmpty {
            let already = existing == value
                || existing.components(separatedBy: separator).contains(value)
            if already {
                return
            }
            environment[key] = "\(value)\(separator)\(existing)"
        } else {
            environment[key] = value
        }
    }
}
