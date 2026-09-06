import Foundation
import Testing
@testable import WynKit

/// `wyn play` used to put the game's own `d3d11,dxgi,d3d10core=n,b` on the
/// Steam client process. Everything Steam spawns inherits that, steamwebhelper
/// included, and loading a game translation layer into Chromium's GPU process
/// kills it at startup — `crash server failed to launch, self-terminating`,
/// respawning every 10 s, never logging on. Measured 12 Aug: `n,b` FAIL 2/2,
/// absent GOOD 4/4, `b` GOOD 2/2.
///
/// The layer now reaches the game through its per-exe AppDefaults, and the
/// client keeps only the clauses that were never about graphics.
@Suite("Steam-safe DLL overrides")
struct SteamSafeOverridesTests {

    /// The exact string the DXMT play path used to export.
    @Test func theDxmtPlayOverrideKeepsOnlyItsNonGraphicsClauses() {
        let raw = "d3d11,dxgi,d3d10core=n,b;gameoverlayrenderer64=n;"
            + "steamerrorreporter64.exe,steamerrorreporter.exe=d"
        let safe = SteamLauncher.steamSafeOverrides(raw)
        #expect(safe == "gameoverlayrenderer64=n;steamerrorreporter64.exe,steamerrorreporter.exe=d")
    }

    /// A whole clause goes if any name in it is a graphics DLL — a mixed clause
    /// cannot be half-applied.
    @Test func aMixedClauseIsDroppedWhole() {
        #expect(SteamLauncher.steamSafeOverrides("winedbg.exe,d3d11=d") == nil)
    }

    /// The solarpunk-dxmt profile's own value: nothing but the layer.
    @Test func aLayerOnlyOverrideLeavesNothingBehind() {
        #expect(SteamLauncher.steamSafeOverrides("dxgi,d3d11,d3d10core=n,b") == nil)
    }

    /// D3DMetal's builtin form is stripped just as thoroughly — `=b` on the
    /// client is safe for CEF, but the client is not where a game's layer is
    /// chosen any more, so it has no business being there either.
    @Test func theD3DMetalOverrideIsStrippedToo() {
        let raw = "d3d11,dxgi,d3d12,d3d10,atidxx64,nvapi64,nvngx=b"
        #expect(SteamLauncher.steamSafeOverrides(raw) == nil)
    }

    @Test func unrelatedOverridesSurviveUntouched() {
        let raw = "winemenubuilder.exe=d;mscoree,mshtml="
        #expect(SteamLauncher.steamSafeOverrides(raw) == raw)
    }

    @Test func emptyAndNilAreNil() {
        #expect(SteamLauncher.steamSafeOverrides(nil) == nil)
        #expect(SteamLauncher.steamSafeOverrides("") == nil)
    }

    /// Spacing and case are the caller's, not ours.
    @Test func namesAreMatchedCaseAndSpaceInsensitively() {
        #expect(SteamLauncher.steamSafeOverrides("DXGI, D3D11 =n,b;foo=d") == "foo=d")
    }
}
