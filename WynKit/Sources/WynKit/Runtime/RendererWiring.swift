//
//  RendererWiring.swift
//  WynKit
//
//  Shared Libraries/ unix d3d*.so pointers. Selecting a backend repoints these
//  entries; it never overwrites or deletes the other payload. GPTK install is
//  availability only — it must not call set().
//

import Foundation

/// Global Direct3D unix-module wiring in `Libraries/Wine/lib/wine/x86_64-unix/`.
///
/// This is the actual loader state. Bottle `translationLayer` is declared
/// intent; when they disagree, `LaunchDiagnostics.effectiveLayer` reports the
/// wired backend and tells the user to `wyn renderer set`.
public enum RendererWiring {
    /// Unix modules that switch between D3DMetal (`libd3dshared`) and Wine/DXMT.
    /// D3DMetal does not provide `d3d9.so`; DXVK may, via `Context.dxvkD3D9`.
    public static let d3dEntries = ["d3d11.so", "d3d10.so", "dxgi.so", "d3d12.so"]

    public static let d3dMetalRelativeTarget = "../../external/libd3dshared.dylib"

    /// Same suffix `GPTKInstaller` uses when overlaying PE/unix modules.
    public static let backupExtension = "fly-pre-gptk"

    public enum Backend: Equatable, Sendable {
        /// `d3d11.so` (and siblings) → `libd3dshared`.
        case d3dMetal
        /// Wine/DXMT/DXVK unix modules — not `libd3dshared`.
        case wineNative
        /// Entries disagree with each other.
        case mixed
        /// Unix dir or the d3d* entries are missing.
        case missing
    }

    public struct Entry: Equatable, Sendable {
        public let name: String
        public let destination: String?
        public let isD3DMetal: Bool
        public let exists: Bool

        public var summary: String {
            if let destination {
                return "\(name) -> \(destination)"
            }
            if exists {
                return "\(name) (regular file, not libd3dshared)"
            }
            return "\(name) MISSING"
        }
    }

    public struct Snapshot: Equatable, Sendable {
        public let unixDirectory: URL
        public let backend: Backend
        public let entries: [Entry]

        public var d3d11Summary: String {
            entries.first(where: { $0.name == "d3d11.so" })?.summary ?? "d3d11.so MISSING"
        }

        public var statusLines: [String] {
            let label: String
            switch backend {
            case .d3dMetal: label = "D3DMetal (libd3dshared)"
            case .wineNative: label = "Wine/DXMT (not libd3dshared)"
            case .mixed: label = "MIXED — d3d*.so disagree"
            case .missing: label = "missing unix d3d*.so"
            }
            var lines = ["wired: \(label)"]
            lines.append(contentsOf: entries.map(\.summary))
            return lines
        }
    }

    public struct Context: Sendable {
        public var unixDirectory: URL
        public var gptkInstalled: Bool
        public var d3dMetalTarget: String
        /// If DXVK ships a unix `d3d9.so`, point `d3d9.so` at this relative target when selecting DXVK.
        public var dxvkD3D9RelativeTarget: String?

        public init(
            unixDirectory: URL,
            gptkInstalled: Bool,
            d3dMetalTarget: String = RendererWiring.d3dMetalRelativeTarget,
            dxvkD3D9RelativeTarget: String? = nil
        ) {
            self.unixDirectory = unixDirectory
            self.gptkInstalled = gptkInstalled
            self.d3dMetalTarget = d3dMetalTarget
            self.dxvkD3D9RelativeTarget = dxvkD3D9RelativeTarget
        }

        public static var live: Context {
            Context(
                unixDirectory: GPTKInstaller.wineLibFolder
                    .appending(path: "wine")
                    .appending(path: "x86_64-unix"),
                gptkInstalled: GPTKInstaller.isInstalled(),
                dxvkD3D9RelativeTarget: liveDXVKD3D9RelativeTarget()
            )
        }
    }

    public enum WiringError: LocalizedError, Equatable {
        case gptkMissing
        case unixDirectoryMissing(String)
        case backupMissing(String)
        case verifyFailed(String)

        public var errorDescription: String? {
            switch self {
            case .gptkMissing:
                return """
                GPTK/D3DMetal is not installed. Download Game Porting Toolkit 3.0 from Apple \
                into ~/Downloads, then:
                  wyn gptk install
                Then: wyn renderer set d3dmetal
                """
            case .unixDirectoryMissing(let path):
                return "Wine unix module directory missing: \(path). Run: wyn install"
            case .backupMissing(let name):
                return """
                Cannot select DXMT/DXVK: no pre-GPTK backup of \(name). \
                Reinstall the FOSS winecx game-host, then: wyn renderer set dxmt
                """
            case .verifyFailed(let detail):
                return "Renderer switch failed verification: \(detail)"
            }
        }
    }

    public static func inspect(context: Context = .live) -> Snapshot {
        let fm = FileManager.default
        let unixDir = context.unixDirectory
        var names = d3dEntries
        if context.dxvkD3D9RelativeTarget != nil {
            names.append("d3d9.so")
        } else if existsOrLink(unixDir.appending(path: "d3d9.so"), fm: fm) {
            names.append("d3d9.so")
        }

        var entries: [Entry] = []
        for name in names {
            let url = unixDir.appending(path: name)
            let dest = symlinkDestination(of: url, fm: fm)
            let exists = existsOrLink(url, fm: fm)
            let isD3DMetal = dest.map { isD3DMetalTarget($0) } ?? false
            entries.append(Entry(name: name, destination: dest, isD3DMetal: isD3DMetal, exists: exists))
        }

        let scoped = entries.filter { d3dEntries.contains($0.name) }
        let backend = classify(scoped)
        return Snapshot(unixDirectory: unixDir, backend: backend, entries: entries)
    }

    /// Repoint unix `d3d*.so` at the requested backend, then re-read and fail if they do not match.
    public static func set(_ layer: TranslationLayer, context: Context = .live) throws {
        let fm = FileManager.default
        let unixDir = context.unixDirectory
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: unixDir.path(percentEncoded: false), isDirectory: &isDir),
              isDir.boolValue
        else {
            throw WiringError.unixDirectoryMissing(unixDir.path(percentEncoded: false))
        }

        switch layer {
        case .d3dMetal:
            guard context.gptkInstalled else { throw WiringError.gptkMissing }
            for name in d3dEntries {
                try pointAtD3DMetal(name: name, context: context, fm: fm)
            }
        case .dxmt, .dxvk:
            for name in d3dEntries {
                try restoreWineNative(name: name, context: context, fm: fm)
            }
            if layer == .dxvk, let d3d9 = context.dxvkD3D9RelativeTarget {
                try pointAt(name: "d3d9.so", relativeTarget: d3d9, context: context, fm: fm)
            }
        }

        try verify(layer, context: context)
    }

    public static func verify(_ layer: TranslationLayer, context: Context = .live) throws {
        let snapshot = inspect(context: context)
        let scoped = snapshot.entries.filter { d3dEntries.contains($0.name) }

        switch layer {
        case .d3dMetal:
            for entry in scoped {
                guard entry.isD3DMetal else {
                    throw WiringError.verifyFailed(
                        "\(entry.summary) (want \(context.d3dMetalTarget))"
                    )
                }
            }
        case .dxmt, .dxvk:
            for entry in scoped {
                if entry.isD3DMetal {
                    throw WiringError.verifyFailed(
                        "\(entry.summary) still points at libd3dshared (D3DMetal)"
                    )
                }
                guard entry.exists else {
                    throw WiringError.verifyFailed("\(entry.name) missing after restore")
                }
            }
            if layer == .dxvk, let want = context.dxvkD3D9RelativeTarget {
                let d3d9 = snapshot.entries.first(where: { $0.name == "d3d9.so" })
                guard let d3d9, d3d9.destination == want else {
                    throw WiringError.verifyFailed(
                        "d3d9.so -> \(d3d9?.destination ?? "MISSING") (want \(want))"
                    )
                }
            }
        }
    }

    public static func mismatchReason(
        declared: TranslationLayer,
        snapshot: Snapshot
    ) -> String? {
        switch (declared, snapshot.backend) {
        case (.dxmt, .d3dMetal), (.dxvk, .d3dMetal):
            return """
            translationLayer=\(declared.rawValue) but Libraries \(snapshot.d3d11Summary) \
            (D3DMetal); run: wyn renderer set \(declared.rawValue)
            """
        case (.d3dMetal, .wineNative), (.d3dMetal, .missing):
            return """
            translationLayer=d3dmetal but Libraries \(snapshot.d3d11Summary); \
            run: wyn renderer set d3dmetal
            """
        case (.d3dMetal, .mixed), (.dxmt, .mixed), (.dxvk, .mixed):
            let detail = snapshot.entries.map(\.summary).joined(separator: "; ")
            return """
            translationLayer=\(declared.rawValue) but Libraries d3d*.so disagree (\(detail)); \
            run: wyn renderer set \(declared.rawValue)
            """
        default:
            return nil
        }
    }

    // MARK: - Private

    private static func classify(_ entries: [Entry]) -> Backend {
        guard !entries.isEmpty, entries.contains(where: \.exists) else { return .missing }
        let present = entries.filter(\.exists)
        guard !present.isEmpty else { return .missing }
        let metal = present.filter(\.isD3DMetal)
        if metal.count == present.count { return .d3dMetal }
        if metal.isEmpty { return .wineNative }
        return .mixed
    }

    private static func pointAtD3DMetal(name: String, context: Context, fm: FileManager) throws {
        try pointAt(name: name, relativeTarget: context.d3dMetalTarget, context: context, fm: fm)
    }

    private static func pointAt(name: String, relativeTarget: String, context: Context, fm: FileManager) throws {
        let url = context.unixDirectory.appending(path: name)
        if let dest = symlinkDestination(of: url, fm: fm), dest == relativeTarget {
            return
        }
        try backupIfNeeded(at: url, fm: fm)
        if existsOrLink(url, fm: fm) {
            try fm.removeItem(at: url)
        }
        try fm.createSymbolicLink(
            atPath: url.path(percentEncoded: false),
            withDestinationPath: relativeTarget
        )
    }

    private static func restoreWineNative(name: String, context: Context, fm: FileManager) throws {
        let url = context.unixDirectory.appending(path: name)
        if let dest = symlinkDestination(of: url, fm: fm), isD3DMetalTarget(dest) {
            let backup = url.appendingPathExtension(backupExtension)
            guard existsOrLink(backup, fm: fm) else {
                throw WiringError.backupMissing(name)
            }
            try fm.removeItem(at: url)
            try fm.copyItem(at: backup, to: url)
            return
        }
        guard existsOrLink(url, fm: fm) else {
            let backup = url.appendingPathExtension(backupExtension)
            guard existsOrLink(backup, fm: fm) else {
                throw WiringError.backupMissing(name)
            }
            try fm.copyItem(at: backup, to: url)
            return
        }
    }

    private static func backupIfNeeded(at url: URL, fm: FileManager) throws {
        guard existsOrLink(url, fm: fm) else { return }
        if let dest = symlinkDestination(of: url, fm: fm), isD3DMetalTarget(dest) {
            return
        }
        let backup = url.appendingPathExtension(backupExtension)
        if existsOrLink(backup, fm: fm) { return }
        var isLink = false
        let path = url.path(percentEncoded: false)
        if let attrs = try? fm.attributesOfItem(atPath: path),
           let type = attrs[.type] as? FileAttributeType {
            isLink = type == .typeSymbolicLink
        }
        // Do not snapshot a D3DMetal pointer as the wine-native backup.
        if isLink, let dest = symlinkDestination(of: url, fm: fm), isD3DMetalTarget(dest) {
            return
        }
        try fm.copyItem(at: url, to: backup)
    }

    private static func isD3DMetalTarget(_ destination: String) -> Bool {
        URL(fileURLWithPath: destination).lastPathComponent == "libd3dshared.dylib"
    }

    private static func symlinkDestination(of url: URL, fm: FileManager) -> String? {
        try? fm.destinationOfSymbolicLink(atPath: url.path(percentEncoded: false))
    }

    private static func existsOrLink(_ url: URL, fm: FileManager) -> Bool {
        let path = url.path(percentEncoded: false)
        if fm.fileExists(atPath: path) { return true }
        return (try? fm.destinationOfSymbolicLink(atPath: path)) != nil
    }

    /// DXVK-macOS is PE-only; a unix `d3d9.so` is used only if the payload actually ships one.
    private static func liveDXVKD3D9RelativeTarget() -> String? {
        let roots = [
            WynWineInstaller.libraryFolder.appending(path: "DXVK"),
            WynWineInstaller.steamLibraryFolder.appending(path: "DXVK")
        ]
        let fm = FileManager.default
        for root in roots {
            let candidate = root.appending(path: "d3d9.so")
            if fm.fileExists(atPath: candidate.path(percentEncoded: false)) {
                return candidate.path(percentEncoded: false)
            }
        }
        return nil
    }
}
