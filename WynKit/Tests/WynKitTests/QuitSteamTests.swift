import Foundation
import Testing
@testable import WynKit

/// `quitSteam` itself needs a live bottle, so what is tested here is the part
/// that decides whether Quit is even allowed to proceed: matching running
/// processes to library games.
///
/// Getting this wrong is quiet and bad in both directions — a false negative
/// force-quits Steam under someone mid-session, a false positive makes Quit
/// permanently refuse.
@Suite("Quit Steam — running game detection")
struct QuitSteamTests {

    private func profile(_ name: String, _ exes: [String]) -> GameProfile {
        GameProfile(id: name.lowercased(), name: name, exePatterns: exes)
    }

    // MARK: - Basename matching

    @Test func matchesGameExeInASteamPath() {
        let base = SteamLauncher.windowsExeBasename(
            fromCommand: #"C:\Program Files (x86)\Steam\steamapps\common\Satisfactory\FactoryGameSteam.exe -dx11"#
        )
        #expect(base == "factorygamesteam.exe")
    }

    /// Profiles are authored lowercase, but the match must not depend on it.
    @Test func matchingIsCaseInsensitiveOnBothSides() {
        let profiles = [profile("Satisfactory", ["FactoryGameSteam.EXE"])]
        var nameForExe: [String: String] = [:]
        for p in profiles {
            for pattern in p.exePatterns { nameForExe[pattern.lowercased()] = p.name }
        }
        let base = SteamLauncher.windowsExeBasename(
            fromCommand: #"C:\Games\FACTORYGAMESTEAM.EXE"#
        )
        #expect(base != nil)
        #expect(nameForExe[base!] == "Satisfactory")
    }

    // MARK: - What must never count as a running game

    /// A running Steam client is not a game. If it were, Quit would refuse to
    /// close the very thing it exists to close.
    @Test func steamClientIsNotAGame() {
        #expect(SteamLauncher.lineIsSteamClientExe(
            #"C:\Program Files (x86)\Steam\steam.exe -no-cef-sandbox"#
        ))
    }

    @Test func steamWebHelperIsNotAGame() {
        let command = #"C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper.exe --type=renderer"#
        #expect(command.lowercased().contains("steamwebhelper"))
        #expect(SteamLauncher.leftoverSessionCommands(matching: ["steamwebhelper.exe"]).isEmpty)
    }

    /// CrashReportClient can sit for hours after a session. Treating it as a
    /// live game would block Quit indefinitely.
    @Test func crashReportClientIsNotALiveGame() {
        #expect(!D3DMetalGpuSettle.leftoverIsLiveGame(
            basename: "crashreportclient.exe",
            gameExeNames: ["factorygamesteam.exe"]
        ))
    }

    @Test func theActualGameIsALiveGame() {
        #expect(D3DMetalGpuSettle.leftoverIsLiveGame(
            basename: "factorygamesteam.exe",
            gameExeNames: ["factorygamesteam.exe"]
        ))
    }

    // MARK: - Empty cases

    /// No profiles, or profiles with no exePatterns (Steam-library imports get
    /// `exePatterns: []`), must scan nothing rather than match everything.
    @Test func profilesWithoutExePatternsMatchNothing() {
        #expect(SteamLauncher.runningGameNames(among: []).isEmpty)
        #expect(SteamLauncher.runningGameNames(among: [profile("Imported", [])]).isEmpty)
    }

    @Test func emptyNameSetScansNothing() {
        #expect(SteamLauncher.leftoverSessionCommands(matching: []).isEmpty)
    }

    /// A name that cannot be running yields no false positive on a real `ps`.
    @Test func unrelatedGameIsNotReportedRunning() {
        let unlikely = "wyn-test-\(UUID().uuidString.prefix(8)).exe"
        #expect(SteamLauncher.runningGameNames(among: [profile("Ghost", [unlikely])]).isEmpty)
    }
}
