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
