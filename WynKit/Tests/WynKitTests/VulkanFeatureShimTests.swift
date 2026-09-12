//
//  VulkanFeatureShimTests.swift
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

/// `fly-mvkshim` is installed *as* `libMoltenVK.dylib`, because that is the name
/// winevulkan dlopens, with the stock library moved beside it to
/// `libMoltenVK.real.dylib` — which is where the shim looks for it. Getting that
/// swap wrong in the wrong direction destroys the real library, and MoltenVK is
/// not something Wyn can re-download on its own, so the destructive edges are
/// what these tests are for.
///
/// A synthetic shim is passed in rather than the built one: `Tools/bin` is
/// gitignored, so a test that needed the real binary would pass here and fail on
/// a fresh checkout.
@Suite("Vulkan feature shim install")
struct VulkanFeatureShimTests {

    private func makeTree() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "VulkanFeatureShimTests")
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appending(path: "Wine/lib"), withIntermediateDirectories: true
        )
        return root
    }

    /// Stock MoltenVK is ~5.5 MB. The size matters: the installer refuses to
    /// preserve anything small enough to be a shim as the "real" library.
    private func writeStockMoltenVK(in root: URL, bytes: Int = 5_500_000) throws -> URL {
        let url = root.appending(path: "Wine/lib/libMoltenVK.dylib")
        try Data(repeating: 0xAB, count: bytes).write(to: url)
        return url
    }

    private func writeSyntheticShim() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "fly_mvkshim-\(UUID().uuidString).dylib")
        try Data(repeating: 0xCD, count: 68_176).write(to: url)
        return url
    }

    @Test func theShimTakesTheLoadedNameAndStockMovesAside() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let installed = try writeStockMoltenVK(in: root)
        let stockBytes = try Data(contentsOf: installed)
        let shim = try writeSyntheticShim()
        defer { try? FileManager.default.removeItem(at: shim) }

        #expect(try WynWineInstaller.ensureVulkanFeatureShim(in: root, shimSource: shim))

        let real = root.appending(path: "Wine/lib/libMoltenVK.real.dylib")
        #expect(try Data(contentsOf: installed) == Data(contentsOf: shim))
        #expect(try Data(contentsOf: real) == stockBytes)
        #expect(WynWineInstaller.vulkanFeatureShimIsInstalled(in: root, shimSource: shim))
    }

    /// Every launch of a Vulkan title calls this, so a second call must be free
    /// and must not treat the shim it already installed as a new stock library.
    @Test func installingTwiceChangesNothing() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try writeStockMoltenVK(in: root)
        let stockBytes = try Data(
            contentsOf: root.appending(path: "Wine/lib/libMoltenVK.dylib")
        )
        let shim = try writeSyntheticShim()
        defer { try? FileManager.default.removeItem(at: shim) }

        #expect(try WynWineInstaller.ensureVulkanFeatureShim(in: root, shimSource: shim))
        #expect(try WynWineInstaller.ensureVulkanFeatureShim(in: root, shimSource: shim) == false)

        // The real library is still the real library, not the first shim.
        let real = root.appending(path: "Wine/lib/libMoltenVK.real.dylib")
        #expect(try Data(contentsOf: real) == stockBytes)
    }

    /// The unrecoverable case: someone hand-copied a shim over
    /// `libMoltenVK.dylib` without keeping the stock copy. Preserving *that* as
    /// `libMoltenVK.real.dylib` would point the shim at itself and lose MoltenVK
    /// for good, so the installer declines and leaves the tree alone.
    @Test func aShimIsNeverPreservedAsTheRealLibrary() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        // Small: a hand-installed shim, with no stock copy beside it.
        let installed = try writeStockMoltenVK(in: root, bytes: 135_200)
        let handInstalled = try Data(contentsOf: installed)
        let shim = try writeSyntheticShim()
        defer { try? FileManager.default.removeItem(at: shim) }

        #expect(try WynWineInstaller.ensureVulkanFeatureShim(in: root, shimSource: shim) == false)
        #expect(
            FileManager.default.fileExists(
                atPath: root.appending(path: "Wine/lib/libMoltenVK.real.dylib")
                    .path(percentEncoded: false)
            ) == false
        )
        #expect(try Data(contentsOf: installed) == handInstalled)
    }

    /// A tree that already has a stock backup — the Aug 2026 hand-install — is
    /// upgraded to the shim Wyn ships, and the backup is not touched.
    @Test func anOlderHandInstalledShimIsReplacedWithoutLosingStock() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let lib = root.appending(path: "Wine/lib")
        try Data(repeating: 0x11, count: 135_200).write(to: lib.appending(path: "libMoltenVK.dylib"))
        let stockBytes = Data(repeating: 0xAB, count: 5_500_000)
        try stockBytes.write(to: lib.appending(path: "libMoltenVK.real.dylib"))

        let shim = try writeSyntheticShim()
        defer { try? FileManager.default.removeItem(at: shim) }

        #expect(try WynWineInstaller.ensureVulkanFeatureShim(in: root, shimSource: shim))
        #expect(try Data(contentsOf: lib.appending(path: "libMoltenVK.dylib"))
                == Data(contentsOf: shim))
        #expect(try Data(contentsOf: lib.appending(path: "libMoltenVK.real.dylib")) == stockBytes)
    }

    @Test func removalPutsStockBack() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let installed = try writeStockMoltenVK(in: root)
        let stockBytes = try Data(contentsOf: installed)
        let shim = try writeSyntheticShim()
        defer { try? FileManager.default.removeItem(at: shim) }

        #expect(try WynWineInstaller.ensureVulkanFeatureShim(in: root, shimSource: shim))
        #expect(try WynWineInstaller.removeVulkanFeatureShim(in: root))

        #expect(try Data(contentsOf: installed) == stockBytes)
        #expect(
            FileManager.default.fileExists(
                atPath: root.appending(path: "Wine/lib/libMoltenVK.real.dylib")
                    .path(percentEncoded: false)
            ) == false
        )
        #expect(try WynWineInstaller.removeVulkanFeatureShim(in: root) == false)
    }

    @Test func aTreeWithNoMoltenVKIsLeftAlone() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let shim = try writeSyntheticShim()
        defer { try? FileManager.default.removeItem(at: shim) }

        #expect(try WynWineInstaller.ensureVulkanFeatureShim(in: root, shimSource: shim) == false)
    }

    /// The shim is selected by profile shape, not by a new schema field. Both
    /// shipped Vulkan titles declare `vulkan-1` in WINEDLLOVERRIDES; a D3D title
    /// must not drag MoltenVK out from under itself.
    @Test func onlyVulkanNativeProfilesAskForTheShim() throws {
        let bundled = ProfileStore.loadBundledProfiles()
        for id in ["doom-2016", "wolfenstein-youngblood"] {
            let profile = try #require(bundled.first { $0.id == id })
            #expect(ProfileValidator.isVulkanNative(profile), "\(id) should be Vulkan-native")
        }
        for id in ["satisfactory", "witcher-3", "ready-or-not"] {
            let profile = try #require(bundled.first { $0.id == id })
            #expect(!ProfileValidator.isVulkanNative(profile), "\(id) is D3D")
        }
        #expect(ProfileApplicator.prepareVulkanShim(profile: nil) == 0)
    }
}
