import Foundation
import Testing
@testable import WynKit

@Suite("Windows runtimes")
struct WindowsRuntimesTests {

    /// Real text, copied from the live Steam bottle's system.reg. Wine doubles
    /// every backslash in a key and appends an epoch to the header, and getting
    /// either wrong silently reports every runtime missing — so the fixture is
    /// the actual bytes rather than a tidied-up version of them.
    private let installedHive = """
    WINE REGISTRY Version 2

    [Software\\\\Microsoft\\\\VisualStudio\\\\14.0\\\\VC\\\\Runtimes\\\\x64] 1788466788
    #time=1dd3be1916f599a
    "Bld"=dword:00008d97
    "Installed"=dword:00000001
    "Major"=dword:0000000e
    "Minor"=dword:00000033
    "Rbld"=dword:00000000
    "Version"="v14.51.36247.00"

    [Software\\\\Microsoft\\\\WBEM] 1788390254
    #time=1dd3b2f5f6f5966
    "Installation Directory"="C:\\\\windows\\\\system32\\\\wbem"

    """

    /// The same key, written but not installed — MSI leaves this behind on a
    /// failed or removed install, and treating "key exists" as "installed"
    /// would report it present.
    private let notInstalledHive = """
    WINE REGISTRY Version 2

    [Software\\\\Microsoft\\\\VisualStudio\\\\14.0\\\\VC\\\\Runtimes\\\\x64] 1788466788
    "Installed"=dword:00000000
    "Version"="v14.51.36247.00"

    """

    private func fixture(_ hive: String?, mono: Bool = false) throws -> URL {
        let dir = URL.temporaryDirectory.appending(path: "wyn-runtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let hive {
            try hive.write(to: dir.appending(path: "system.reg"), atomically: true, encoding: .utf8)
        }
        if mono {
            try FileManager.default.createDirectory(
                at: dir.appending(path: "drive_c/windows/mono"),
                withIntermediateDirectories: true
            )
        }
        return dir
    }

    // MARK: - Reading the hive

    @Test func aPresentRuntimeIsReportedWithItsVersion() throws {
        let prefix = try fixture(installedHive)
        let found = WindowsRuntimes.check(verbs: ["vcrun2022"], prefix: prefix)
        #expect(found.count == 1)
        #expect(found[0].result == .present("v14.51.36247.00"))
        #expect(found[0].summary.contains("v14.51.36247.00"))
    }

    /// The bug this whole file exists to prevent: the Solarpunk investigation
    /// spent an hour on a "Visual C++ Redistributable" dialog for a runtime
    /// that was installed. If a present runtime ever reads as missing, the
    /// check is worse than no check.
    @Test func aPresentRuntimeIsNeverReportedMissing() throws {
        let prefix = try fixture(installedHive)
        let missing = WindowsRuntimes.check(verbs: ["vcrun2019", "vcrun2022"], prefix: prefix)
            .filter(\.result.isMissing)
        #expect(missing.isEmpty)
    }

    @Test func anAbsentKeyIsMissing() throws {
        let prefix = try fixture("WINE REGISTRY Version 2\n\n")
        let found = WindowsRuntimes.check(verbs: ["vcrun2022"], prefix: prefix)
        #expect(found[0].result == .missing)
        #expect(found[0].summary.contains("MISSING"))
    }

    @Test func aKeyWithoutTheInstalledFlagIsMissing() throws {
        let prefix = try fixture(notInstalledHive)
        #expect(WindowsRuntimes.check(verbs: ["vcrun2022"], prefix: prefix)[0].result == .missing)
    }

    // MARK: - Honesty about what it cannot answer

    /// A bottle that has never been initialised has no registry. That is not
    /// the same as the runtime being absent, and saying "missing" would send
    /// someone to install something they already have.
    @Test func aBottleWithNoRegistryIsUnknownNotMissing() throws {
        let prefix = try fixture(nil)
        let found = WindowsRuntimes.check(verbs: ["vcrun2022"], prefix: prefix)
        #expect(!found[0].result.isMissing)
        if case .unknown(let why) = found[0].result {
            #expect(why.contains("registry"))
        } else {
            Issue.record("expected .unknown, got \(found[0].result)")
        }
    }

    /// The failure mode that made `winetricks` decorative in the first place
    /// was code quietly returning "fine" for something it never looked at.
    @Test func anUnrecognisedVerbIsUnknownNotSatisfied() throws {
        let prefix = try fixture(installedHive)
        let found = WindowsRuntimes.check(verbs: ["corefonts"], prefix: prefix)
        #expect(found[0].runtime == nil)
        #expect(!found[0].result.isMissing)
        if case .unknown(let why) = found[0].result {
            #expect(why.contains("corefonts"))
        } else {
            Issue.record("expected .unknown, got \(found[0].result)")
        }
    }

    /// Wine Mono answers for .NET and reports a version Microsoft never
    /// shipped. Claiming ".NET 4.8 installed" would be a fabrication.
    @Test func wineMonoIsNamedRatherThanPassedOffAsDotNet() throws {
        let hive = """
        WINE REGISTRY Version 2

        [Software\\\\Microsoft\\\\NET Framework Setup\\\\NDP\\\\v4\\\\Full] 1788390251
        "Install"=dword:00000001
        "Release"=dword:00082348
        "Version"="4.7.03190"

        """
        let prefix = try fixture(hive, mono: true)
        let found = WindowsRuntimes.check(verbs: ["dotnet48"], prefix: prefix)
        #expect(found[0].result == .present("4.7.03190, Wine Mono"))
    }

    // MARK: - Shape

    /// 79 profiles list vcrun2019 and vcrun2022 together. They are the same
    /// redistributable, and printing the identical line twice reads like two
    /// separate dependencies.
    @Test func verbsForTheSameRuntimeCollapseIntoOneLine() throws {
        let prefix = try fixture(installedHive)
        let found = WindowsRuntimes.check(verbs: ["vcrun2019", "vcrun2022"], prefix: prefix)
        #expect(found.count == 1)
        #expect(found[0].verbs == ["vcrun2019", "vcrun2022"])
        #expect(found[0].verb == "vcrun2019, vcrun2022")
    }

    @Test func unrecognisedVerbsDoNotCollapseIntoEachOther() throws {
        let prefix = try fixture(installedHive)
        let found = WindowsRuntimes.check(verbs: ["corefonts", "d3dx9"], prefix: prefix)
        #expect(found.count == 2)
        #expect(found.map(\.verbs) == [["corefonts"], ["d3dx9"]])
    }

    @Test func noVerbsMeansNothingToSay() throws {
        let prefix = try fixture(installedHive)
        #expect(WindowsRuntimes.check(verbs: [], prefix: prefix).isEmpty)
    }

    /// Every verb the shipped corpus actually uses must be one this file can
    /// answer for. If a profile starts declaring something new, the report
    /// should stop saying "not checked" and grow a probe instead.
    @Test func everyVerbInTheShippedCorpusIsRecognised() {
        let verbs = Set(ProfileStore.loadAll().flatMap(\.winetricks))
        #expect(!verbs.isEmpty, "no winetricks verbs found — the test would pass vacuously")
        for verb in verbs.sorted() {
            #expect(WindowsRuntime(winetricksVerb: verb) != nil,
                    "no probe for \"\(verb)\" — it would report as unchecked")
        }
    }
}

@Suite("Launch path")
struct LaunchPathTests {

    /// The rule that was implicit in SteamLauncher and invisible everywhere
    /// else. D3DMetal runs the executable itself; the other two hand the choice
    /// to Steam, which is how a prerequisite shim ends up running instead of
    /// the game.
    @Test func d3dMetalIsAlwaysDirectAndTheOthersGoThroughSteam() {
        #expect(LaunchPath.forLayer(.d3dMetal) == .directExecutable)
        #expect(LaunchPath.forLayer(.dxvk) == .steamApplaunch)
        #expect(LaunchPath.forLayer(.dxmt) == .steamApplaunch)
    }

    /// `--direct` is documented as "DXMT/DXVK only ... ignored for D3DMetal",
    /// and `launchGame` does not consult it on the D3DMetal path. If this
    /// diverges, the UI starts promising something the launcher will not do.
    @Test func directOnlyMovesTheLayersThatCanMove() {
        #expect(LaunchPath.forLayer(.d3dMetal, direct: true) == .directExecutable)
        #expect(LaunchPath.forLayer(.dxvk, direct: true) == .directExecutable)
        #expect(LaunchPath.forLayer(.dxmt, direct: true) == .directExecutable)
    }

    /// Only the Steam path can have a shim in it, so only it should mention one.
    @Test func theExplanationNamesTheThingThatBitUs() {
        #expect(LaunchPath.steamApplaunch.explanation.contains("prerequisite"))
        #expect(!LaunchPath.directExecutable.shortLabel.isEmpty)
        #expect(LaunchPath.directExecutable.shortLabel != LaunchPath.steamApplaunch.shortLabel)
    }

    /// Solarpunk is verified on d3dmetal, which is why its notes say the shim
    /// never appears. If the profile's layer changes, the note is wrong.
    @Test func solarpunkRunsDirectlyAsItsNotesClaim() throws {
        let profile = try #require(ProfileStore.profile(id: "solarpunk"))
        let layer = try #require(profile.bottle?.translationLayer)
        #expect(LaunchPath.forLayer(layer) == .directExecutable)
    }

    /// A game with no profile is `-applaunch` whatever the layer says, because
    /// `launchGame` short-circuits on empty `exePatterns` *before* it looks at
    /// the layer. `GameLibrary.installed` hands the app exactly this shape —
    /// a synthesised `steam-<appid>` profile — for every installed title Wyn
    /// has no profile for.
    ///
    /// Reporting the layer's answer for one of those is the mistake that cost
    /// an hour: a d3dmetal bottle would have claimed "runs the game directly"
    /// while Steam was in fact picking the executable, and picking a 230 KB
    /// prerequisite shim over the game.
    @Test func aGameWithNoExecutableIsNeverReportedAsDirect() throws {
        let unprofiled = GameProfile(
            id: "steam-1805110",
            name: "Solarpunk",
            steamAppId: 1805110,
            exePatterns: []
        )
        let bottle = Bottle(bottleUrl: URL.temporaryDirectory.appending(path: UUID().uuidString))
        bottle.settings.translationLayer = .d3dMetal

        #expect(LaunchPath.forLayer(.d3dMetal) == .directExecutable)
        #expect(LaunchPath.forProfile(unprofiled, in: bottle) == .noProfile)
        #expect(LaunchPath.noProfile.shortLabel.contains("no profile"))
        #expect(LaunchPath.noProfile.explanation.contains("prerequisite"))
    }

    /// The same profile with an executable does follow the layer.
    @Test func aProfileWithAnExecutableFollowsTheLayer() throws {
        let profiled = GameProfile(
            id: "solarpunk",
            name: "Solarpunk",
            steamAppId: 1805110,
            exePatterns: ["solarpunk-win64-shipping.exe"]
        )
        let bottle = Bottle(bottleUrl: URL.temporaryDirectory.appending(path: UUID().uuidString))
        bottle.settings.translationLayer = .d3dMetal
        #expect(LaunchPath.forProfile(profiled, in: bottle) == .directExecutable)

        bottle.settings.translationLayer = .dxmt
        #expect(LaunchPath.forProfile(profiled, in: bottle) == .steamApplaunch)
    }
}
