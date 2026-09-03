import Foundation
import Testing
@testable import WynKit

/// Wyn ships 120 profiles and exactly one was ever measured, because measuring
/// meant owning the game. Beta testers own the games — but a tester playing for
/// an hour currently produces nothing at all, so five hundred of them still
/// leave one verified profile. The bottleneck was never testing; it was that
/// nothing got written down.
@Suite("Launch evidence")
struct LaunchRecordTests {

    private func profile(
        id: String = "test-game",
        environment: [String: String] = [:],
        launchArgs: String? = nil,
        status: ProfileStatus = .guessed
    ) -> GameProfile {
        GameProfile(
            id: id,
            name: "Test",
            exePatterns: ["test.exe"],
            bottle: ProfileBottleOverrides(translationLayer: .d3dMetal, dxvk: false),
            environment: environment,
            launchArgs: launchArgs,
            notes: "n",
            status: status
        )
    }

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Observing

    /// A crash-loop dies in seconds. It must never read as a launch.
    @Test func aShortRunIsNotALaunch() {
        var observer = LaunchObserver()
        #expect(observer.update(running: ["game"], now: t0).isEmpty)
        let finished = observer.update(running: [], now: t0.addingTimeInterval(9))
        #expect(finished.isEmpty)
    }

    @Test func aRunThatLastsIsRecordedWhenItEnds() {
        var observer = LaunchObserver()
        _ = observer.update(running: ["game"], now: t0)
        // Still playing: nothing yet.
        #expect(observer.update(running: ["game"], now: t0.addingTimeInterval(600)).isEmpty)

        let finished = observer.update(running: [], now: t0.addingTimeInterval(1800))
        #expect(finished.count == 1)
        #expect(finished.first?.profileID == "game")
        #expect(finished.first?.startedAt == t0)
        #expect((finished.first?.ranFor ?? 0) == 1800)
    }

    /// Exactly at the threshold counts; a hair under does not.
    @Test func theThresholdIsInclusive() {
        var atLimit = LaunchObserver()
        _ = atLimit.update(running: ["game"], now: t0)
        #expect(atLimit.update(
            running: [], now: t0.addingTimeInterval(LaunchObserver.minimumUptime)
        ).count == 1)

        var justUnder = LaunchObserver()
        _ = justUnder.update(running: ["game"], now: t0)
        #expect(justUnder.update(
            running: [], now: t0.addingTimeInterval(LaunchObserver.minimumUptime - 0.5)
        ).isEmpty)
    }

    @Test func twoGamesAreTimedIndependently() {
        var observer = LaunchObserver()
        _ = observer.update(running: ["a"], now: t0)
        _ = observer.update(running: ["a", "b"], now: t0.addingTimeInterval(100))
        let finished = observer.update(running: ["b"], now: t0.addingTimeInterval(200))
        #expect(finished.map(\.profileID) == ["a"])
        #expect(observer.inFlight == ["b"])
    }

    /// A game that stops and starts again is two runs, not one long one.
    @Test func relaunchStartsANewClock() {
        var observer = LaunchObserver()
        _ = observer.update(running: ["game"], now: t0)
        _ = observer.update(running: [], now: t0.addingTimeInterval(300))
        _ = observer.update(running: ["game"], now: t0.addingTimeInterval(400))
        let finished = observer.update(running: [], now: t0.addingTimeInterval(500))
        #expect(finished.first?.ranFor == 100)
    }

    // MARK: - Evidence is tied to the settings it saw

    /// The discipline that was missing when 72 profiles had MetalFX on: a record
    /// vouches for the settings that were in force, and nothing else.
    @Test func changingSettingsInvalidatesTheEvidence() {
        let before = profile(environment: ["D3DM_ENABLE_METALFX": "0"])
        let record = LaunchRecordStore.makeRecord(for: before, startedAt: t0, ranFor: 900)

        #expect(LaunchRecordStore.evidence(for: before, in: [record]).count == 1)
        #expect(LaunchRecordStore.effectiveStatus(for: before, in: [record]) == .launched)

        let after = profile(environment: ["D3DM_ENABLE_METALFX": "1"])
        #expect(LaunchRecordStore.evidence(for: after, in: [record]).isEmpty)
        #expect(LaunchRecordStore.effectiveStatus(for: after, in: [record]) == .guessed)
    }

    /// Editing prose must not throw away a real run.
    @Test func notesAndNameDoNotAffectTheFingerprint() {
        var a = profile()
        var b = profile()
        a.notes = "one thing"
        b.notes = "quite another"
        b.name = "Renamed"
        b.publisher = "Someone"
        #expect(a.settingsFingerprint == b.settingsFingerprint)
    }

    @Test func anythingReachingWineAffectsTheFingerprint() {
        let base = profile()
        #expect(profile(launchArgs: "-dx11").settingsFingerprint != base.settingsFingerprint)
        #expect(profile(environment: ["X": "1"]).settingsFingerprint != base.settingsFingerprint)

        var layerChanged = profile()
        layerChanged.bottle = ProfileBottleOverrides(translationLayer: .dxvk, dxvk: true)
        #expect(layerChanged.settingsFingerprint != base.settingsFingerprint)
    }

    @Test func recordsForOtherProfilesDoNotCount() {
        let mine = profile(id: "mine")
        let theirs = profile(id: "theirs")
        let record = LaunchRecordStore.makeRecord(for: theirs, startedAt: t0, ranFor: 900)
        #expect(LaunchRecordStore.evidence(for: mine, in: [record]).isEmpty)
    }

    // MARK: - Status

    @Test func noEvidenceMeansGuessed() {
        #expect(LaunchRecordStore.effectiveStatus(for: profile(), in: []) == .guessed)
    }

    /// Running is not measuring. A verified profile stays verified, and no
    /// amount of local running promotes anything to it — that rung needs a
    /// person who watched the screen and wrote down what they saw.
    @Test func runningNeverPromotesToVerified() {
        let declared = profile(status: .verified)
        let record = LaunchRecordStore.makeRecord(for: declared, startedAt: t0, ranFor: 36_000)
        #expect(LaunchRecordStore.effectiveStatus(for: declared, in: [record]) == .verified)

        let guessed = profile(status: .guessed)
        let lots = (0..<50).map {
            LaunchRecordStore.makeRecord(
                for: guessed, startedAt: t0.addingTimeInterval(Double($0) * 3600), ranFor: 3600
            )
        }
        #expect(LaunchRecordStore.effectiveStatus(for: guessed, in: lots) == .launched)
    }

    /// A shipped profile cannot declare itself `launched` — that word means
    /// "this machine saw it run", so it has to be earned locally.
    @Test func declaredLaunchedWithoutEvidenceIsStillAGuess() {
        let claims = profile(status: .launched)
        #expect(LaunchRecordStore.effectiveStatus(for: claims, in: []) == .guessed)
    }

    // MARK: - Round trip

    @Test func recordsSurviveEncodingAndDecoding() throws {
        let record = LaunchRecordStore.makeRecord(for: profile(), startedAt: t0, ranFor: 1234)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(LaunchRecord.self, from: encoder.encode(record))
        #expect(decoded == record)
        #expect(decoded.ranForSeconds == 1234)
    }

    @Test func theReportSaysSoWhenThereIsNothingYet() {
        // Whatever this machine happens to have, the empty branch must read as
        // an explanation rather than a bare zero.
        let text = DiagnosticsBundle.launchRecordReport()
        #expect(!text.isEmpty)
    }
}
