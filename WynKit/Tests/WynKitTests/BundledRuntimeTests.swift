//
//  BundledRuntimeTests.swift
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
import Testing
@testable import WynKit

/// A release Wyn.app (1.1+) carries its runtime in Contents/SharedSupport/Runtime.
/// The lookup has to find it from all three places Wyn code runs — the app,
/// the CLI inside the app, and a CLI copied to ~/.local/bin — and must never
/// mistake a source build (no Runtime/) for one that carries a runtime, or
/// setup would stop downloading the runtime a source build needs.
///
/// These tests build fake bundles in a temporary directory and read nothing
/// from this Mac's real Application Support.
@Suite("Bundled runtime lookup")
struct BundledRuntimeTests {

    private func makeFakeApp(withRuntime: Bool) throws -> URL {
        let fm = FileManager.default
        let app = fm.temporaryDirectory
            .appending(path: "BundledRuntimeTests-\(UUID().uuidString)")
            .appending(path: "Wyn.app")
        let contents = app.appending(path: "Contents")
        try fm.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: contents.appending(path: "Resources"), withIntermediateDirectories: true)
        try Data().write(to: contents.appending(path: "MacOS/Wyn"))
        try Data().write(to: contents.appending(path: "Resources/wyn"))
        if withRuntime {
            let bin = contents.appending(path: "SharedSupport/Runtime/Libraries/Wine/bin")
            try fm.createDirectory(at: bin, withIntermediateDirectories: true)
            try Data().write(to: bin.appending(path: "wine"))
            try fm.createSymbolicLink(
                atPath: bin.appending(path: "wine64").path(percentEncoded: false),
                withDestinationPath: "wine"
            )
        }
        return app
    }

    @Test func aReleaseAppIsRecognisedByItsWine64() throws {
        let app = try makeFakeApp(withRuntime: true)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        #expect(BundledRuntime.isRuntimeRoot(app.appending(path: "Contents/SharedSupport/Runtime")))
    }

    /// The regression this guards: a source build must keep downloading its
    /// runtime, so an app without Runtime/ must not look like it carries one.
    @Test func aSourceBuildCarriesNoRuntime() throws {
        let app = try makeFakeApp(withRuntime: false)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let roots = BundledRuntime.candidateRoots(
            sharedSupportURL: app.appending(path: "Contents/SharedSupport"),
            executableURL: app.appending(path: "Contents/MacOS/Wyn"),
            installedApps: [app]
        )
        #expect(!roots.isEmpty)
        #expect(roots.allSatisfy { !BundledRuntime.isRuntimeRoot($0) })
    }

    /// The CLI inside the app runs as Contents/Resources/wyn, and its
    /// Bundle.main is only that directory — no sharedSupportURL. The
    /// executable's own location has to lead back to SharedSupport.
    @Test func theCLIInsideTheAppFindsItsRuntime() throws {
        let app = try makeFakeApp(withRuntime: true)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let roots = BundledRuntime.candidateRoots(
            sharedSupportURL: nil,
            executableURL: app.appending(path: "Contents/Resources/wyn"),
            installedApps: []
        )
        let found = try #require(roots.first(where: BundledRuntime.isRuntimeRoot))
        #expect(found.standardizedFileURL
                == app.appending(path: "Contents/SharedSupport/Runtime").standardizedFileURL)
    }

    /// A CLI copied out to ~/.local/bin has no bundle; the installed app is
    /// the only place its runtime can be.
    @Test func aCopiedCLIFallsBackToTheInstalledApp() {
        let roots = BundledRuntime.candidateRoots().map { $0.path(percentEncoded: false) }
        #expect(roots.contains("/Applications/Wyn.app/Contents/SharedSupport/Runtime"))
    }

    /// Files dragged out of a downloaded image are quarantined, and the copy
    /// into Application Support keeps the flag; install has to clear it on
    /// every file, nested ones included, and leave symlink targets alone.
    @Test func installedCopiesLoseTheQuarantineFlag() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "BundledRuntimeQuarantine-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let nested = root.appending(path: "Wine/lib/wine/x86_64-unix")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appending(path: "ntdll.so")
        try Data([0xCF, 0xFA, 0xED, 0xFE]).write(to: file)

        let value = "0083;66f6b000;Safari;"
        func quarantined(_ url: URL) -> Bool {
            url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return false }
                return getxattr(path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
            }
        }
        for url in [root, nested, file] {
            _ = url.withUnsafeFileSystemRepresentation { path in
                path.map { setxattr($0, "com.apple.quarantine", value, value.utf8.count, 0, XATTR_NOFOLLOW) }
            }
            #expect(quarantined(url))
        }

        BundledRuntime.clearQuarantine(under: root)

        #expect(!quarantined(root))
        #expect(!quarantined(nested))
        #expect(!quarantined(file))
    }

    @Test func theRuntimeSourceHasNoRemoteToUpdateFrom() {
        #expect(RuntimeSource.bundled.versionPlistURL == nil)
        #expect(RuntimeSource.bundled.releasesBaseURL == nil)
        #expect(RuntimeSource(rawValue: "bundled") == .bundled)
    }
}
