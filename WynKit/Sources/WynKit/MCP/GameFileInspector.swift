//
//  GameFileInspector.swift
//  WynKit
//
//  What the game's own files say about it.
//
//  This is the difference between an assistant that recalls and one that looks.
//  Asking a model "what settings does Solarpunk need?" is recall, which is where
//  models are weakest and where 72 profiles with MetalFX turned on came from.
//  Handing it "this directory contains Engine/Binaries/Win64, a
//  FactoryGame-Win64-Shipping.exe, and ships vulkan-1.dll but no d3d12.dll" is
//  observation, which is where they are strong — and it is checkable.
//
//  Everything here is a directory walk. No PE parsing, no heuristics dressed up
//  as facts: signatures with names attached, or "unknown". A wrong guess
//  reported confidently is the failure this whole line of work is about.
//

import Foundation

public struct GameFileReport: Codable, Sendable, Equatable {
    public struct Executable: Codable, Sendable, Equatable {
        public let name: String
        /// Path relative to the install directory.
        public let path: String
        public let bytes: Int
        /// Set when the name matches a known shipping-build convention.
        public let looksLikeMainExecutable: Bool
    }

    public let installDirectory: String
    /// Engine as identified by files on disk, or "unknown".
    public let engine: String
    /// Why `engine` says what it says — the file or directory that decided it.
    public let engineEvidence: [String]
    public let executables: [Executable]
    /// Graphics and platform DLLs the game ships. These say a lot: vulkan-1
    /// without d3d12 means a Vulkan renderer, and D3DMetal does not translate
    /// Vulkan at all.
    public let shippedLibraries: [String]
    public let notes: [String]
}

public enum GameFileInspector {

    /// Filenames that identify an engine. First match wins, so the specific
    /// ones come first.
    static let engineSignatures: [(needle: String, engine: String)] = [
        ("unityplayer.dll", "Unity"),
        ("re_chunk_000.pak", "RE Engine"),
        ("gameassembly.dll", "Unity (IL2CPP)"),
        ("hl2.exe", "Source")
    ]

    /// Libraries whose presence changes what a profile should say.
    static let interestingLibraries: Set<String> = [
        "vulkan-1.dll", "d3d12.dll", "d3d11.dll", "dxgi.dll", "dxil.dll",
        "unityplayer.dll", "gameassembly.dll", "steam_api64.dll", "steam_api.dll",
        "amd_ags_x64.dll", "nvngx.dll", "nvngx_dlss.dll", "openvr_api.dll",
        "eossdk-win64-shipping.dll", "galaxy64.dll"
    ]

    /// Directories never worth walking into.
    static let skippedDirectories: Set<String> = [
        "_commonredist", "redist", "directx", "vcredist", "shadercache",
        "savedata", "saves", "logs", "crashes"
    ]

    static let maxDepth = 3
    static let maxEntries = 4000

    public static func inspect(installDirectory url: URL) -> GameFileReport {
        let fm = FileManager.default
        var executables: [GameFileReport.Executable] = []
        var libraries: Set<String> = []
        var engine = "unknown"
        var evidence: [String] = []
        var notes: [String] = []
        var seen = 0

        let root = url.path(percentEncoded: false)

        func note(_ found: String, _ name: String) {
            guard engine == "unknown" else { return }
            engine = found
            evidence.append(name)
        }

        func walk(_ directory: URL, depth: Int) {
            guard depth <= maxDepth, seen < maxEntries else { return }
            guard let entries = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            for entry in entries {
                seen += 1
                if seen > maxEntries { return }
                let name = entry.lastPathComponent
                let lower = name.lowercased()
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

                if isDirectory {
                    // Unreal and Unity announce themselves with a directory.
                    if lower == "engine" { note("Unreal Engine", "\(relative(entry, to: root))/") }
                    if lower.hasSuffix("_data") { note("Unity", "\(relative(entry, to: root))/") }
                    guard !skippedDirectories.contains(lower) else { continue }
                    walk(entry, depth: depth + 1)
                    continue
                }

                if lower.hasSuffix(".exe") {
                    let size = (try? entry.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    executables.append(
                        GameFileReport.Executable(
                            name: name,
                            path: relative(entry, to: root),
                            bytes: size,
                            looksLikeMainExecutable: isLikelyMainExecutable(lower)
                        )
                    )
                    if lower.contains("-win64-shipping") { note("Unreal Engine", name) }
                }

                if lower.hasSuffix(".dll"), interestingLibraries.contains(lower) {
                    libraries.insert(lower)
                }
                if lower.hasSuffix(".pck") { note("Godot", name) }
                for signature in engineSignatures where lower == signature.needle {
                    note(signature.engine, name)
                }
            }
        }

        walk(url, depth: 0)

        if seen >= maxEntries {
            notes.append("Directory is large; the scan stopped after \(maxEntries) entries.")
        }
        if libraries.contains("vulkan-1.dll"), !libraries.contains("d3d12.dll") {
            notes.append(
                "Ships vulkan-1.dll and no d3d12.dll — this looks like a Vulkan "
                + "renderer. D3DMetal does not translate Vulkan; that is the "
                + "MoltenVK path (see doom-eternal, enshrouded)."
            )
        }
        if libraries.contains("eossdk-win64-shipping.dll") {
            notes.append("Ships the Epic Online Services SDK; -NO_EOS_OVERLAY may be needed.")
        }
        if executables.isEmpty {
            notes.append("No .exe found — wrong directory, or the game is not fully installed.")
        }

        return GameFileReport(
            installDirectory: root,
            engine: engine,
            engineEvidence: evidence,
            executables: executables.sorted {
                if $0.looksLikeMainExecutable != $1.looksLikeMainExecutable {
                    return $0.looksLikeMainExecutable
                }
                return $0.bytes > $1.bytes
            },
            shippedLibraries: libraries.sorted(),
            notes: notes
        )
    }

    /// Names that are conventionally the thing you launch. A ranking hint, not
    /// a determination — `exePatterns` still has to be chosen deliberately, and
    /// the uninstaller trap is the reminder why: FactoryGameSteam.exe matches a
    /// naive "steam.exe" pattern.
    static func isLikelyMainExecutable(_ lowercasedName: String) -> Bool {
        if lowercasedName.contains("-win64-shipping") { return true }
        let noise = [
            "unins", "crashreport", "crashpad", "launcher", "setup", "redist",
            "vcredist", "dxsetup", "activation", "touchup", "server", "editor",
            "benchmark", "config", "helper"
        ]
        return !noise.contains { lowercasedName.contains($0) }
    }

    static func relative(_ url: URL, to root: String) -> String {
        let path = url.path(percentEncoded: false)
        guard path.hasPrefix(root) else { return url.lastPathComponent }
        return String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
