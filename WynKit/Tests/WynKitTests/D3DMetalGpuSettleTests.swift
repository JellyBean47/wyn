import Foundation
import Testing
@testable import WynKit

@Suite("D3DMetalGpuSettle")
struct D3DMetalGpuSettleTests {
    @Test func coldStartDoesNotWait() {
        let remaining = D3DMetalGpuSettle.remaining(
            processJustExitedAt: nil,
            rememberedExitAt: nil,
            unrealLogMtime: nil
        )
        #expect(remaining == 0)
    }

    @Test func recentExitWaitsFullWindow() {
        let now = Date()
        let remaining = D3DMetalGpuSettle.remaining(
            now: now,
            processJustExitedAt: now,
            rememberedExitAt: nil,
            unrealLogMtime: nil
        )
        #expect(abs(remaining - 120) < 0.01)
    }

    @Test func thirtyOneSecondsStillInsideWindow() {
        // 29 Aug 18:07: 31s after canary SIGILL'd because a 30s gate skipped.
        let now = Date()
        let last = now.addingTimeInterval(-31)
        let remaining = D3DMetalGpuSettle.remaining(
            now: now,
            processJustExitedAt: last,
            rememberedExitAt: nil,
            unrealLogMtime: nil
        )
        #expect(abs(remaining - 89) < 0.01)
    }

    @Test func hundredThreeSecondsIsIdle() {
        let now = Date()
        let last = now.addingTimeInterval(-103)
        let remaining = D3DMetalGpuSettle.remaining(
            now: now,
            processJustExitedAt: last,
            rememberedExitAt: nil,
            unrealLogMtime: nil
        )
        #expect(abs(remaining - 17) < 0.01)
    }

    @Test func pastWindowIsZero() {
        let now = Date()
        let last = now.addingTimeInterval(-200)
        let remaining = D3DMetalGpuSettle.remaining(
            now: now,
            processJustExitedAt: last,
            rememberedExitAt: nil,
            unrealLogMtime: nil
        )
        #expect(remaining == 0)
    }

    @Test func newestEvidenceWins() {
        let now = Date()
        let remaining = D3DMetalGpuSettle.remaining(
            now: now,
            processJustExitedAt: now.addingTimeInterval(-200),
            rememberedExitAt: now.addingTimeInterval(-10),
            unrealLogMtime: now.addingTimeInterval(-50)
        )
        #expect(abs(remaining - 110) < 0.01)
    }

    @Test func windowsExeBasenameSkipsSteamWebHelperPathNoise() {
        let steam = SteamLauncher.windowsExeBasename(
            fromCommand: #"C:\Program Files (x86)\Steam\steam.exe -no-cef-sandbox"#
        )
        #expect(steam == "steam.exe")
        let helper = SteamLauncher.windowsExeBasename(
            fromCommand: #"C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper_real.exe --type=crashpad-handler"#
        )
        #expect(helper == "steamwebhelper_real.exe")
        let game = SteamLauncher.windowsExeBasename(
            fromCommand: #"C:\Program Files (x86)\Steam\steamapps\common\Satisfactory\FactoryGameSteam.exe -dx11"#
        )
        #expect(game == "factorygamesteam.exe")
    }
}
