import Foundation
import Testing
@testable import WynKit

/// The app used to show every failure as `error.localizedDescription` in a
/// dialog titled "Wyn", which answers neither question a stuck person has:
/// what was it trying to do, and what should I do now.
@Suite("Failure messages")
struct FailureTests {

    private struct KnownError: LocalizedError {
        var errorDescription: String? { "Steam did not unpack its login interface." }
        var recoverySuggestion: String? { "Check your connection and try again." }
    }

    private struct SilentError: LocalizedError {
        var errorDescription: String? { "Something specific went wrong." }
        var recoverySuggestion: String? { nil }
    }

    // MARK: - The step

    /// The busy overlay says "Opening Steam…"; a title wants "Opening Steam".
    @Test func stepLosesItsTrailingEllipsis() {
        let failure = Failure(step: "Opening Steam…", reason: "x")
        #expect(failure.step == "Opening Steam")
        #expect(failure.title == "Opening Steam didn't work")
    }

    @Test func stepLosesTrailingPunctuationAndPadding() {
        #expect(Failure(step: "  Installing Steam.  ", reason: "x").step == "Installing Steam")
        #expect(Failure(step: "Launching Satisfactory….", reason: "x").step == "Launching Satisfactory")
    }

    /// Never title a dialog " didn't work".
    @Test func emptyStepFallsBackToSomethingReadable() {
        #expect(Failure(step: "   ", reason: "x").title == "That didn't work")
        #expect(Failure(step: "…", reason: "x").title == "That didn't work")
    }

    // MARK: - Reason and hint

    @Test func localizedErrorSuppliesBothReasonAndHint() {
        let failure = Failure(step: "Opening Steam…", error: KnownError())
        #expect(failure.reason == "Steam did not unpack its login interface.")
        #expect(failure.hint == "Check your connection and try again.")
    }

    @Test func aLocalizedErrorWithNoSuggestionGetsNoHint() {
        let failure = Failure(step: "Opening Steam", error: SilentError())
        #expect(failure.reason == "Something specific went wrong.")
        #expect(failure.hint == nil)
    }

    /// Foundation's fallback — "The operation couldn't be completed.
    /// (NSPOSIXErrorDomain error 2.)" — is what most non-LocalizedError throws
    /// produce, and it tells a person nothing. Say so honestly, and keep the
    /// domain and code, which are worth something in a bug report.
    @Test func uselessSystemTextIsReplacedButTheCodeIsKept() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: 2)
        let failure = Failure(step: "Stopping the bottle", error: error)
        #expect(!failure.reason.contains("operation couldn"))
        #expect(failure.reason.contains(NSPOSIXErrorDomain))
        #expect(failure.reason.contains("2"))
    }

    /// A system error that *does* explain itself must be left alone.
    @Test func aRealSystemMessageIsKept() {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "The file “steam.exe” doesn’t exist."]
        )
        #expect(Failure(step: "Opening Steam", error: error).reason
                == "The file “steam.exe” doesn’t exist.")
    }

    // MARK: - What the bundle gets

    /// The diagnostics zip should arrive carrying the failure it was exported
    /// for, not contextless.
    @Test func noteLineCarriesStepAndReason() {
        let failure = Failure(step: "Launching Satisfactory…", error: KnownError())
        #expect(failure.noteLine == "Launching Satisfactory — Steam did not unpack its login interface.")
    }

    // MARK: - Every SteamError tells you what to do

    /// `errorDescription` on SteamError is written for the CLI and names `wyn`
    /// subcommands — right there, useless in the app. Every case must also
    /// offer a suggestion that assumes no terminal. This is the test that
    /// fails when a new case is added without one.
    @Test func everySteamErrorHasARecoverySuggestion() {
        let all: [SteamError] = [
            .downloadFailed,
            .steamNotInstalled,
            .steamSetupFailed,
            .steamWineMissing,
            .steamNotLoggedOn,
            .steamDidNotExit,
            .steamAlreadyRunningElsewhere,
            .cefDidNotAppear,
            .gameNotInstalled(appId: 526870),
            .missingSteamAppId(profileId: "satisfactory"),
            .d3dMetalRequiresDirectLaunch,
            .previousSessionStillRunning(summary: "FactoryGameSteam.exe")
        ]
        for error in all {
            let hint = error.recoverySuggestion
            #expect(hint != nil, "\(error) has no recovery suggestion")
            #expect(!(hint ?? "").isEmpty)
            // The app shows this to someone with no prompt in front of them.
            #expect(!(hint ?? "").contains("wyn "), "\(error) suggests a shell command")
        }
    }

    /// And the pairing must survive the trip through Failure.
    @Test func aSteamErrorArrivesWithStepReasonAndHint() {
        let failure = Failure(step: "Opening Steam…", error: SteamError.steamNotLoggedOn)
        #expect(failure.title == "Opening Steam didn't work")
        #expect(failure.reason.contains("Logged On"))
        #expect(failure.hint == "Open Steam, sign in with Remember me, then try again.")
    }
}
