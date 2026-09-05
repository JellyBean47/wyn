import Foundation
import Testing
@testable import WynKit

/// A model adding a game over MCP could previously see whether a profile
/// launched and nothing else. That was enough to miss a two-hour session
/// running on the wrong translation layer at a third of the frame rate, with
/// every tool reporting success.
@Suite("Session performance")
struct SessionPerformanceTests {

    /// Real shapes, copied from the logs both layers actually produced.
    private func log(vendor: String, adapter: String,
                     startMinute: Int = 11, framesPerSecond: Int = 120,
                     minutes: Int = 3) -> String {
        var lines = [
            "Log file open, 09/05/26 20:11:55",
            "LogRHI: Using Default RHI: D3D11",
            "[2026.09.05-18.11.57:353][  0]LogD3D11RHI:     Description : \(adapter)",
            "[2026.09.05-18.11.57:353][  0]LogD3D11RHI:     VendorId    : \(vendor)",
            "[2026.09.05-18.11.57:353][  0]LogConfig: Set CVar [[r.setres:1280x720]]",
            #"[2026.09.05-18.11.58:000][  0]r.ScreenPercentage = "45""#
        ]
        // One line per second so each minute bucket has full coverage.
        var frame = 0
        for minute in 0..<minutes {
            for second in 0..<60 {
                frame += framesPerSecond
                let mm = startMinute + minute
                lines.append(String(
                    format: "[2026.09.05-18.%02d.%02d:000][%3d]LogTemp: tick",
                    mm, second, frame
                ))
            }
        }
        return lines.joined(separator: "\n")
    }

    private func read(_ text: String) -> SessionPerformance.Report {
        SessionPerformance.read(logText: text, logURL: URL(fileURLWithPath: "/tmp/Game.log"))
    }

    // MARK: - Which layer ran

    /// The single most useful fact in the file, and the only reliable way to
    /// get it. Both strings are what the layers really report.
    @Test func theAdapterNamesTheLayer() {
        let metal = read(log(vendor: "1002", adapter: "AMD Compatibility Mode"))
        #expect(metal.layer == .d3dMetal)
        #expect(metal.layer?.translationLayer == .d3dMetal)

        let dxvk = read(log(vendor: "10de", adapter: "NVIDIA GeForce 6800"))
        #expect(dxvk.layer == .dxvk)
        #expect(dxvk.layer?.translationLayer == .dxvk)
    }

    /// A vendor nobody has taught it about is named, never guessed. Attributing
    /// the wrong layer is worse than admitting ignorance.
    @Test func anUnknownAdapterIsNotGuessedAt() {
        let other = read(log(vendor: "8086", adapter: "Intel Iris"))
        #expect(other.layer == .unrecognised("Intel Iris"))
        #expect(other.layer?.translationLayer == nil)
    }

    // MARK: - Frame rate

    @Test func framesPerMinuteComeOutOfTheLogPrefix() {
        let report = read(log(vendor: "1002", adapter: "AMD Compatibility Mode",
                              framesPerSecond: 120, minutes: 3))
        let fps = try? #require(report.fps)
        #expect(fps != nil)
        #expect((fps?.median ?? 0) > 115 && (fps?.median ?? 0) < 125)
        #expect(report.framesCounted > 0)
    }

    /// A quiet minute has almost nothing to divide by. Reporting it as a frame
    /// rate would be noise presented as measurement.
    @Test func aMinuteWithNoCoverageIsDroppedNotReported() {
        let sparse = """
        [2026.09.05-18.11.57:353][  0]LogD3D11RHI:     Description : AMD Compatibility Mode
        [2026.09.05-18.11.57:353][  0]LogD3D11RHI:     VendorId    : 1002
        [2026.09.05-18.20.00:000][100]LogTemp: one
        [2026.09.05-18.20.01:000][200]LogTemp: two
        """
        // Two lines a second apart is 1s of coverage, far under the threshold.
        #expect(read(sparse).fps == nil)
    }

    /// A level load resets the frame counter; treating that as elapsed frames
    /// would invent an enormous frame rate out of a loading screen.
    @Test func aCounterResetIsNotAFrameRate() {
        let reset = """
        [2026.09.05-18.11.57:353][  0]LogD3D11RHI:     Description : AMD Compatibility Mode
        [2026.09.05-18.11.57:353][  0]LogD3D11RHI:     VendorId    : 1002
        [2026.09.05-18.12.00:000][9000]LogTemp: before
        [2026.09.05-18.12.01:000][   1]LogTemp: after a load
        """
        #expect(read(reset).framesCounted == 0)
    }

    // MARK: - Resolution

    /// A frame rate means nothing without the pixel count that produced it.
    @Test func effectiveResolutionAccountsForScreenPercentage() {
        let report = read(log(vendor: "1002", adapter: "AMD Compatibility Mode"))
        #expect(report.resolution == "1280x720")
        #expect(report.screenPercentage == 45)
        #expect(report.effectiveResolution == "576x324")
    }

    /// Enabling hitch logging is not a hitch. Counting the line that turns the
    /// category on reported a phantom hitch on every healthy session — a signal
    /// that fires when nothing is wrong stops being read.
    @Test func enablingHitchLoggingIsNotAHitch() {
        let enabled = """
        [2026.09.05-18.11.57:353][  0]LogD3D11RHI:     Description : AMD Compatibility Mode
        [2026.09.05-18.11.57:353][  0]LogD3D11RHI:     VendorId    : 1002
        LogHAL: Log category LogHitchDetection verbosity has been raised to Verbose.
        [2026.09.05-18.11.57:509][  0]LogConfig: Set CVar [[t.HitchFrameTimeThreshold:33.3]]
        """
        #expect(read(enabled).hitches == 0)

        let real = enabled + "\n[2026.09.05-18.12.00:000][ 60]LogHitchDetector: Hitch detected 120ms"
        #expect(read(real).hitches == 1)
    }

    // MARK: - Findings, which are the point

    /// The finding that would have saved the whole investigation.
    @Test func aLayerThatIsNotTheOneAskedForIsTheFirstFinding() {
        let report = read(log(vendor: "10de", adapter: "NVIDIA GeForce 6800", framesPerSecond: 45))
        let findings = SessionPerformance.findings(report, expecting: .d3dMetal)
        let first = try? #require(findings.first)
        #expect(first?.contains("WRONG LAYER") == true)
        #expect(first?.contains("Wine tree") == true)
    }

    /// The diagnosis that took a day: slow *and* small is structural, and the
    /// instinct it must override is "turn the settings down".
    @Test func slowAtLowResolutionSaysNotToLowerSettings() {
        let report = read(log(vendor: "1002", adapter: "AMD Compatibility Mode",
                              framesPerSecond: 45))
        let findings = SessionPerformance.findings(report, expecting: .d3dMetal)
        let text = findings.joined(separator: "\n")
        #expect(text.contains("Slow at a low resolution"))
        #expect(text.lowercased().contains("do not respond by lowering settings"))
    }

    /// Fast at low resolution is not a problem to report.
    @Test func fastAtLowResolutionIsNotFlaggedAsSlow() {
        let report = read(log(vendor: "1002", adapter: "AMD Compatibility Mode",
                              framesPerSecond: 120))
        let text = SessionPerformance.findings(report, expecting: .d3dMetal).joined(separator: "\n")
        #expect(!text.contains("Slow at a low resolution"))
    }

    /// The right layer and a healthy frame rate should produce no alarm at all.
    /// A checker that always finds something is a checker nobody reads.
    @Test func aHealthySessionReportsNothingWrong() {
        let report = read(log(vendor: "1002", adapter: "AMD Compatibility Mode",
                              framesPerSecond: 60))
        #expect(SessionPerformance.findings(report, expecting: .d3dMetal).isEmpty)
        #expect(SessionPerformance.rendered(report, expecting: .d3dMetal)
            .contains("Nothing looks wrong"))
    }

    /// Without an expectation there is nothing to compare against, so it must
    /// not invent a layer complaint.
    @Test func noExpectedLayerMeansNoLayerComplaint() {
        let report = read(log(vendor: "10de", adapter: "NVIDIA GeForce 6800", framesPerSecond: 120))
        let text = SessionPerformance.findings(report).joined(separator: "\n")
        #expect(!text.contains("WRONG LAYER"))
    }

    // MARK: - The rendered report

    @Test func theReportLeadsWithTheLayer() {
        let report = read(log(vendor: "10de", adapter: "NVIDIA GeForce 6800", framesPerSecond: 45))
        let text = SessionPerformance.rendered(report, expecting: .d3dMetal)
        let lines = text.split(separator: "\n")
        #expect(lines.count > 3)
        #expect(lines[1].contains("Layer that actually ran"))
        #expect(text.contains("NVIDIA GeForce 6800"))
        #expect(text.contains("576x324"))
    }

    /// A profile with no unrealProject cannot be measured this way, and saying
    /// so beats returning an empty report that reads like a clean bill.
    @Test func aNonUnrealProfileSaysWhyItCannotBeMeasured() {
        let profile = GameProfile(id: "x", name: "X", steamAppId: 1, exePatterns: ["x.exe"])
        let bottle = Bottle(bottleUrl: URL.temporaryDirectory.appending(path: UUID().uuidString))
        let text = SessionPerformance.report(profile: profile, in: bottle)
        #expect(text.contains("unrealProject"))
    }
}
