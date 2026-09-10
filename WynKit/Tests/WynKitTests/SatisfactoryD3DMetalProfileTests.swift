//
//  SatisfactoryD3DMetalProfileTests.swift
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

@Suite("Satisfactory D3DMetal profile")
struct SatisfactoryD3DMetalProfileTests {
    /// Fresh clones used to ship MetalFX/HUD on. That is ~2 fps then RHIThread SIGILL.
    @Test func bundledProfileDisablesMetalFXHudAndAsyncCommit() {
        let profile = ProfileStore.profile(id: "satisfactory")
        #expect(profile != nil)
        guard let profile else { return }

        #expect(profile.environment["D3DM_ENABLE_METALFX"] == "0")
        #expect(profile.environment["D3DM_ENABLE_ASYNC_COMMIT"] == "0")
        #expect(profile.environment["MTL_HUD_ENABLED"] == "0")
        #expect(profile.environment["D3DM_SHOW_HUD_STATS"] == "0")
        #expect(profile.bottle?.metalHud == false)
    }
}
