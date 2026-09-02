import Foundation
import Testing
@testable import WynKit

/// Regression cover for the black Steam login window on a genuinely fresh
/// bottle — the second time it shipped.
///
/// Recorded on the machine, 2 Sep 2026, from the bottle's own timestamps and
/// `Steam/logs/`:
///
/// | time     | event                                                        |
/// |----------|--------------------------------------------------------------|
/// | 23:49:31 | bootstrap `steam.exe -silent`, first client download          |
/// | 23:50:23 | `cef.win7x64` created **and shimmed** — old code returned true |
/// | 23:51:10 | `cef.win64` created, carrying Valve's 7,488,152-byte helper   |
/// | 23:51:25 | webhelper pid 600 launched from `cef.win64` — **no `--in-process-gpu`** |
/// | 23:52:21 | `cef.win64` finally shimmed, by the *next* call               |
/// | 23:52:23 | webhelper pid 1964 → `steamwebhelper_real.exe --disable-gpu --in-process-gpu` |
///
/// The 47 seconds between the two variants is the whole bug: the old success
/// rule ("every variant that has a helper is shimmed") was satisfied at
/// 23:50:23, when the variant Steam would actually load did not exist yet.
///
/// Reproduced on a fresh bottle 3 Sep 2026 with the same 47-second gap
/// (cef.win7x64 00:12:14, cef.win64 00:13:01), so it is the shape of a first
/// run rather than a fluke — and that run turned up the other half:
///
///     BVerifyInstalledFiles: bin\cef\cef.win64\steamwebhelper.exe
///       is 151908 bytes, expected 7488152
///
/// ten times in a hundred seconds. Steam verifies its own files on any launch
/// without `-noverifyfiles`, re-extracts the package over the shim and
/// restarts. So `layoutState` deliberately asks only whether Steam has finished
/// unpacking — the shim is written afterwards, with the client stopped.
@Suite("Steam CEF variant selection")
struct SteamCEFShimVariantTests {

    // Real lines, copied from Steam/logs/webhelper.txt, truncated after the
    // flags that matter. `--in-process-gpu` occurs exactly once in the whole
    // recorded log, and only on the shimmed launch.
    static let unshimmedLine = #"""
    [2026-09-02 23:51:25] Startup - webhelper launched pid: 600 commandline: "C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper.exe" -nocrashdialog -lang=en_US -cachedir="C:\users\crossover\AppData\Local\Steam\htmlcache" -steampid=560 --disable-gpu-compositing --disable-gpu --no-sandbox
    """#

    static let shimmedLine = #"""
    [2026-09-02 23:52:23] Startup - webhelper launched pid: 1964 commandline: "C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper_real.exe" --disable-gpu --in-process-gpu -nocrashdialog -lang=en_US -steampid=560 --no-sandbox
    """#

    // MARK: - Reading which variant Steam chose

    @Test func unshimmedLaunchIsRecognised() {
        let launch = SteamCEFShim.lastWebHelperLaunch(inLog: Self.unshimmedLine)
        #expect(launch?.variant == "cef.win64")
        #expect(launch?.executable == "steamwebhelper.exe")
        #expect(launch?.shimmed == false)
    }

    @Test func shimmedLaunchIsRecognised() {
        let launch = SteamCEFShim.lastWebHelperLaunch(inLog: Self.shimmedLine)
        #expect(launch?.variant == "cef.win64")
        #expect(launch?.executable == "steamwebhelper_real.exe")
        #expect(launch?.shimmed == true)
    }

    /// Steam appends; the newest launch is the live one.
    @Test func lastLaunchWins() {
        let log = [Self.unshimmedLine, Self.shimmedLine].joined(separator: "\n")
        #expect(SteamCEFShim.lastWebHelperLaunch(inLog: log)?.shimmed == true)

        let reversed = [Self.shimmedLine, Self.unshimmedLine].joined(separator: "\n")
        #expect(SteamCEFShim.lastWebHelperLaunch(inLog: reversed)?.shimmed == false)
    }

    @Test func win7x64IsReadAsItsOwnVariant() {
        let line = #"[2026-09-02 23:50:40] Startup - webhelper launched pid: 42 commandline: "C:\Program Files (x86)\Steam\bin\cef\cef.win7x64\steamwebhelper.exe" -lang=en_US"#
        #expect(SteamCEFShim.lastWebHelperLaunch(inLog: line)?.variant == "cef.win7x64")
    }

    /// A log with no launch line yet — the state a fresh bottle is in for the
    /// first ~2 minutes. Must be nil, not a guess.
    @Test func noLaunchLineYieldsNil() {
        let log = """
        [2026-09-02 23:49:31] Startup - updater built May 20 2024 14:26:54
        [2026-09-02 23:49:34] Downloading update...
        """
        #expect(SteamCEFShim.lastWebHelperLaunch(inLog: log) == nil)
    }

    @Test func emptyLogYieldsNil() {
        #expect(SteamCEFShim.lastWebHelperLaunch(inLog: "") == nil)
    }

    // MARK: - Layout settling, replayed against the recorded timeline

    private func inputs(
        helpers: Set<String>,
        steamVariant: String? = nil,
        variantAgeSeconds: TimeInterval = 600,
        bootstrapLogAgeSeconds: TimeInterval? = 600,
        settle: TimeInterval = 15
    ) -> SteamCEFShim.LayoutInputs {
        let now = Date()
        return SteamCEFShim.LayoutInputs(
            helperVariants: helpers,
            steamVariant: steamVariant,
            now: now,
            lastVariantChange: now.addingTimeInterval(-variantAgeSeconds),
            bootstrapLogMtime: bootstrapLogAgeSeconds.map { now.addingTimeInterval(-$0) },
            settle: settle
        )
    }

    private func hasSettled(_ state: SteamCEFShim.LayoutState) -> Bool {
        if case .settled = state { return true }
        return false
    }

    /// **23:50:23.** The exact state the old code called success. `cef.win7x64`
    /// exists; `cef.win64` will not exist for another 47 seconds. Calling this
    /// done — and shimming on the strength of it — is what shipped the black
    /// window.
    @Test func winSevenX64AloneHasNotSettled() {
        let state = SteamCEFShim.layoutState(
            inputs(
                helpers: ["cef.win7x64"],
                steamVariant: nil,
                variantAgeSeconds: 0,        // it landed this second
                bootstrapLogAgeSeconds: 0    // Steam is still unpacking
            )
        )
        #expect(!hasSettled(state))
    }

    /// Steam has named a variant that is not on disk yet — keep waiting for it,
    /// whatever else is present.
    @Test func steamsOwnVariantDecidesAndBlocks() {
        let state = SteamCEFShim.layoutState(
            inputs(helpers: ["cef.win7x64"], steamVariant: "cef.win64")
        )
        #expect(!hasSettled(state))
        if case .keepWaiting(let reason) = state {
            #expect(reason.contains("cef.win64"))
        }
    }

    /// **23:51:10.** Steam's variant is on disk. Settled — and note it is
    /// settled while still carrying Valve's helper: shimming is a separate step
    /// that happens after the client is stopped.
    @Test func settledWhenSteamsVariantIsOnDisk() {
        let state = SteamCEFShim.layoutState(
            inputs(helpers: ["cef.win7x64", "cef.win64"], steamVariant: "cef.win64")
        )
        #expect(state == .settled(variant: "cef.win64"))
    }

    /// A variant Steam never loads must not hold the launch hostage.
    @Test func variantsSteamDoesNotLoadDoNotBlock() {
        let state = SteamCEFShim.layoutState(
            inputs(helpers: ["cef.win7", "cef.win64"], steamVariant: "cef.win64")
        )
        #expect(state == .settled(variant: "cef.win64"))
    }

    /// The warm path: `webhelper.txt` already names a present variant, so the
    /// settle window is never charged even though a variant just changed. Every
    /// launch after the first must not pay for the first one's bug.
    @Test func warmBottleSettlesWithoutWaiting() {
        let state = SteamCEFShim.layoutState(
            inputs(
                helpers: ["cef.win64"],
                steamVariant: "cef.win64",
                variantAgeSeconds: 0,
                bootstrapLogAgeSeconds: 0
            )
        )
        #expect(state == .settled(variant: "cef.win64"))
    }

    /// No launch recorded and Steam has gone quiet: nothing more is coming.
    @Test func quietSteamWithVariantsOnDiskHasSettled() {
        let state = SteamCEFShim.layoutState(
            inputs(
                helpers: ["cef.win64"],
                steamVariant: nil,
                variantAgeSeconds: 60,
                bootstrapLogAgeSeconds: 60
            )
        )
        #expect(state == .settled(variant: nil))
    }

    /// Same, but Steam is still writing `bootstrap_log.txt` — mid-update, and
    /// another variant may still land. This guard alone would have held the
    /// 23:50:23 pass open.
    @Test func steamStillWritingBootstrapLogHasNotSettled() {
        let state = SteamCEFShim.layoutState(
            inputs(
                helpers: ["cef.win64"],
                steamVariant: nil,
                variantAgeSeconds: 60,
                bootstrapLogAgeSeconds: 2
            )
        )
        #expect(!hasSettled(state))
    }

    /// A variant that appeared moments ago means Steam is still unpacking, even
    /// with no bootstrap log at all.
    @Test func freshlyAppearedVariantHasNotSettled() {
        let state = SteamCEFShim.layoutState(
            inputs(
                helpers: ["cef.win64"],
                steamVariant: nil,
                variantAgeSeconds: 1,
                bootstrapLogAgeSeconds: nil
            )
        )
        #expect(!hasSettled(state))
    }

    @Test func noHelperOnDiskHasNotSettled() {
        let state = SteamCEFShim.layoutState(inputs(helpers: []))
        #expect(!hasSettled(state))
    }

    // MARK: - Against a bottle on disk

    /// Build the 23:50:23 layout for real and prove the two rules disagree:
    /// the **old** success rule (`isInstalled`) is true, the new one is not.
    /// Without this the layout tests above could be vacuously green.
    @Test func oldRuleSaysDoneAtTheMomentTheBugShipped() throws {
        let fixture = try CEFBottleFixture()
        defer { fixture.cleanUp() }
        try fixture.makeShimmedVariant("cef.win7x64")

        #expect(SteamCEFShim.isInstalled(in: fixture.bottle))   // old rule: done
        #expect(SteamCEFShim.helperBearingVariants(in: fixture.bottle) == ["cef.win7x64"])
        #expect(SteamCEFShim.shimmedVariants(in: fixture.bottle) == ["cef.win7x64"])

        let state = SteamCEFShim.layoutState(
            inputs(
                helpers: SteamCEFShim.helperBearingVariants(in: fixture.bottle),
                steamVariant: nil,
                variantAgeSeconds: 0,
                bootstrapLogAgeSeconds: 0
            )
        )
        #expect(!hasSettled(state))                             // new rule: not yet
    }

    /// 23:51:10: Valve's helper lands in `cef.win64`. It must read as a
    /// helper-bearing variant and *not* as a shimmed one.
    @Test func valveHelperReadsAsUnshimmed() throws {
        let fixture = try CEFBottleFixture()
        defer { fixture.cleanUp() }
        try fixture.makeShimmedVariant("cef.win7x64")
        try fixture.makeValveVariant("cef.win64")

        #expect(SteamCEFShim.helperBearingVariants(in: fixture.bottle) == ["cef.win7x64", "cef.win64"])
        #expect(SteamCEFShim.shimmedVariants(in: fixture.bottle) == ["cef.win7x64"])
        #expect(!SteamCEFShim.isInstalled(in: fixture.bottle))
    }

    /// `webhelper.txt` is read from the bottle, not just from a string.
    @Test func webHelperLogIsReadFromTheBottle() throws {
        let fixture = try CEFBottleFixture()
        defer { fixture.cleanUp() }
        try fixture.writeWebHelperLog([Self.unshimmedLine, Self.shimmedLine].joined(separator: "\n"))

        let launch = SteamCEFShim.lastWebHelperLaunch(in: fixture.bottle)
        #expect(launch?.variant == "cef.win64")
        #expect(launch?.shimmed == true)
    }

    @Test func missingWebHelperLogIsNil() throws {
        let fixture = try CEFBottleFixture()
        defer { fixture.cleanUp() }
        #expect(SteamCEFShim.lastWebHelperLaunch(in: fixture.bottle) == nil)
    }
}

// MARK: - Fixture

/// A throwaway prefix shaped like a Steam bottle. Under `$HOME`, never `/tmp`:
/// `/tmp/Wyn*` trees are what the uninstaller sweeps, and a test tree there has
/// already been mistaken for a real build once.
private struct CEFBottleFixture {
    let root: URL
    let bottle: Bottle

    /// Valve's real `cef.win64` helper measured 7,488,152 bytes. Anything at or
    /// above SteamCEFShim's 500,000-byte threshold reads as Valve's; the shim
    /// itself is 151,908.
    private static let valveHelperBytes = 600_000
    private static let shimBytes = 151_908

    init() throws {
        root = URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: "Library/Caches/com.wyn.gaming/CEFShimTests")
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        bottle = Bottle(bottleUrl: root)
    }

    private var cefRoot: URL { SteamCEFShim.cefRoot(in: bottle) }
    private var logsRoot: URL { SteamCEFShim.steamRoot(in: bottle).appending(path: "logs") }

    func makeShimmedVariant(_ name: String) throws {
        let dir = cefRoot.appending(path: name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try write(dir.appending(path: "steamwebhelper.exe"), bytes: Self.shimBytes)
        try write(dir.appending(path: "steamwebhelper_real.exe"), bytes: Self.valveHelperBytes)
    }

    func makeValveVariant(_ name: String) throws {
        let dir = cefRoot.appending(path: name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try write(dir.appending(path: "steamwebhelper.exe"), bytes: Self.valveHelperBytes)
    }

    func writeWebHelperLog(_ text: String) throws {
        try FileManager.default.createDirectory(at: logsRoot, withIntermediateDirectories: true)
        try text.write(to: SteamCEFShim.webHelperLogURL(in: bottle), atomically: true, encoding: .utf8)
    }

    private func write(_ url: URL, bytes: Int) throws {
        try Data(count: bytes).write(to: url)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}
