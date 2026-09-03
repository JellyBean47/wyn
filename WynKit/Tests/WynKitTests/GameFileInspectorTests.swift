import Foundation
import Testing
@testable import WynKit

/// Reading the game's own files instead of recalling facts about the game.
///
/// Checked against the real Satisfactory install, 3 Sep 2026:
///
///     engine:    Unreal Engine   (evidence: Engine/)
///     libraries: eossdk-win64-shipping.dll
///     notes:     Ships the Epic Online Services SDK; -NO_EOS_OVERLAY may be needed.
///     exes:      main=true    270,336  Engine/Binaries/Win64/FactoryGameSteam-Win64-Shipping.exe
///                main=true    217,112  FactoryGameSteam.exe
///                main=false 27,841,024  Engine/Binaries/Win64/CrashReportClient.exe
///
/// Two things worth noticing there. `CrashReportClient.exe` is a hundred times
/// larger than the game, so "pick the biggest executable" chooses exactly the
/// wrong one. And the EOS SDK on disk implies `-NO_EOS_OVERLAY`, which is the
/// first flag in the hand-tuned launch args that took weeks to arrive at —
/// derived here from a directory listing.
@Suite("Game file inspection")
struct GameFileInspectorTests {

    /// A throwaway install tree. Under `$HOME`, never `/tmp`.
    private func makeTree(_ build: (URL) throws -> Void) throws -> URL {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: "Library/Caches/com.wyn.gaming/InspectorTests")
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try build(root)
        return root
    }

    private func write(_ url: URL, bytes: Int = 1024) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(count: bytes).write(to: url)
    }

    // MARK: - Engines

    @Test func unrealIsFoundByItsEngineDirectory() throws {
        let root = try makeTree { root in
            try write(root.appending(path: "Engine/Binaries/Win64/Game-Win64-Shipping.exe"))
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let report = GameFileInspector.inspect(installDirectory: root)
        #expect(report.engine == "Unreal Engine")
        #expect(!report.engineEvidence.isEmpty)
    }

    @Test func unityIsFoundByItsDataDirectory() throws {
        let root = try makeTree { root in
            try write(root.appending(path: "MyGame_Data/level0"))
            try write(root.appending(path: "MyGame.exe"))
        }
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(GameFileInspector.inspect(installDirectory: root).engine == "Unity")
    }

    @Test func godotIsFoundByItsPack() throws {
        let root = try makeTree { root in
            try write(root.appending(path: "game.pck"))
            try write(root.appending(path: "game.exe"))
        }
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(GameFileInspector.inspect(installDirectory: root).engine == "Godot")
    }

    /// No signature means no answer. A confident wrong guess is the failure
    /// this whole line of work is about.
    @Test func anUnknownEngineSaysUnknown() throws {
        let root = try makeTree { root in try write(root.appending(path: "mystery.exe")) }
        defer { try? FileManager.default.removeItem(at: root) }

        let report = GameFileInspector.inspect(installDirectory: root)
        #expect(report.engine == "unknown")
        #expect(report.engineEvidence.isEmpty)
    }

    // MARK: - Choosing the executable

    /// The Satisfactory shape: the crash reporter dwarfs the game.
    @Test func theCrashReporterIsNotTheGame() throws {
        let root = try makeTree { root in
            try write(root.appending(path: "Engine/Binaries/Win64/CrashReportClient.exe"),
                      bytes: 27_841_024)
            try write(root.appending(path: "Engine/Binaries/Win64/FactoryGameSteam-Win64-Shipping.exe"),
                      bytes: 270_336)
            try write(root.appending(path: "FactoryGameSteam.exe"), bytes: 217_112)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let report = GameFileInspector.inspect(installDirectory: root)
        #expect(report.engine == "Unreal Engine")

        let first = report.executables.first
        #expect(first?.name == "FactoryGameSteam-Win64-Shipping.exe")
        #expect(first?.looksLikeMainExecutable == true)

        let reporter = report.executables.first { $0.name == "CrashReportClient.exe" }
        #expect(reporter?.looksLikeMainExecutable == false,
                "the biggest binary here is the one you must not launch")
    }

    @Test func installersAndHelpersAreNotTheGame() {
        for name in [
            "unins000.exe", "vcredist_x64.exe", "dxsetup.exe", "launcher.exe",
            "crashpad_handler.exe", "game_server.exe", "editor.exe"
        ] {
            #expect(!GameFileInspector.isLikelyMainExecutable(name), "\(name) is not the game")
        }
        for name in ["factorygamesteam.exe", "eldenring.exe", "game-win64-shipping.exe"] {
            #expect(GameFileInspector.isLikelyMainExecutable(name), "\(name) is the game")
        }
    }

    // MARK: - What the shipped libraries imply

    /// Vulkan with no D3D12 is the doom-eternal / enshrouded shape, and
    /// D3DMetal cannot translate Vulkan at all — worth saying out loud before
    /// somebody writes a d3dmetal profile for it.
    @Test func aVulkanRendererIsCalledOut() throws {
        let root = try makeTree { root in
            try write(root.appending(path: "game.exe"))
            try write(root.appending(path: "vulkan-1.dll"))
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let report = GameFileInspector.inspect(installDirectory: root)
        #expect(report.shippedLibraries.contains("vulkan-1.dll"))
        #expect(report.notes.contains { $0.contains("Vulkan") })
    }

    @Test func shippingD3D12MeansItIsNotVulkanOnly() throws {
        let root = try makeTree { root in
            try write(root.appending(path: "game.exe"))
            try write(root.appending(path: "vulkan-1.dll"))
            try write(root.appending(path: "d3d12.dll"))
        }
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!GameFileInspector.inspect(installDirectory: root).notes
            .contains { $0.contains("looks like a Vulkan renderer") })
    }

    @Test func theEpicSDKImpliesTheOverlayFlag() throws {
        let root = try makeTree { root in
            try write(root.appending(path: "game.exe"))
            try write(root.appending(path: "EOSSDK-Win64-Shipping.dll"))
        }
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(GameFileInspector.inspect(installDirectory: root).notes
            .contains { $0.contains("NO_EOS_OVERLAY") })
    }

    // MARK: - Edges

    @Test func anEmptyDirectorySaysSo() throws {
        let root = try makeTree { _ in }
        defer { try? FileManager.default.removeItem(at: root) }

        let report = GameFileInspector.inspect(installDirectory: root)
        #expect(report.executables.isEmpty)
        #expect(report.notes.contains { $0.contains("No .exe") })
    }

    @Test func aMissingDirectoryDoesNotThrow() {
        let report = GameFileInspector.inspect(
            installDirectory: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")
        )
        #expect(report.executables.isEmpty)
        #expect(report.engine == "unknown")
    }

    /// Redist folders are full of installers nobody wants ranked.
    @Test func redistributableFoldersAreSkipped() throws {
        let root = try makeTree { root in
            try write(root.appending(path: "game.exe"))
            try write(root.appending(path: "_CommonRedist/vcredist/2019/vc_redist.x64.exe"))
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let names = GameFileInspector.inspect(installDirectory: root).executables.map(\.name)
        #expect(names == ["game.exe"])
    }
}
