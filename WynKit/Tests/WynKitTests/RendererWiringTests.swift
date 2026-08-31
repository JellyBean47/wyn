import Foundation
import Testing
@testable import WynKit

@Suite("RendererWiring")
struct RendererWiringTests {
    private func scratchUnixDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "wyn-renderer-wiring-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func seedWineNative(at unixDir: URL, payload: Data = Data("wine-d3d11".utf8)) throws {
        for name in RendererWiring.d3dEntries {
            try payload.write(to: unixDir.appending(path: name))
        }
    }

    private func context(unixDir: URL, gptk: Bool, d3d9: String? = nil) -> RendererWiring.Context {
        RendererWiring.Context(
            unixDirectory: unixDir,
            gptkInstalled: gptk,
            dxvkD3D9RelativeTarget: d3d9
        )
    }

    @Test func inspectWineNative() throws {
        let unixDir = try scratchUnixDir()
        defer { try? FileManager.default.removeItem(at: unixDir) }
        try seedWineNative(at: unixDir)
        let snapshot = RendererWiring.inspect(context: context(unixDir: unixDir, gptk: false))
        #expect(snapshot.backend == .wineNative)
        #expect(snapshot.entries.filter { RendererWiring.d3dEntries.contains($0.name) }.allSatisfy { !$0.isD3DMetal && $0.exists })
    }

    @Test func setD3DMetalThenRestoreDXMT() throws {
        let unixDir = try scratchUnixDir()
        defer { try? FileManager.default.removeItem(at: unixDir) }
        let original = Data("wine-module-bytes".utf8)
        try seedWineNative(at: unixDir, payload: original)
        let ctx = context(unixDir: unixDir, gptk: true)

        try RendererWiring.set(.d3dMetal, context: ctx)
        let metal = RendererWiring.inspect(context: ctx)
        #expect(metal.backend == .d3dMetal)
        for entry in metal.entries where RendererWiring.d3dEntries.contains(entry.name) {
            #expect(entry.destination == RendererWiring.d3dMetalRelativeTarget)
        }

        try RendererWiring.set(.dxmt, context: ctx)
        let restored = RendererWiring.inspect(context: ctx)
        #expect(restored.backend == .wineNative)
        for name in RendererWiring.d3dEntries {
            let data = try Data(contentsOf: unixDir.appending(path: name))
            #expect(data == original)
            let backup = unixDir.appending(path: name).appendingPathExtension(RendererWiring.backupExtension)
            #expect(FileManager.default.fileExists(atPath: backup.path(percentEncoded: false)))
        }
    }

    @Test func setD3DMetalIsIdempotent() throws {
        let unixDir = try scratchUnixDir()
        defer { try? FileManager.default.removeItem(at: unixDir) }
        try seedWineNative(at: unixDir)
        let ctx = context(unixDir: unixDir, gptk: true)
        try RendererWiring.set(.d3dMetal, context: ctx)
        try RendererWiring.set(.d3dMetal, context: ctx)
        #expect(RendererWiring.inspect(context: ctx).backend == .d3dMetal)
    }

    @Test func setD3DMetalWithoutGPTKFails() throws {
        let unixDir = try scratchUnixDir()
        defer { try? FileManager.default.removeItem(at: unixDir) }
        try seedWineNative(at: unixDir)
        #expect(throws: RendererWiring.WiringError.gptkMissing) {
            try RendererWiring.set(.d3dMetal, context: context(unixDir: unixDir, gptk: false))
        }
    }

    @Test func restoreWithoutBackupFailsLoudly() throws {
        let unixDir = try scratchUnixDir()
        defer { try? FileManager.default.removeItem(at: unixDir) }
        let fm = FileManager.default
        for name in RendererWiring.d3dEntries {
            try fm.createSymbolicLink(
                atPath: unixDir.appending(path: name).path(percentEncoded: false),
                withDestinationPath: RendererWiring.d3dMetalRelativeTarget
            )
        }
        let ctx = context(unixDir: unixDir, gptk: true)
        #expect(throws: RendererWiring.WiringError.backupMissing("d3d11.so")) {
            try RendererWiring.set(.dxmt, context: ctx)
        }
    }

    @Test func verifyFailsIfTargetWrong() throws {
        let unixDir = try scratchUnixDir()
        defer { try? FileManager.default.removeItem(at: unixDir) }
        try seedWineNative(at: unixDir)
        let ctx = context(unixDir: unixDir, gptk: true)
        try RendererWiring.set(.d3dMetal, context: ctx)
        let d3d11 = unixDir.appending(path: "d3d11.so")
        try FileManager.default.removeItem(at: d3d11)
        try FileManager.default.createSymbolicLink(
            atPath: d3d11.path(percentEncoded: false),
            withDestinationPath: "../../wined3d.so"
        )
        #expect(throws: RendererWiring.WiringError.self) {
            try RendererWiring.verify(.d3dMetal, context: ctx)
        }
    }

    @Test func setDXVKPointsOptionalD3D9() throws {
        let unixDir = try scratchUnixDir()
        defer { try? FileManager.default.removeItem(at: unixDir) }
        try seedWineNative(at: unixDir)
        let ctx = context(unixDir: unixDir, gptk: true, d3d9: "../DXVK/d3d9.so")
        try RendererWiring.set(.d3dMetal, context: ctx)
        try RendererWiring.set(.dxvk, context: ctx)
        let snapshot = RendererWiring.inspect(context: ctx)
        #expect(snapshot.backend == .wineNative)
        #expect(snapshot.entries.first(where: { $0.name == "d3d9.so" })?.destination == "../DXVK/d3d9.so")
    }

    @Test func effectiveLayerFilesystemWins() throws {
        let unixDir = try scratchUnixDir()
        defer { try? FileManager.default.removeItem(at: unixDir) }
        try seedWineNative(at: unixDir)
        let ctx = context(unixDir: unixDir, gptk: true)
        try RendererWiring.set(.d3dMetal, context: ctx)
        let snapshot = RendererWiring.inspect(context: ctx)

        let dxmtWiredMetal = LaunchDiagnostics.resolveEffectiveLayer(
            declared: .dxmt, snapshot: snapshot, gptkInstalled: true
        )
        #expect(dxmtWiredMetal.layer == .d3dMetal)
        #expect(dxmtWiredMetal.reason.contains("translationLayer=dxmt but Libraries"))
        #expect(dxmtWiredMetal.reason.contains("wyn renderer set dxmt"))

        let metalWiredMetal = LaunchDiagnostics.resolveEffectiveLayer(
            declared: .d3dMetal, snapshot: snapshot, gptkInstalled: true
        )
        #expect(metalWiredMetal.layer == .d3dMetal)
        #expect(metalWiredMetal.reason == "translationLayer=d3dmetal")

        try RendererWiring.set(.dxmt, context: ctx)
        let wine = RendererWiring.inspect(context: ctx)
        let metalWiredWine = LaunchDiagnostics.resolveEffectiveLayer(
            declared: .d3dMetal, snapshot: wine, gptkInstalled: true
        )
        #expect(metalWiredWine.layer == .dxmt)
        #expect(metalWiredWine.reason.contains("wyn renderer set d3dmetal"))

        let metalNoGPTK = LaunchDiagnostics.resolveEffectiveLayer(
            declared: .d3dMetal, snapshot: wine, gptkInstalled: false
        )
        #expect(metalNoGPTK.layer == .d3dMetal)
        #expect(metalNoGPTK.reason == "translationLayer=d3dmetal")
    }
}
