//
//  SetupPrerequisiteTests.swift
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

@Suite("Setup prerequisites")
struct SetupPrerequisiteTests {

    /// The whole value of the Rosetta gate is the wording a person reads when
    /// it fires: someone installing from the disk image has no checkout, no
    /// `doctor.sh`, and no reason to know Wine's unix half is x86_64. An empty
    /// or vague hint would leave them with a failed setup and nothing to do,
    /// which is the state this check exists to prevent.
    @Test func rosettaFailureSaysWhatToRun() throws {
        let error = WynInstallError.rosettaMissing

        let description = try #require(error.errorDescription)
        #expect(description.contains("Rosetta 2"))
        #expect(description.contains("x86_64"))

        let suggestion = try #require(error.recoverySuggestion)
        #expect(suggestion.contains("softwareupdate --install-rosetta"))
        #expect(suggestion.contains("--agree-to-license"))
    }

    /// `Failure(step:error:)` reads `recoverySuggestion` off `LocalizedError`
    /// to fill the dialog's "Try:" line, so the conformance is what carries
    /// the hint to the screen — not the enum case by itself.
    @Test func theHintReachesTheFailureDialog() throws {
        let failure = Failure(step: "Installing Wine runtime", error: WynInstallError.rosettaMissing)

        #expect(failure.title == "Installing Wine runtime didn't work")
        let hint = try #require(failure.hint)
        #expect(hint.contains("softwareupdate --install-rosetta"))
    }
}
