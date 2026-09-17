import Foundation
import Testing
@testable import WynKit

@Suite("Ubisoft Connect startup")
struct ConnectLauncherTests {
    @Test func paintedSignInPageOpensTileButDoesNotAuthorizeGame() {
        let log = "StartView.cpp\nClient launched with argOffline: false"
        #expect(ConnectLauncher.startupStatus(log: log, elapsedSeconds: 20,
                                             isRunning: true, hasFrame: true) == .ready)
        #expect(ConnectLauncher.authenticationStatus(log: log, elapsedSeconds: 20,
                                                     isRunning: true) == .waiting)
        #expect(ConnectLauncher.authenticationStatus(log: log, elapsedSeconds: 120,
                                                     isRunning: true) == .failed)
    }

    @Test func accountFromEarlierStartupCannotAuthorizeRestart() {
        let old = "Client launched\nAccountStartupUser.cpp (238) User: test-account\n"
        #expect(ConnectLauncher.authenticationStatus(log: old, elapsedSeconds: 20,
                                                     isRunning: true) == .ready)
        let restarted = old + "StartView.cpp\nClient launched with argOffline: false\n"
        #expect(ConnectLauncher.authenticationStatus(log: restarted, elapsedSeconds: 120,
                                                     isRunning: true) == .failed)
        #expect(ConnectLauncher.authenticationStatus(
            log: restarted + "AccountStartupUser.cpp (238) User: test-account",
            elapsedSeconds: 20, isRunning: true) == .ready)
    }

    @Test func existingProcessRequiresDatedAccountEvidenceFromItsOwnLifetime() throws {
        let start = try #require(ConnectLauncher.launcherTimestamp("2026-09-14 00:09:17"))
        for line in [
            "2026-09-10 18:24:02 AccountStartupUser.cpp (238) User: test-account",
            "AccountStartupUser.cpp (238) User: test-account",
            "2026-09-14 00:09:30 AccountStartupUser.cpp (238) failed",
            "2026-09-14 00:09:30 AccountStartupUser.cpp (238) User: "
        ] {
            #expect(ConnectLauncher.authenticationStatus(log: line, elapsedSeconds: 120,
                isRunning: true, processStartedAt: start) == .failed)
        }
        let current = "2026-09-14 00:09:30 AccountStartupUser.cpp (238) User: test-account"
        #expect(ConnectLauncher.authenticationStatus(log: current, elapsedSeconds: 20,
            isRunning: true, processStartedAt: start) == .ready)
        #expect(ConnectLauncher.authenticationStatus(log: current, elapsedSeconds: 20,
            isRunning: false, processStartedAt: start) == .failed)
    }

    @Test func processStartParsingRejectsMissingAndAmbiguousClients() throws {
        let client = #"Mon Sep 14 00:09:17 2026 C:\Program Files (x86)\Ubisoft\upc.exe"#
        let expected = try #require(ConnectLauncher.launcherTimestamp("2026-09-14 00:09:17"))
        #expect(ConnectLauncher.connectStartDate(processListing: client) == expected)
        #expect(ConnectLauncher.connectStartDate(processListing: "") == nil)
        #expect(ConnectLauncher.connectStartDate(processListing: client + "\n" + client) == nil)
        #expect(ConnectLauncher.connectStartDate(processListing:
            client.replacingOccurrences(of: "upc.exe", with: "UplayWebCore.exe")) == nil)
        #expect(ConnectLauncher.connectStartDate(processListing:
            #"Wed Sep  9 01:00:00 2026 C:\Ubisoft\upc.exe"#) != nil)
    }

    /// `ps -o lstart` is locale-formatted. This is the line an en_ZA Mac printed
    /// on 15 Sep 2026 while Connect was signed in and the launch was refused.
    @Test func processStartParsingAcceptsDayFirstLocales() throws {
        let dayFirst = #"Tue 15 Sep 23:34:29 2026     C:\Program Files (x86)\Ubisoft\Ubisoft Game Launcher\upc.exe"#
        let expected = try #require(ConnectLauncher.launcherTimestamp("2026-09-15 23:34:29"))
        #expect(ConnectLauncher.connectStartDate(processListing: dayFirst) == expected)
    }

    /// 15 Sep 2026 21:42 (game-host) and 9 Sep 19:32 (wine 11.0): the account
    /// line appeared, ownership then failed, and the client showed dolphin-028.
    /// Measured 17 Sep 2026: running `wyn connect status` from a shell whose own
    /// command line contained "upc.exe" reported Connect as running with no
    /// Connect on the machine. Detection must key on the executable's path.
    @Test func aCommandLineMentioningConnectIsNotConnect() {
        #expect(!PlatformCatalog.lineLooksLike(.ubisoft, "pgrep -fl 'upc.exe|steam.exe'"))
        #expect(!PlatformCatalog.lineLooksLike(.ubisoft, "/bin/zsh -c echo upc.exe"))
        #expect(PlatformCatalog.lineLooksLike(
            .ubisoft, #"C:\Program Files (x86)\Ubisoft\Ubisoft Game Launcher\upc.exe --no-sandbox"#))
        #expect(!PlatformCatalog.lineLooksLike(
            .ubisoft, #"C:\Program Files (x86)\Ubisoft\Ubisoft Game Launcher\UplayWebCore.exe"#))
    }

    @Test func ownershipFailureAfterSignInIsReported() {
        let log = """
        Client launched with argOffline: false
        2026-09-15 21:42:54 AccountStartupUser.cpp (238) User: test-account
        2026-09-15 21:43:24 ERROR DemuxFailReason.cpp (16) 11-5002,4004, Ownership connection is not set up with 0 retries
        2026-09-15 21:43:26 ERROR ConnectView.cpp (1066) dolphin-028, Shell recovery page, recovery page is set: true
        """
        #expect(ConnectLauncher.ownershipStatus(log: log) == .failed("dolphin-028"))
    }

    /// 10 Sep 18:47, after 23 minutes of play: the connection dropped. That is a
    /// network event, not a startup failure, and must not block a launch.
    @Test func ownershipLostAfterPlayIsNotAStartupFailure() {
        let log = """
        Client launched with argOffline: false
        2026-09-10 18:24:02 AccountStartupUser.cpp (238) User: test-account
        2026-09-10 18:47:07 WARNING DemuxFailReason.cpp (22) 9-5002,10060-1016,2016, Ownership connection lost
        """
        #expect(ConnectLauncher.ownershipStatus(log: log) == .ok)
    }

    @Test func ownershipFailureFromAnEarlierSessionIsIgnored() {
        let log = """
        Client launched with argOffline: false
        2026-09-15 21:43:24 ERROR DemuxFailReason.cpp (16) 11-5002,4004, Ownership connection is not set up with 0 retries
        2026-09-15 21:43:26 ERROR ConnectView.cpp (1066) dolphin-028, Shell recovery page
        Client launched with argOffline: false
        2026-09-15 21:50:50 AccountStartupUser.cpp (238) User: test-account
        """
        #expect(ConnectLauncher.ownershipStatus(log: log) == .ok)
    }

    /// Real `launcher_log.txt` shape: pid column, two timestamps, source file.
    /// The timestamp `2026-09-15 21:43:24` also matches a hyphenated code.
    @Test func ownershipCodeComesFromTheErrorNotTheTimestamp() {
        let log = """
        [   332]  2026-09-15 21:42:23      [   336]     INFO       Client launched with argOffline: false
        [   332]  2026-09-15 21:42:54      [   420]     INFO       AccountStartupUser.cpp (238)  User: test-account
        [   332]  2026-09-15 21:43:24      [   416]     ERROR      DemuxFailReason.cpp (16)  11-5002,4004, Ownership connection is not set up with 0 retries
        """
        #expect(ConnectLauncher.ownershipStatus(log: log) == .failed("11-5002,4004"))
    }

    @Test func parkingTheBrowserCacheRenamesItAndKeepsEverything() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "ConnectCacheTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appending(path: "drive_c/users/tester/AppData/Local")
            .appending(path: "Ubisoft Game Launcher/cache/http2")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let cookie = cache.appending(path: "Cookies")
        try Data("not-a-real-cookie".utf8).write(to: cookie)

        let bottle = Bottle(bottleUrl: root)
        #expect(ConnectLauncher.browserCacheDirectory(in: bottle) != nil)

        let stamp = try #require(ConnectLauncher.launcherTimestamp("2026-09-15 21:38:14"))
        let moved = try ConnectLauncher.parkBrowserCache(in: bottle, at: stamp)
        let parked = try #require(moved)

        #expect(parked.lastPathComponent == "http2.parked-20260915-213814")
        // Renamed, not deleted: the contents survive and the live path is gone.
        #expect(FileManager.default.fileExists(atPath: parked.appending(path: "Cookies").path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: cache.path(percentEncoded: false)))
        #expect(ConnectLauncher.browserCacheDirectory(in: bottle) == nil)
    }

    @Test func parkedCacheNameIsDatedAndNeverTheLiveDirectory() throws {
        let stamp = try #require(ConnectLauncher.launcherTimestamp("2026-09-15 21:38:14"))
        let name = ConnectLauncher.parkedCacheName(at: stamp)
        #expect(name == "http2.parked-20260915-213814")
        #expect(name != "http2")
    }

    @Test func cefArgsKeepInProcessGpuSoFLY4GetsStretchBlts() {
        #expect(ConnectLauncher.cefArgs.contains("--in-process-gpu"))
        #expect(!ConnectLauncher.cefArgs.contains("--disable-gpu"))
    }

    @Test func d3dmetalOdysseyPlayDoesNotKeepFrankea() {
        var keep = Wine.LaunchOptions()
        keep.preferFrankeaSteam = true
        #expect(SteamLauncher.ubisoftConnectForcesFrankea(options: keep))

        var migrate = Wine.LaunchOptions()
        migrate.preferD3DMetalAuth = true
        #expect(!SteamLauncher.ubisoftConnectForcesFrankea(options: migrate))

        #expect(!SteamLauncher.ubisoftConnectForcesFrankea(options: Wine.LaunchOptions()))
    }

    @Test func gameHostConnectIsReadyWithoutFLY4() {
        let signedIn = """
        Using CEF with native rendering
        StartView.cpp (1125)
        AccountStartupUser.cpp (238)   User: 0ba37e39-a9ee-4133-b6ea-a727ea09490f
        """
        #expect(ConnectLauncher.gameHostStartupStatus(
            log: signedIn, elapsedSeconds: 12, isRunning: true
        ) == .ready)
        #expect(ConnectLauncher.gameHostStartupStatus(
            log: "Using CEF with native rendering", elapsedSeconds: 12, isRunning: true
        ) == .waiting)
        #expect(ConnectLauncher.gameHostStartupStatus(
            log: signedIn, elapsedSeconds: 16, isRunning: false
        ) == .failed)
        #expect(ConnectLauncher.gameHostStartupStatus(
            log: "", elapsedSeconds: 120, isRunning: true
        ) == .failed)
    }

    /// 10 Sep: three launches in a row reported ready while Connect sat on
    /// Ubisoft's bot-check page. The client is running and has reached
    /// StartView — it just cannot authenticate anything, because the Windows
    /// user it resolved to held no token. Reaching the shell is not signing in.
    @Test func aConnectParkedOnTheBotCheckPageIsNotReady() {
        let blocked = """
        Using CEF with native rendering
        StartView.cpp (1125)
        Startup.cpp (164)   Client launched with argOffline: false
        CefClientHandler.cpp (215)   Close for browser with id: 4
        """
        for second in [12, 30, 60, 119] {
            #expect(ConnectLauncher.gameHostStartupStatus(
                log: blocked, elapsedSeconds: second, isRunning: true
            ) == .waiting)
        }
        // It must time out rather than ever passing as ready.
        #expect(ConnectLauncher.gameHostStartupStatus(
            log: blocked, elapsedSeconds: 120, isRunning: true
        ) == .failed)
        // The same log, once an account resolves, is ready.
        #expect(ConnectLauncher.gameHostStartupStatus(
            log: blocked + "\nAccountStartupUser.cpp (238)   User: 0ba37e39",
            elapsedSeconds: 12, isRunning: true
        ) == .ready)
    }

    /// Pins the settle, because the number is the whole fix and a future
    /// tidy-up would otherwise delete it as a magic constant.
    ///
    /// 10 Sep, six runs: a game launched ~1s after `AccountStartupUser` made
    /// Connect re-run its startup and crash (2/2); at 35s–7min it was healthy
    /// (4/4). The shortest observed healthy gap was 35s, so the settle must
    /// stay meaningfully above the failing case. If someone finds a real
    /// readiness marker in Connect's log, replace the wait — do not just
    /// shrink it because launches feel slow.
    @Test func connectSettlesLongEnoughForAGameToBeAccepted() {
        #expect(ConnectLauncher.signedInSettleSeconds >= 20,
                "below ~20s this stops protecting against the observed 1s failure")
        #expect(ConnectLauncher.signedInSettleSeconds <= 60,
                "a minute of dead time per launch needs a better answer than a longer wait")
    }

    @Test func slowCEFInitializationCanStillPaint() {
        let cef = "Using CEF with native rendering"
        for second in [10, 20, 40, 60, 90] {
            #expect(ConnectLauncher.startupStatus(log: cef, elapsedSeconds: second,
                                                isRunning: true, hasFrame: false) == .waiting)
        }
        #expect(ConnectLauncher.startupStatus(log: cef + "\nStartView.cpp (1125)",
                                            elapsedSeconds: 91, isRunning: true,
                                            hasFrame: true) == .ready)
    }

    @Test func transparentStartViewDoesNotCountAsReady() {
        #expect(ConnectLauncher.startupStatus(log: "StartView.cpp", elapsedSeconds: 50,
                                            isRunning: true, hasFrame: false) == .waiting)
        #expect(ConnectLauncher.startupStatus(log: "StartView.cpp", elapsedSeconds: 120,
                                            isRunning: true, hasFrame: false) == .failed)
        #expect(ConnectLauncher.startupStatus(log: "StartView.cpp", elapsedSeconds: 60,
                                            isRunning: false, hasFrame: true) == .failed)
    }

    @Test func oldLogEntriesCannotPassANewLaunch() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let old = Data("StartView.cpp old session\n".utf8)
        try (old + Data("Using CEF with native rendering\n".utf8)).write(to: url)
        let tail = ConnectLauncher.logTail(url, offset: old.count)
        #expect(!tail.contains("StartView.cpp"))
        #expect(tail.contains("Using CEF"))
    }

    @Test func fly4SurfaceRequiresMagicHwndAndPixels() {
        #expect(!ConnectLauncher.fly4SurfaceLooksPainted(Data()))
        #expect(!ConnectLauncher.fly4SurfaceLooksPainted(fly4Surface(width: 16, height: 16,
                                                                    hwnd: 1, fill: 0)))
        #expect(!ConnectLauncher.fly4SurfaceLooksPainted(fly4Surface(width: 16, height: 16,
                                                                    hwnd: 0, fill: 0x00FF_FF00)))
        var truncated = fly4Surface(width: 16, height: 16, hwnd: 1, fill: 0x00FF_FF00)
        truncated.removeLast()
        #expect(!ConnectLauncher.fly4SurfaceLooksPainted(truncated))
        #expect(ConnectLauncher.fly4SurfaceLooksPainted(fly4Surface(width: 16, height: 16,
                                                                    hwnd: 1, fill: 0x00FF_FF00)))
        // Partial CEF dirty rects (e.g. 942×633) are valid FLY4 frames.
        #expect(ConnectLauncher.fly4SurfaceLooksPainted(fly4Surface(width: 942, height: 633,
                                                                    hwnd: 0x601E0, fill: 0x0010_2030)))
    }

    private func fly4Surface(width: Int, height: Int, hwnd: UInt64, fill: UInt32) -> Data {
        var bytes = Data(count: 64 + width * height * 4)
        func write32(_ offset: Int, _ value: UInt32) {
            for i in 0..<4 {
                bytes[offset + i] = UInt8((value >> (8 * i)) & 0xFF)
            }
        }
        func write64(_ offset: Int, _ value: UInt64) {
            for i in 0..<8 {
                bytes[offset + i] = UInt8((value >> (8 * i)) & 0xFF)
            }
        }
        write32(0, 0x3459_4C46)
        write32(4, UInt32(width))
        write32(8, UInt32(height))
        write64(16, hwnd)
        if fill != 0 {
            var i = 64
            while i + 4 <= bytes.count {
                write32(i, fill)
                i += 4
            }
        }
        return bytes
    }
}
