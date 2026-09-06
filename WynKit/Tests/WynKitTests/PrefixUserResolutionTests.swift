import Foundation
import Testing
@testable import WynKit

/// The bottle holds a Wine user directory per Wine version — `ebenoelofse`
/// from wine 11.0 and `crossover` from winecx 11.15 — each with a complete set
/// of Solarpunk saves, configs and logs. Which one a launch writes is decided
/// at runtime by the tree it runs on, and nothing resolved it: `wyn play
/// solarpunk` tailed users/ebenoelofse and printed *yesterday's* lines during
/// a launch, while `wyn play solarpunk-dxmt` happened to tail the right one.
///
/// Picking by name would just be a different guess. Picking by time cannot be
/// wrong: a log older than the wyn process doing the launching was written by
/// something else.
@Suite("Prefix user resolution")
struct PrefixUserResolutionTests {

    @Test func aLogFromBeforeThisProcessIsNotThisSession() {
        let start = Date()
        let yesterday = start.addingTimeInterval(-86_400)
        #expect(!LaunchDiagnostics.isFromThisSession(mtime: yesterday, processStart: start))
    }

    @Test func aLogWrittenAfterTheLaunchStartedIsThisSession() {
        let start = Date()
        #expect(LaunchDiagnostics.isFromThisSession(
            mtime: start.addingTimeInterval(5), processStart: start
        ))
    }

    /// A log that does not exist is not evidence of anything.
    @Test func aMissingModificationTimeIsNotThisSession() {
        #expect(!LaunchDiagnostics.isFromThisSession(mtime: nil, processStart: Date()))
    }

    /// The boundary belongs to this session — a log stamped at the same instant
    /// the process started is the launch's own first write, not a leftover.
    @Test func theExactStartInstantCounts() {
        let start = Date()
        #expect(LaunchDiagnostics.isFromThisSession(mtime: start, processStart: start))
    }

    /// A perf report has to name the user directory it read, or a report from
    /// the other user reads exactly like the run that just finished.
    @Test func aPerfReportNamesTheUserDirectoryItRead() {
        let log = URL(fileURLWithPath:
            "/b/drive_c/users/crossover/AppData/Local/Solarpunk/Saved/Logs/Solarpunk.log")
        let line = SessionPerformance.logProvenance(of: log)
        #expect(line.contains("users/crossover"))
        #expect(line.contains("Solarpunk.log"))
    }

    @Test func provenanceSurvivesAPathWithNoUsersComponent() {
        let line = SessionPerformance.logProvenance(of: URL(fileURLWithPath: "/tmp/Solarpunk.log"))
        #expect(line.contains("users/?"))
    }
}
