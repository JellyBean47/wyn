import Foundation
import Testing
@testable import WynKit

/// Per-exe `AppDefaults\<exe>\DllOverrides` blocks are written at launch and
/// never removed, so every launch of an exe has to say what *it* needs — or it
/// inherits what the last launch of that exe needed. `user.reg` on the test
/// machine carries ~120 such blocks, all `d3d*=b`, from one bulk write.
@Suite("A launch says what its own exe needs")
struct PerExeOverridesTests {

    /// DXVK and DXMT want the same native trio. The direct-EXE path used to ask
    /// only when the layer was DXMT, so a DXVK launch of an exe that had once
    /// run on D3DMetal kept that run's `d3d*=b` and quietly used the builtins.
    @Test func dxvkAsksForTheSameNativesAsDXMT() {
        let dxvk = SteamLauncher.perExeNativeD3D(for: .dxvk)
        let dxmt = SteamLauncher.perExeNativeD3D(for: .dxmt)

        #expect(dxvk == dxmt)
        #expect(dxvk?["d3d11"] == "n")
        #expect(dxvk?["dxgi"] == "n")
        #expect(dxvk?["d3d10core"] == "n")
    }

    /// D3DMetal writes its own block (`applyD3DMetalGameOverrides`, `d3d*=b`),
    /// so this path must not write a competing one.
    @Test func d3dMetalIsNotThisPathsBusiness() {
        #expect(SteamLauncher.perExeNativeD3D(for: .d3dMetal) == nil)
    }

    /// Writing a block replaces it: names from the previous shape do not
    /// survive. `d3d10` and the overlay keys are in the D3DMetal shape and not
    /// in the native trio, so a DXVK launch must drop them.
    @Test func writingABlockReplacesTheOneBefore() throws {
        let bottleURL = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: bottleURL, withIntermediateDirectories: true)
        let userReg = bottleURL.appending(path: "user.reg")
        try """
        WINE REGISTRY Version 2

        [Software\\\\Wine\\\\AppDefaults\\\\game.exe\\\\DllOverrides] 1789082294
        "atidxx64"="b"
        "d3d10"="b"
        "d3d11"="b"
        "dxgi"="b"
        "gameoverlayrenderer"="d"

        """.write(to: userReg, atomically: true, encoding: .utf8)

        let bottle = Bottle(bottleUrl: bottleURL)
        let natives = try #require(SteamLauncher.perExeNativeD3D(for: .dxvk))
        try Wine.setAppDllOverrides(bottle: bottle, exeName: "game.exe", overrides: natives)

        let text = try String(contentsOf: userReg, encoding: .utf8)
        #expect(text.contains("\"d3d11\"=\"n\""))
        #expect(text.contains("\"dxgi\"=\"n\""))
        #expect(!text.contains("\"d3d10\"=\"b\""))
        #expect(!text.contains("\"gameoverlayrenderer\"=\"d\""))
    }
}
