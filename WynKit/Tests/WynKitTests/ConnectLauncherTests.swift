import Foundation
import Testing
@testable import WynKit

@Suite("Ubisoft Connect startup")
struct ConnectLauncherTests {
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

    @Test func frameMustBeFreshCompleteAndAddressAWindow() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let startedAt = Date().addingTimeInterval(-10)
        // FLY2 header: 16 x 16 BGRA, HWND 1, followed by a complete payload.
        var frame = Data([0x46, 0x4c, 0x59, 0x32, 16, 0, 0, 0, 16, 0, 0, 0,
                          1, 0, 0, 0, 0, 0, 0, 0])
        frame.append(Data(repeating: 255, count: 16 * 16 * 4))
        try frame.write(to: url)
        #expect(ConnectLauncher.hasFreshFrame(at: url, since: startedAt))
        #expect(!ConnectLauncher.hasFreshFrame(at: url, since: Date().addingTimeInterval(10)))
        try frame.dropLast().write(to: url)
        #expect(!ConnectLauncher.hasFreshFrame(at: url, since: startedAt))
        frame[12] = 0
        try frame.write(to: url)
        #expect(!ConnectLauncher.hasFreshFrame(at: url, since: startedAt))
        frame[12] = 1
        frame[0] = 0
        try frame.write(to: url)
        #expect(!ConnectLauncher.hasFreshFrame(at: url, since: startedAt))
    }
}
