import Foundation
import Testing
@testable import WynKit

@Suite("Ubisoft Connect startup")
struct ConnectLauncherTests {
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
