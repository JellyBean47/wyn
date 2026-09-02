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

    // MARK: - Readiness, replayed against the recorded timeline

    private func inputs(
        helpers: Set<String>,
        shimmed: Set<String>,
        steamVariant: String? = nil,
        variantAgeSeconds: TimeInterval = 600,
        bootstrapLogAgeSeconds: TimeInterval? = 600,
        settle: TimeInterval = 15
    ) -> SteamCEFShim.ReadinessInputs {
        let now = Date()
        return SteamCEFShim.ReadinessInputs(
            helperVariants: helpers,
            shimmedVariants: shimmed,
            steamVariant: steamVariant,
            now: now,
            lastVariantChange: now.addingTimeInterval(-variantAgeSeconds),
            bootstrapLogMtime: bootstrapLogAgeSeconds.map { now.addingTimeInterval(-$0) },
            settle: settle
        )
    }

    private func isReady(_ state: SteamCEFShim.Readiness) -> Bool {
        if case .ready = state { return true }
        return false
    }

    /// **23:50:23.** The exact state the old code called success. `cef.win7x64`
    /// exists and is shimmed; `cef.win64` will not exist for another 47 seconds.
    /// Returning ready here is what shipped the black window.
    @Test func winSevenX64AloneIsNotReady() {
        let state = SteamCEFShim.readiness(
            inputs(
                helpers: ["cef.win7x64"],
                shimmed: ["cef.win7x64"],
                steamVariant: nil,
                variantAgeSeconds: 0,        // it landed this second
                bootstrapLogAgeSeconds: 0    // Steam is still unpacking
            )
        )
        #expect(!isReady(state))
    }

    /// **23:51:25.** Steam has named its variant and it is Valve's helper.
    @Test func steamsOwnVariantDecidesAndBlocks() {
        let state = SteamCEFShim.readiness(
            inputs(
                helpers: ["cef.win7x64", "cef.win64"],
                shimmed: ["cef.win7x64"],
                steamVariant: "cef.win64"
            )
        )
        #expect(!isReady(state))
        if case .keepWaiting(let reason) = state {
            #expect(reason.contains("cef.win64"))
        }
    }

    /// **23:52:23.** Steam's variant is shimmed — and that is the whole test.
    @Test func readyWhenSteamsVariantIsShimmed() {
        let state = SteamCEFShim.readiness(
            inputs(
                helpers: ["cef.win7x64", "cef.win64"],
                shimmed: ["cef.win7x64", "cef.win64"],
                steamVariant: "cef.win64"
            )
        )
        #expect(state == .ready(variant: "cef.win64"))
    }

    /// A variant Steam never loads must not hold the launch hostage. `cef.win7`
    /// sitting unshimmed on a Windows 10 bottle is not a reason to wait.
    @Test func variantsSteamDoesNotLoadDoNotBlock() {
        let state = SteamCEFShim.readiness(
            inputs(
                helpers: ["cef.win7", "cef.win64"],
                shimmed: ["cef.win64"],
                steamVariant: "cef.win64"
            )
        )
        #expect(state == .ready(variant: "cef.win64"))
    }

    /// The warm path: `webhelper.txt` already names a shimmed variant, so the
    /// settle window is never charged even though a variant "just changed".
    /// Every launch after the first must not pay for the first one's bug.
    @Test func warmBottleIsReadyWithoutWaiting() {
        let state = SteamCEFShim.readiness(
            inputs(
                helpers: ["cef.win64"],
                shimmed: ["cef.win64"],
                steamVariant: "cef.win64",
                variantAgeSeconds: 0,
                bootstrapLogAgeSeconds: 0
            )
        )
        #expect(state == .ready(variant: "cef.win64"))
    }

    /// No launch recorded and Steam has gone quiet: everything on disk is
    /// shimmed and nothing has moved for a settle window. Nothing more is
    /// coming, so stop waiting.
    @Test func quietSteamWithEverythingShimmedIsReady() {
        let state = SteamCEFShim.readiness(
            inputs(
                helpers: ["cef.win64"],
                shimmed: ["cef.win64"],
                steamVariant: nil,
                variantAgeSeconds: 60,
                bootstrapLogAgeSeconds: 60
            )
        )
        #expect(state == .ready(variant: nil))
    }

    /// Same, but Steam is still writing `bootstrap_log.txt` — it is mid-update
    /// and another variant may still land. This is the guard that would have
    /// held the 23:50:23 pass open on its own.
    @Test func steamStillWritingBootstrapLogIsNotReady() {
        let state = SteamCEFShim.readiness(
            inputs(
                helpers: ["cef.win64"],
                shimmed: ["cef.win64"],
                steamVariant: nil,
                variantAgeSeconds: 60,
                bootstrapLogAgeSeconds: 2
            )
        )
        #expect(!isReady(state))
    }

    /// A variant that appeared moments ago means Steam is still unpacking, even
    /// if the bootstrap log is missing entirely.
    @Test func freshlyAppearedVariantIsNotReady() {
        let state = SteamCEFShim.readiness(
            inputs(
                helpers: ["cef.win64"],
                shimmed: ["cef.win64"],
                steamVariant: nil,
                variantAgeSeconds: 1,
                bootstrapLogAgeSeconds: nil
            )
        )
        #expect(!isReady(state))
    }

    @Test func noHelperOnDiskIsNotReady() {
        let state = SteamCEFShim.readiness(inputs(helpers: [], shimmed: []))
        #expect(!isReady(state))
    }

    @Test func unshimmedHelperIsNotReadyEvenWithSteamSilent() {
        let state = SteamCEFShim.readiness(
            inputs(helpers: ["cef.win64"], shimmed: [], steamVariant: nil)
        )
        #expect(!isReady(state))
    }

    // MARK: - Against a bottle on disk

    /// Build the 23:50:23 layout for real and prove the two rules disagree:
    /// the **old** success rule (`isInstalled`) is true, the new one is not.
    /// Without this the readiness tests above could be vacuously green.
    @Test func oldRuleSaysDoneAtTheMomentTheBugShipped() throws {
        let fixture = try CEFBottleFixture()
        defer { fixture.cleanUp() }
        try fixture.makeShimmedVariant("cef.win7x64")

        #expect(SteamCEFShim.isInstalled(in: fixture.bottle))   // old rule: done
        #expect(SteamCEFShim.helperBearingVariants(in: fixture.bottle) == ["cef.win7x64"])
        #expect(SteamCEFShim.shimmedVariants(in: fixture.bottle) == ["cef.win7x64"])

        let state = SteamCEFShim.readiness(
            inputs(
                helpers: SteamCEFShim.helperBearingVariants(in: fixture.bottle),
                shimmed: SteamCEFShim.shimmedVariants(in: fixture.bottle),
                steamVariant: nil,
                variantAgeSeconds: 0,
                bootstrapLogAgeSeconds: 0
            )
        )
        #expect(!isReady(state))                                // new rule: not yet
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
