import Foundation
import Testing
@testable import WynKit

/// Solarpunk ran on DXMT for the first time on 5 Sep 2026 — five launches, all
/// clean, on the default path — and `wyn profiles performance` reported:
///
///     Layer that actually ran: unrecognised adapter "Apple M4"
///
/// Correct at the time and better than guessing, but it means the one thing
/// this file exists to answer went unanswered for the layer most users will
/// actually be on. 119 of 121 bundled profiles are `guessed` and both verified
/// ones were D3DMetal, so DXMT is the path nobody had measured.
///
/// DXMT is also the odd one out: D3DMetal claims to be an AMD card and DXVK an
/// NVIDIA one, so both are identified by an invented vendor id. DXMT reports
/// the real GPU under Apple's own — the adapter string is the truth, not a
/// disguise.
@Suite("DXMT detection")
struct DXMTDetectionTests {

    private func log(vendor: String, adapter: String) -> String {
        """
        [2026.09.05-16.25.07:488][  0]LogRHI: Using Default RHI: D3D11
        [2026.09.05-16.25.07:488][  0]LogD3D11RHI:     Description : \(adapter)
        [2026.09.05-16.25.07:488][  0]LogD3D11RHI:     VendorId    : \(vendor)
        [2026.09.05-16.25.07:488][  0]LogConfig: Set CVar [[r.setres:1280x720]]
        """
    }

    private func read(_ text: String) -> SessionPerformance.Report {
        SessionPerformance.read(logText: text, logURL: URL(fileURLWithPath: "/tmp/Game.log"))
    }

    /// The real shape, copied from the first measured DXMT session.
    @Test func appleVendorIdIsDXMT() {
        let report = read(log(vendor: "106b", adapter: "Apple M4"))
        #expect(report.layer == .dxmt)
        #expect(report.layer?.translationLayer == .dxmt)
        #expect(report.layer?.displayName.contains("DXMT") == true)
    }

    /// Any Apple GPU, not just the one this was found on — the vendor id is
    /// what identifies the layer, and the adapter name varies by machine.
    @Test func anyAppleGpuIsStillDXMT() {
        #expect(read(log(vendor: "106b", adapter: "Apple M1 Pro")).layer == .dxmt)
        #expect(read(log(vendor: "106B", adapter: "Apple M3 Max")).layer == .dxmt)
    }

    /// The other two must not move. Their whole value is that a faked adapter
    /// tells you which layer really ran when the profile cannot.
    @Test func theOtherTwoAreUnchanged() {
        #expect(read(log(vendor: "1002", adapter: "AMD Compatibility Mode")).layer == .d3dMetal)
        #expect(read(log(vendor: "10de", adapter: "NVIDIA GeForce 6800")).layer == .dxvk)
    }

    /// And a vendor nobody has taught it about is still named, never guessed.
    @Test func anUnknownVendorIsStillNotGuessedAt() {
        #expect(read(log(vendor: "8086", adapter: "Intel Iris")).layer == .unrecognised("Intel Iris"))
    }

    /// A dxmt profile that really ran on DXMT must not produce a wrong-layer
    /// finding. Before this, every DXMT session would have been reported as
    /// `unrecognised` with no translationLayer, so the comparison silently did
    /// not happen at all.
    @Test func aDxmtProfileOnDxmtIsNotFlaggedAsTheWrongLayer() {
        let report = read(log(vendor: "106b", adapter: "Apple M4"))
        let findings = SessionPerformance.findings(report, expecting: .dxmt)
        #expect(!findings.joined(separator: "\n").contains("WRONG LAYER"))
    }

    /// And a dxmt profile that quietly got D3DMetal instead — the exact thing
    /// that happened twice on 5 Sep — must now be caught.
    @Test func aDxmtProfileThatGotD3DMetalIsCaught() {
        let report = read(log(vendor: "1002", adapter: "AMD Compatibility Mode"))
        let text = SessionPerformance.findings(report, expecting: .dxmt).joined(separator: "\n")
        #expect(text.contains("WRONG LAYER"))
    }
}
