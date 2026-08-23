//
//  RuntimeIntegrity.swift
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

import CryptoKit
import Foundation

/// Hash pins and GPTK-in-tarball guards. Keep SHA-256 values in sync with
/// `scripts/runtime-pins.env` and `DEPENDENCIES.md`.
public enum RuntimeIntegrity {
    public struct Pin: Sendable {
        public let url: URL
        public let sha256: String
        public let version: String
    }

    public static let whiskyCDN = Pin(
        url: URL(string: "https://github.com/frankea/Whisky/releases/download/v3.1.1/Libraries.tar.gz")!,
        sha256: "01f3a1b43b98065fe20c529c1023b61dd79a6d2ad93bba6040865f646481ccf3",
        version: "3.1.1"
    )

    public static let gptkAware = Pin(
        url: URL(string: "https://github.com/EricSpencer00/Whisky/releases/download/wine-v26.1.0-foss-phase1l/Libraries.tar.gz")!,
        sha256: "645917a4135c2ce83047186b6a352bf0d03ff785468e0c276db800ae044ab634",
        version: "wine-v26.1.0-foss-phase1l"
    )

    public static let applePayloadMarkers = [
        "D3DMetal.framework",
        "libd3dshared.dylib",
        "libmetalirconverter.dylib"
    ]

    public enum IntegrityError: LocalizedError, Equatable {
        case hashMismatch(expected: String, actual: String)
        case containsAppleGPTK(String)
        case tarListFailed(String)

        public var errorDescription: String? {
            switch self {
            case .hashMismatch(let expected, let actual):
                return "Wine tarball SHA-256 mismatch (expected \(expected), got \(actual)). Refusing to install. See DEPENDENCIES.md."
            case .containsAppleGPTK(let name):
                return "Archive or directory contains Apple GPTK file \(name). Wyn will not unpack or copy it. Obtain GPTK from Apple and use: wyn gptk install --from <path>"
            case .tarListFailed(let detail):
                return "Could not list tarball contents: \(detail)"
            }
        }
    }

    public static func sha256Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024)
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func verifySHA256(of file: URL, expected: String) throws {
        let actual = try sha256Hex(of: file)
        guard actual.lowercased() == expected.lowercased() else {
            throw IntegrityError.hashMismatch(
                expected: expected.lowercased(),
                actual: actual.lowercased()
            )
        }
    }

    public static func assertNoAppleGPTK(inTarball file: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["tzf", file.path(percentEncoded: false)]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Drain stdout before waitUntilExit. A 317 MB Wine listing fills the
        // pipe (~64 KB) and deadlocks tar if we wait first.
        let listing = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw IntegrityError.tarListFailed(e.isEmpty ? "tar exit \(process.terminationStatus)" : e)
        }
        if let hit = applePayloadMarkers.first(where: { listing.contains($0) }) {
            throw IntegrityError.containsAppleGPTK(hit)
        }
    }

    public static func assertNoAppleGPTK(inDirectory directory: URL) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if applePayloadMarkers.contains(name) {
                throw IntegrityError.containsAppleGPTK(name)
            }
        }
    }
}
