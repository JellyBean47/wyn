//
//  BottleFactoryTests.swift
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

/// `create` writes into the real BottleData registry, so these tests cover the
/// validation and naming rules rather than creating bottles on a dev machine.
///
/// The rules matter: a bottle named "Steam" would make every storefront lookup
/// resolve to a user's empty prefix instead of the real one.
@Suite("Bottle creation rules")
struct BottleFactoryTests {

    // MARK: - Reserved names

    @Test func steamBottleNameIsReserved() {
        #expect(BottleFactory.isReservedName(SteamLauncher.defaultBottleName))
    }

    /// Case and stray whitespace must not get past the check — "  steam  " is
    /// the same collision as "Steam".
    @Test func reservedCheckIgnoresCaseAndWhitespace() {
        #expect(BottleFactory.isReservedName("  steam  "))
        #expect(BottleFactory.isReservedName("STEAM"))
    }

    @Test func dedicatedStorefrontNamesAreReserved() {
        for kind in PlatformKind.allCases {
            guard let name = kind.dedicatedBottleName else { continue }
            #expect(BottleFactory.isReservedName(name),
                    "\(name) should be reserved for \(kind)")
        }
    }

    @Test func ordinaryNamesAreNotReserved() {
        #expect(!BottleFactory.isReservedName("My Games"))
        #expect(!BottleFactory.isReservedName("Testing"))
    }

    /// An empty name must not match a storefront with no dedicated bottle,
    /// which would otherwise report "" as reserved and give a confusing error.
    @Test func emptyNameIsNotReportedAsReserved() {
        #expect(!BottleFactory.isReservedName(""))
        #expect(!BottleFactory.isReservedName("   "))
    }

    // MARK: - Validation

    @Test func emptyNameIsRejected() {
        #expect(throws: BottleFactory.CreateError.emptyName) {
            try BottleFactory.create(name: "")
        }
        #expect(throws: BottleFactory.CreateError.emptyName) {
            try BottleFactory.create(name: "   \n ")
        }
    }

    /// An existing bottle name must collide with itself whatever the case —
    /// this is the check that stops a second "Steam" being created.
    ///
    /// Skipped rather than faked when the machine has no bottles registered: a
    /// fixture bottle would have to be written into the real registry, and a
    /// test that leaves bottles behind on a dev machine is worse than one that
    /// sometimes has nothing to assert.
    @Test func existingNamesCollideRegardlessOfCase() throws {
        guard let first = BottleFactory.existingNames().first else { return }
        #expect(throws: BottleFactory.CreateError.duplicateName(first.uppercased())) {
            try BottleFactory.create(name: first.uppercased())
        }
    }

    @Test func errorsExplainThemselves() {
        #expect(BottleFactory.CreateError.emptyName.errorDescription == "A bottle needs a name.")
        let duplicate = BottleFactory.CreateError.duplicateName("My Games")
        #expect(duplicate.errorDescription?.contains("My Games") == true)
    }

}
