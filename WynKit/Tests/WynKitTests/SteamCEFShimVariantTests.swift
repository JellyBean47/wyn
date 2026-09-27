//
//  SteamCEFShimVariantTests.swift
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
/// restarts. So `firstRunState` deliberately asks only whether Steam has finished
/// installing — the shim is written afterwards, with the client stopped.
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

    /// **Steam writes these logs CRLF**, and in Swift `"\r\n"` is a *single*
    /// Character — so `split(separator: "\n")` matches nothing and returns the
    /// whole file as one line.
    ///
    /// That shipped. On every real log the parser returned the *first* launch
    /// in the file and reported `shimmed` as "--in-process-gpu appears
    /// somewhere in this log", which is true forever once one good launch has
    /// happened — so a client sitting on a black window read as healthy and
    /// was adopted. Caught 3 Sep against a real `webhelper.txt`; the LF tests
    /// above all passed throughout, which is the whole lesson.
    @Test func crlfLogsAreSplitIntoLines() {
        let log = [Self.unshimmedLine, Self.shimmedLine].joined(separator: "\r\n")
        let launch = SteamCEFShim.lastWebHelperLaunch(inLog: log)
        #expect(launch?.executable == "steamwebhelper_real.exe")
        #expect(launch?.shimmed == true)

        // The direction that actually bit: a good launch, then a bad one.
        // Whole-file matching calls this shimmed. It is not.
        let regressed = [Self.shimmedLine, Self.unshimmedLine].joined(separator: "\r\n")
        let live = SteamCEFShim.lastWebHelperLaunch(inLog: regressed)
        #expect(live?.executable == "steamwebhelper.exe")
        #expect(live?.shimmed == false)
    }

    /// Bare CR, in case a log ever arrives classic-Mac style.
    @Test func carriageReturnOnlyLogsAreSplitIntoLines() {
        let log = [Self.shimmedLine, Self.unshimmedLine].joined(separator: "\r")
        #expect(SteamCEFShim.lastWebHelperLaunch(inLog: log)?.shimmed == false)
    }

    /// A trailing CRLF must not be read as an empty trailing record.
    @Test func trailingNewlineIsHarmless() {
        let log = Self.shimmedLine + "\r\n"
        #expect(SteamCEFShim.lastWebHelperLaunch(inLog: log)?.shimmed == true)
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

    // MARK: - Has Steam finished installing? Replayed against the 2 Sep timeline

    /// The first-run bootstrap's session, recorded 2 Sep 2026 23:49:31 (the
    /// line in `noLaunchLineYieldsNil`). Every launch below comes after it.
    private static let bootstrapSession = SteamCEFShim.UpdaterSession(
        startedAt: "2026-09-02 23:49:31",
        phase: .starting
    )

    private func inputs(
        helpers: Set<String>,
        launchLine: String? = nil,
        quietFor: TimeInterval = 0
    ) -> SteamCEFShim.FirstRunInputs {
        SteamCEFShim.FirstRunInputs(
            clientRunning: true,
            clientGoneFor: 0,
            session: Self.bootstrapSession,
            webHelper: launchLine.flatMap { SteamCEFShim.lastWebHelperLaunch(inLog: $0) },
            helperVariants: helpers,
            quietFor: quietFor
        )
    }

    /// **23:50:23.** The exact state the old code called success. `cef.win7x64`
    /// exists; `cef.win64` will not exist for another 47 seconds. Calling this
    /// done — and shimming on the strength of it — is what shipped the black
    /// window.
    @Test func winSevenX64AloneIsNotFinished() {
        let state = SteamCEFShim.firstRunState(inputs(helpers: ["cef.win7x64"]))
        #expect(!state.isFinished)
    }

    /// Steam has named a variant that is not on disk — keep waiting for it,
    /// whatever else is present.
    @Test func steamsOwnVariantHasToBeOnDisk() {
        let state = SteamCEFShim.firstRunState(
            inputs(helpers: ["cef.win7x64"], launchLine: Self.unshimmedLine)
        )
        #expect(!state.isFinished)
    }

    /// **23:51:25.** Steam launched its UI from `cef.win64`, which is on disk.
    /// Finished — and note it is finished while still carrying Valve's helper:
    /// shimming is a separate step that happens after the client is stopped.
    @Test func finishedWhenSteamLaunchesItsUIFromAVariantOnDisk() {
        let state = SteamCEFShim.firstRunState(
            inputs(helpers: ["cef.win7x64", "cef.win64"], launchLine: Self.unshimmedLine)
        )
        #expect(state == .uiLaunched(variant: "cef.win64"))
    }

    /// A variant Steam never loads must not hold the launch hostage.
    @Test func variantsSteamDoesNotLoadDoNotBlock() {
        let state = SteamCEFShim.firstRunState(
            inputs(helpers: ["cef.win7", "cef.win64"], launchLine: Self.unshimmedLine)
        )
        #expect(state == .uiLaunched(variant: "cef.win64"))
    }

    /// Quiet is not finished. The rule this replaces settled a layout once
    /// `bootstrap_log.txt` had been still for 15 s, and a first run is not
    /// reliably noisy: on 27 Sep 2026 Steam sat silent for 50 s behind its own
    /// error dialog, between two downloads. Only Steam's own launch says done.
    @Test func quietIsNotFinished() {
        let state = SteamCEFShim.firstRunState(
            inputs(helpers: ["cef.win7x64"], quietFor: 60)
        )
        #expect(!state.isFinished)
    }

    @Test func noHelperOnDiskIsNotFinished() {
        let state = SteamCEFShim.firstRunState(inputs(helpers: []))
        #expect(!state.isFinished)
    }

    // MARK: - Against a bottle on disk

    /// Build the 23:50:23 layout for real and prove the two rules disagree:
    /// the **old** success rule (`isInstalled`) is true, the new one is not.
    /// Without this the rule tests above could be vacuously green.
    @Test func oldRuleSaysDoneAtTheMomentTheBugShipped() throws {
        let fixture = try CEFBottleFixture()
        defer { fixture.cleanUp() }
        try fixture.makeShimmedVariant("cef.win7x64")

        #expect(SteamCEFShim.isInstalled(in: fixture.bottle))   // old rule: done
        #expect(SteamCEFShim.helperBearingVariants(in: fixture.bottle) == ["cef.win7x64"])
        #expect(SteamCEFShim.shimmedVariants(in: fixture.bottle) == ["cef.win7x64"])
        #expect(!SteamCEFShim.hasLaunchedUISinceLastUpdate(in: fixture.bottle))   // new rule: not yet
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

/// Regression cover for the black sign-in window on Wyn 1.1 build 3: a fresh
/// install over a slow line, 27 Sep 2026. Recorded from that bottle's
/// `Steam/logs/`, its directory birth times and Wyn's launch logs:
///
/// | time     | event                                                              |
/// |----------|--------------------------------------------------------------------|
/// | 22:36:25 | Setup starts Steam `-silent`: the 32-bit client, 236 MB            |
/// | 22:39:23 | build 3 gives up after 180 s (`cefDidNotAppear`), 75 MB in         |
/// | 22:48:20 | `Exhausted list of download hosts`: "Failed to load steamui.dll"   |
/// | 22:49:10 | the person closes Steam's error; Steam exits                       |
/// | 22:49:17 | they open Steam again: it installs, relaunches at 22:49:27         |
/// | 22:49:25 | `cef.win7x64` lands, from the 32-bit client                        |
/// | 22:49:30 | the 64-bit client, 230 MB, starts downloading                      |
/// | 22:53:31 | build 3's 240 s wait runs out: `-shutdown` ×3, the updater ignores all three |
/// | 22:54:30 | `cef.win64` lands                                                  |
/// | 22:54:34 | `Update complete, launching Steam...`                              |
/// | 22:54:46 | the relaunched client starts Valve's helper from `cef.win64`: black |
/// | 23:09:11 | stopped, shimmed, relaunched: `steamwebhelper_real.exe --in-process-gpu`, and the window draws |
///
/// Every test below asks the new rule what it would have done at one of
/// those moments, against the logs exactly as they stood then.
@Suite("Steam's first run on a slow line")
struct SteamFirstRunTests {

    /// `bootstrap_log.txt`, verbatim, cut down to the lines that decide
    /// anything (the real file is 219 KB, most of it progress and pending
    /// downloads).
    static let bootstrapLog = #"""
    [2026-09-27 22:36:25] Startup - updater built May 20 2024 14:26:54
    [2026-09-27 22:36:25] Startup - Steam Client launched with: "C:\Program Files (x86)\Steam\steam.exe" -no-cef-sandbox -cef-disable-gpu -cef-in-process-gpu -silent
    [2026-09-27 22:36:25] Verifying installation...
    [2026-09-27 22:36:25] Unable to read and verify install manifest C:\Program Files (x86)\Steam\package\steam_client_win32.installed
    [2026-09-27 22:36:25] Verification complete
    [2026-09-27 22:36:25] Checking for available updates...
    [2026-09-27 22:36:29] Downloaded new manifest: /client/steam_client_win32 version 1769731672, installed version 0, existing pending version 0
    [2026-09-27 22:36:29] Downloading update (15 of 241,937 KB)...
    [2026-09-27 22:39:20] Downloading update (77,631 of 241,937 KB)...
    [2026-09-27 22:40:10] Error: Download of package (public_all) failed after 0 bytes (0 : 200).
    [2026-09-27 22:48:10] Downloading update (236,811 of 241,937 KB)...
    [2026-09-27 22:48:20] Exhausted list of download hosts
    [2026-09-27 22:48:20] Download complete.
    [2026-09-27 22:48:20] Error: Failed to determine download location for universe 1
    [2026-09-27 22:49:10] Shutdown
    [2026-09-27 22:49:17] Startup - updater built May 20 2024 14:26:54
    [2026-09-27 22:49:17] Startup - Steam Client launched with: "C:\Program Files (x86)\Steam\steam.exe" -no-cef-sandbox -cef-disable-gpu -cef-in-process-gpu -silent
    [2026-09-27 22:49:17] Checking for available updates...
    [2026-09-27 22:49:19] Found pending update
    [2026-09-27 22:49:19] Installing update...
    [2026-09-27 22:49:20] Extracting package...
    [2026-09-27 22:49:27] Update complete, launching Steam...
    [2026-09-27 22:49:27] Shutdown
    [2026-09-27 22:49:27] Startup - updater built Jan 29 2026 14:35:32
    [2026-09-27 22:49:27] Startup - Steam Client launched with: "C:\Program Files (x86)\Steam\Steam.exe" -no-cef-sandbox -cef-disable-gpu -cef-in-process-gpu -silent
    [2026-09-27 22:49:27] Verification complete
    [2026-09-27 22:49:27] Downloading update...
    [2026-09-27 22:49:27] Checking for available updates...
    [2026-09-27 22:49:30] Downloaded new manifest: /steam_client_win64 version 1788652215, installed version 0, existing pending version 0
    [2026-09-27 22:49:30] Downloading update (286 of 236,054 KB)...
    [2026-09-27 22:53:30] Downloading update (196,122 of 236,054 KB)...
    [2026-09-27 22:54:20] Downloading update (231,337 of 236,054 KB)...
    [2026-09-27 22:54:25] Download complete.
    [2026-09-27 22:54:25] Extracting package...
    [2026-09-27 22:54:30] Installing update...
    [2026-09-27 22:54:34] Update complete, launching Steam...
    [2026-09-27 22:54:34] Shutdown
    [2026-09-27 22:54:36] Startup - updater built Sep  2 2026 18:32:43
    [2026-09-27 22:54:36] Startup - Steam Client launched with: "C:\Program Files (x86)\Steam\steam.exe" -no-cef-sandbox -cef-disable-gpu -cef-in-process-gpu -silent
    [2026-09-27 22:54:36] Verification complete
    [2026-09-27 22:56:51] Nothing to do
    [2026-09-27 23:09:09] Shutdown
    [2026-09-27 23:09:10] Startup - updater built Sep  2 2026 18:32:43
    [2026-09-27 23:09:10] Startup - Steam Client launched with: "C:\Program Files (x86)\Steam\steam.exe" -no-cef-sandbox -noverifyfiles -cef-disable-gpu -cef-in-process-gpu
    [2026-09-27 23:09:10] Verification skipped
    [2026-09-27 23:09:10] Verification complete
    """#

    /// `webhelper.txt`, verbatim, truncated after the flags that matter.
    static let webHelperLog = #"""
    [2026-09-27 22:54:46] Startup - webhelper launched pid: 608 commandline: "C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper.exe" -nocrashdialog -lang=en_US -cachedir="C:\users\crossover\AppData\Local\Steam\htmlcache" -steampid=568 -buildid=1788652215 -steamid=0
    [2026-09-27 23:09:08] Shutdown
    [2026-09-27 23:09:11] Startup - webhelper launched pid: 1620 commandline: "C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper_real.exe" --disable-gpu --in-process-gpu -nocrashdialog -lang=en_US -steampid=1560 -buildid=1788652215
    """#

    /// A log as it stood at `time` ("22:53:31"), CRLF like the real one.
    private func log(_ text: String, at time: String) -> String {
        let cutoff = "2026-09-27 \(time)"
        return text
            .split(whereSeparator: \.isNewline)
            .filter { line in SteamCEFShim.logTimestamp(line).map { $0 <= cutoff } ?? false }
            .joined(separator: "\r\n")
    }

    private func session(at time: String) -> SteamCEFShim.UpdaterSession? {
        SteamCEFShim.lastUpdaterSession(inLog: log(Self.bootstrapLog, at: time))
    }

    private func state(
        at time: String,
        helpers: Set<String>,
        running: Bool = true,
        goneFor: TimeInterval = 0,
        quietFor: TimeInterval = 0
    ) -> SteamCEFShim.FirstRunState {
        SteamCEFShim.firstRunState(
            SteamCEFShim.FirstRunInputs(
                clientRunning: running,
                clientGoneFor: goneFor,
                session: session(at: time),
                webHelper: SteamCEFShim.lastWebHelperLaunch(inLog: log(Self.webHelperLog, at: time)),
                helperVariants: helpers,
                quietFor: quietFor
            )
        )
    }

    // MARK: - The moments build 3 got wrong

    /// **22:39:23.** Build 3's 180 s wait for a helper ran out here and Setup
    /// failed. Steam was a third of the way through a healthy download.
    @Test func threeMinutesIntoTheDownloadIsStillDownloading() {
        #expect(state(at: "22:39:23", helpers: []) == .keepWaiting("Downloading Steam: 75 of 236 MB…"))
    }

    /// **22:53:31.** Build 3 sent the first of three `-shutdown`s here. The
    /// 64-bit client was 191 MB into 230, `cef.win7x64` had been on disk for
    /// four minutes, and Steam had never launched a helper.
    @Test func midDownloadWithAHelperOnDiskIsStillDownloading() {
        let now = state(at: "22:53:31", helpers: ["cef.win7x64"])
        #expect(now == .keepWaiting("Downloading Steam: 191 of 230 MB…"))
    }

    /// **22:54:34–36.** The updater exits and starts the client it installed.
    /// For a moment there is no `steam.exe`, and that is not an exit.
    @Test func theUpdatersRelaunchIsWaitedOut() {
        let gap = state(at: "22:54:35", helpers: ["cef.win7x64", "cef.win64"], running: false, goneFor: 1)
        #expect(gap == .keepWaiting("Steam is restarting to finish installing…"))
    }

    /// **22:54:46.** The relaunched client starts its UI from `cef.win64`. That
    /// is the finish line: stop it here, shim, and relaunch.
    @Test func theClientsFirstUILaunchIsTheFinishLine() {
        #expect(state(at: "22:54:46", helpers: ["cef.win7x64", "cef.win64"]) == .uiLaunched(variant: "cef.win64"))
    }

    // MARK: - The failed download

    /// **22:48:20.** Steam's updater gives up and puts up its own error. The
    /// person is told what to do about it.
    @Test func aFailedDownloadSaysWhatToDo() {
        guard case .keepWaiting(let status) = state(at: "22:48:30", helpers: [], quietFor: 10) else {
            Issue.record("a running Steam behind its error dialog is not finished, and not stalled yet")
            return
        }
        #expect(status.contains("download failed"))
        #expect(status.contains("close it"))
    }

    /// **22:49:10.** They closed it. A Steam that exits before its UI came up
    /// is started again, which resumes the download: the next run found every
    /// package already there and went straight to installing.
    @Test func steamThatQuitsBeforeItsUIIsStartedAgain() {
        #expect(state(at: "22:49:12", helpers: [], running: false, goneFor: 25) == .exitedEarly)
        // …but not while it might still be starting or relaunching.
        #expect(state(at: "22:49:12", helpers: [], running: false, goneFor: 5) != .exitedEarly)
    }

    // MARK: - Stopped bottles

    /// **23:09:09**, after the stop. The install finished and the variant it
    /// launched from is on disk: nothing to bootstrap, only the shim to write.
    @Test func aFinishedInstallNeedsNoBootstrap() {
        let variant = SteamCEFShim.launchedUIVariant(
            webHelper: SteamCEFShim.lastWebHelperLaunch(inLog: log(Self.webHelperLog, at: "23:09:09")),
            session: session(at: "23:09:09"),
            helperVariants: ["cef.win7x64", "cef.win64"]
        )
        #expect(variant == "cef.win64")
    }

    /// **23:09:10.** A new session has begun and its client has not launched a
    /// helper yet. The 22:54:46 launch belongs to the session before it and
    /// says nothing about this one.
    @Test func aLaunchFromBeforeTheNewestSessionDoesNotCount() {
        #expect(!state(at: "23:09:10", helpers: ["cef.win7x64", "cef.win64"]).isFinished)
    }

    /// **23:09:11.** The shimmed launch, and the one after it that drew.
    @Test func theShimmedLaunchIsSeen() {
        #expect(state(at: "23:09:11", helpers: ["cef.win7x64", "cef.win64"]) == .uiLaunched(variant: "cef.win64"))
        #expect(SteamCEFShim.lastWebHelperLaunch(inLog: log(Self.webHelperLog, at: "23:09:11"))?.shimmed == true)
    }

    /// The same, read off a bottle on disk: the interrupted layout of 22:53:31,
    /// then the finished one of 23:09:09.
    @Test func aStoppedBottleIsReadFromDisk() throws {
        let fixture = try CEFBottleFixture()
        defer { fixture.cleanUp() }
        try fixture.makeValveVariant("cef.win7x64")
        try fixture.writeBootstrapLog(log(Self.bootstrapLog, at: "22:53:31"))
        #expect(!SteamCEFShim.hasLaunchedUISinceLastUpdate(in: fixture.bottle))

        try fixture.makeValveVariant("cef.win64")
        try fixture.writeBootstrapLog(log(Self.bootstrapLog, at: "23:09:09"))
        try fixture.writeWebHelperLog(log(Self.webHelperLog, at: "23:09:09"))
        #expect(SteamCEFShim.hasLaunchedUISinceLastUpdate(in: fixture.bottle))
    }

    // MARK: - Reading the updater

    @Test func sessionsFollowTheLog() {
        #expect(session(at: "22:36:25") == .init(startedAt: "2026-09-27 22:36:25", phase: .starting))
        #expect(session(at: "22:39:23")?.phase == .downloading(doneKB: 77_631, totalKB: 241_937))
        #expect(session(at: "22:48:20")?.phase == .downloadFailed)
        #expect(session(at: "22:49:19") == .init(startedAt: "2026-09-27 22:49:17", phase: .installing))
        // Relaunch, shutdown and the new session all inside one second.
        #expect(session(at: "22:49:27") == .init(
            startedAt: "2026-09-27 22:49:27",
            phase: .downloading(doneKB: nil, totalKB: nil)
        ))
        #expect(session(at: "22:54:34")?.phase == .relaunching)
        #expect(session(at: "22:54:36") == .init(startedAt: "2026-09-27 22:54:36", phase: .starting))
    }

    @Test func noSessionBeforeSteamHasRun() {
        #expect(SteamCEFShim.lastUpdaterSession(inLog: "") == nil)
    }

    /// The figures carry the prefix locale's separators.
    @Test func downloadFiguresKeepOnlyDigits() {
        for line in [
            "[2026-09-27 22:40:04] Downloading update (85,858 of 241,937 KB)...",
            "[2026-09-27 22:40:04] Downloading update (85.858 of 241.937 KB)...",
            "[2026-09-27 22:40:04] Downloading update (85 858 of 241 937 KB)...",
            "[2026-09-27 22:40:04] Downloading update (85\u{00A0}858 of 241\u{00A0}937 KB)..."
        ] {
            let figures = SteamCEFShim.downloadFigures(line)
            #expect(figures?.done == 85_858, "\(line)")
            #expect(figures?.total == 241_937, "\(line)")
        }
        #expect(SteamCEFShim.downloadFigures("[2026-09-27 22:49:27] Downloading update...") == nil)
    }

    /// Ten minutes of nothing from a running Steam ends the wait with a
    /// reason. Tonight's longest silence was 50 s.
    @Test func aSilentSteamIsGivenUpOnAfterTenMinutes() {
        #expect(state(at: "22:53:31", helpers: ["cef.win7x64"], quietFor: 599) != .stalled("Downloading Steam: 191 of 230 MB…"))
        #expect(state(at: "22:53:31", helpers: ["cef.win7x64"], quietFor: 600) == .stalled("Downloading Steam: 191 of 230 MB…"))
    }
}

private extension SteamCEFShim.FirstRunState {
    var isFinished: Bool {
        if case .uiLaunched = self { return true }
        return false
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

    func writeBootstrapLog(_ text: String) throws {
        try FileManager.default.createDirectory(at: logsRoot, withIntermediateDirectories: true)
        try text.write(to: SteamCEFShim.bootstrapLogURL(in: bottle), atomically: true, encoding: .utf8)
    }

    private func write(_ url: URL, bytes: Int) throws {
        try Data(count: bytes).write(to: url)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}
