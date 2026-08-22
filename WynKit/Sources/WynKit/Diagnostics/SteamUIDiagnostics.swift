//
//  SteamUIDiagnostics.swift
//  WynKit
//
//  Snapshot Steam login / CEF / window state during `wyn play --debug`.
//

import CoreGraphics
import Foundation

public enum SteamUIDiagnostics {
    /// Print a concise `[fly:steam-ui]` block so we can see *why* the login window
    /// is missing (off-screen, CEF GPU dead, wrong d3d11, DXVK fail, not logged in, …).
    public static func printSnapshot(bottle: Bottle, label: String) {
        var lines: [String] = []
        lines.append("════════════════════════════════════════════════════════════")
        lines.append("FLY STEAM UI SNAPSHOT — \(label)")
        lines.append("════════════════════════════════════════════════════════════")

        lines.append(contentsOf: processLines())
        lines.append(contentsOf: windowLines())
        lines.append(contentsOf: loginLines(bottle: bottle))
        lines.append(contentsOf: cefLines(bottle: bottle))
        lines.append(contentsOf: dllLines(bottle: bottle))
        lines.append(contentsOf: appDefaultsLines(bottle: bottle))
        lines.append(contentsOf: recentLogHints())
        lines.append(contentsOf: displayLines())
        lines.append("════════════════════════════════════════════════════════════")

        for line in lines {
            print("[fly:steam-ui] \(line)")
        }
        fflush(stdout)
    }

    /// Background sampler used while Wine Steam is starting (`--debug` only).
    public static func startSampling(bottle: Bottle, delaysSeconds: [Int] = [5, 12, 25]) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            var elapsed = 0
            for delay in delaysSeconds {
                let wait = delay - elapsed
                guard wait > 0 else { continue }
                try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
                if Task.isCancelled { return }
                elapsed = delay
                await MainActor.run {
                    printSnapshot(bottle: bottle, label: "t+\(delay)s")
                }
            }
        }
    }

    // MARK: - Sections

    private static func processLines() -> [String] {
        var out = ["── Processes ──"]
        let patterns = ["steam.exe", "steamwebhelper", "FactoryGame", "wineserver", "winedbg"]
        var found = false
        for pattern in patterns {
            let matches = pgrep(pattern)
            if matches.isEmpty { continue }
            found = true
            for line in matches.prefix(4) {
                out.append("  ✅ \(line)")
            }
        }
        if !found {
            out.append("  ❌ no steam/wine/game processes matched")
        }
        return out
    }

    private static func windowLines() -> [String] {
        var out = ["── Wine / Steam windows ──"]
        let opts = CGWindowListOption(arrayLiteral: .optionAll)
        guard let wins = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            out.append("  ❌ CGWindowListCopyWindowInfo failed")
            return out
        }

        var interesting: [(onscreen: Bool, w: Int, h: Int, x: Int, y: Int, owner: String, title: String)] = []
        for w in wins {
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            let ownerL = owner.lowercased()
            guard ownerL.contains("wine") || ownerL.contains("steam") else { continue }
            let bounds = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
            let width = Int(bounds["Width"] ?? 0)
            let height = Int(bounds["Height"] ?? 0)
            if width * height < 8_000 { continue } // skip menu-bar strips
            let onscreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false
            let title = w[kCGWindowName as String] as? String ?? ""
            interesting.append((
                onscreen,
                width,
                height,
                Int(bounds["X"] ?? 0),
                Int(bounds["Y"] ?? 0),
                owner,
                title
            ))
        }

        if interesting.isEmpty {
            out.append("  ❌ no Wine/Steam windows ≥ ~90×90 (login UI not created or already gone)")
            out.append("     tip: dock icon alone usually means CEF GPU died or window never mapped")
            return out
        }

        for w in interesting.sorted(by: { $0.w * $0.h > $1.w * $1.h }).prefix(8) {
            let flag = w.onscreen ? "ONSCREEN " : "offscreen"
            let whereHint: String
            if w.x < -100 {
                whereHint = " ← left display / negative X"
            } else if !w.onscreen {
                whereHint = " ← not on active Space?"
            } else {
                whereHint = ""
            }
            let titleBit = w.title.isEmpty ? "" : " \"\(w.title)\""
            out.append(
                "  \(flag) \(w.w)x\(w.h) at (\(w.x),\(w.y)) \(w.owner)\(titleBit)\(whereHint)"
            )
        }

        let onscreenLoginish = interesting.contains {
            $0.onscreen && $0.w >= 400 && $0.h >= 300
        }
        if onscreenLoginish {
            out.append("  ✅ likely visible UI window present — look at main (or left) display")
        } else if interesting.contains(where: { $0.w >= 400 && $0.h >= 300 }) {
            out.append("  ⚠️ login-sized window exists but offscreen — check left monitor / Mission Control")
        }
        return out
    }

    private static func loginLines(bottle: Bottle) -> [String] {
        var out = ["── Steam login state ──"]
        let log = steamLogsDir(bottle: bottle).appending(path: "steamui_login.txt")
        guard let text = try? String(contentsOf: log, encoding: .utf8), !text.isEmpty else {
            out.append("  ❌ steamui_login.txt missing/empty")
            return out
        }
        let tail = text.split(whereSeparator: \.isNewline).suffix(8)
        for line in tail {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { continue }
            out.append("  \(s)")
        }
        let joined = text
        if joined.contains("SetLoginState: Success") {
            out.append("  note: a prior Success exists in this file — check timestamp of last lines")
        }
        if joined.contains("WaitingForCredentials") {
            out.append("  note: WaitingForCredentials ⇒ Steam wants the login UI (must be visible/interactive)")
        }
        return out
    }

    private static func cefLines(bottle: Bottle) -> [String] {
        var out = ["── CEF / GPU ──"]
        let cef = steamLogsDir(bottle: bottle).appending(path: "cef_log.txt")
        guard let text = try? String(contentsOf: cef, encoding: .utf8), !text.isEmpty else {
            out.append("  ❌ cef_log.txt missing/empty")
            return out
        }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        let crashes = lines.filter { $0.contains("GPU process exited unexpectedly") }
        let gpuDisabled = lines.filter {
            $0.localizedCaseInsensitiveContains("gpu compositing has been disabled")
                || $0.localizedCaseInsensitiveContains("software compositing")
        }
        out.append("  GPU process crash lines (file total): \(crashes.count)")
        for line in crashes.suffix(3) {
            out.append("    \(line.trimmingCharacters(in: .whitespaces))")
        }
        if let last = gpuDisabled.last {
            out.append("  \(last.trimmingCharacters(in: .whitespaces))")
        }
        if crashes.count >= 3 {
            out.append("  ⚠️ CEF gave up after ≥3 GPU crashes — expect blank/missing Steam UI")
        }
        return out
    }

    private static func dllLines(bottle: Bottle) -> [String] {
        var out = ["── Steam-local graphics DLLs ──"]
        let steamRoot = bottle.url
            .appending(path: "drive_c")
            .appending(path: "Program Files (x86)")
            .appending(path: "Steam")
        let cefDir = steamRoot
            .appending(path: "bin")
            .appending(path: "cef")
            .appending(path: "cef.win64")
        let system32 = bottle.url
            .appending(path: "drive_c")
            .appending(path: "windows")
            .appending(path: "system32")

        for (label, dir) in [("Steam/", steamRoot), ("CEF/", cefDir), ("system32/", system32)] {
            for name in ["d3d11.dll", "dxgi.dll", "wined3d.dll"] {
                let url = dir.appending(path: name)
                out.append("  \(label)\(name): \(classifyDLL(url))")
            }
        }
        return out
    }

    private static func appDefaultsLines(bottle: Bottle) -> [String] {
        var out = ["── AppDefaults (user.reg) ──"]
        let userReg = bottle.url.appending(path: "user.reg")
        guard let text = try? String(contentsOf: userReg, encoding: .utf8) else {
            out.append("  ❌ cannot read user.reg")
            return out
        }
        for exe in ["steam.exe", "steamwebhelper.exe", "factorygamesteam-win64-shipping.exe"] {
            let header = "[Software\\\\Wine\\\\AppDefaults\\\\\(exe)\\\\DllOverrides]"
            if let range = text.range(of: header) {
                let rest = text[range.lowerBound...]
                let end = rest.range(of: "\n[")?.lowerBound ?? rest.endIndex
                let section = String(rest[..<end])
                    .split(whereSeparator: \.isNewline)
                    .prefix(10)
                    .joined(separator: " | ")
                out.append("  \(exe): \(section)")
            } else {
                out.append("  \(exe): (no AppDefaults section)")
            }
        }
        return out
    }

    private static func recentLogHints() -> [String] {
        var out = ["── Latest Wyn log hints ──"]
        let logs = Wine.logsFolder
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: logs, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            out.append("  (no log dir)")
            return out
        }
        let latest = files
            .filter { $0.pathExtension == "log" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
                return da > db
            }
            .first
        guard let latest, let text = try? String(contentsOf: latest, encoding: .utf8) else {
            out.append("  (no log file)")
            return out
        }
        out.append("  file: \(latest.lastPathComponent)")
        let needles = [
            "Failed to initialize DXVK",
            "No adapters found",
            "geometryShader",
            "Failed to load libvulkan",
            "FreeType",
            "err:ole:create_server",
            "FactoryGame",
            "d3d11.dll",
            "WINEDLLOVERRIDES",
        ]
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        var hits = 0
        for line in lines.reversed() {
            guard needles.contains(where: { line.contains($0) }) else { continue }
            out.append("  · \(line.trimmingCharacters(in: .whitespaces))")
            hits += 1
            if hits >= 8 { break }
        }
        if hits == 0 {
            out.append("  (no matching DXVK/vulkan/d3d/login hints in latest log)")
        }
        return out
    }

    private static func displayLines() -> [String] {
        var out = ["── Displays ──"]
        // NSScreen needs AppKit; keep CoreGraphics-only via CGDisplay.
        let count = CGMainDisplayID()
        out.append("  main display id: \(count)")
        var displayCount: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        if CGGetActiveDisplayList(16, &displays, &displayCount) == .success {
            for i in 0 ..< Int(displayCount) {
                let id = displays[i]
                let bounds = CGDisplayBounds(id)
                let main = id == CGMainDisplayID() ? " main" : ""
                out.append(
                    "  display[\(i)]\(main): \(Int(bounds.width))x\(Int(bounds.height)) origin=(\(Int(bounds.origin.x)),\(Int(bounds.origin.y)))"
                )
            }
        }
        if displayCount > 1 {
            out.append("  tip: Wine often opens Steam on the left (negative X) display")
        }
        return out
    }

    // MARK: - Helpers

    private static func steamLogsDir(bottle: Bottle) -> URL {
        bottle.url
            .appending(path: "drive_c")
            .appending(path: "Program Files (x86)")
            .appending(path: "Steam")
            .appending(path: "logs")
    }

    private static func classifyDLL(_ url: URL) -> String {
        let fm = FileManager.default
        let path = url.path(percentEncoded: false)
        guard fm.fileExists(atPath: path),
              let attrs = try? fm.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber else {
            return "MISSING"
        }
        let bytes = size.intValue
        // Size alone confuses EricSpencer Wine d3d11 (~3.2MB) with DXVK; sniff strings.
        let kind: String
        if let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
           data.count > 64 {
            let ascii = String(decoding: data, as: UTF8.self)
            if ascii.contains("DXVK") || ascii.contains("Dxvk") {
                kind = "DXVK"
            } else if ascii.contains("__wine_unix_call") && bytes < 200_000 {
                kind = "GPTK-stub"
            } else if ascii.contains("wined3d.dll") || ascii.contains("wined3d") {
                kind = "Wine-wined3d"
            } else if bytes < 200_000 {
                kind = "likely-GPTK-stub/Wine-small"
            } else if bytes >= 3_800_000 {
                kind = "likely-DXVK/DXMT"
            } else {
                kind = "unknown-mid"
            }
        } else if bytes < 200_000 {
            kind = "likely-GPTK-stub/Wine-small"
        } else if bytes >= 3_800_000 {
            kind = "likely-DXVK/DXMT"
        } else {
            kind = "unknown"
        }
        return "\(bytes) bytes (\(kind))"
    }

    private static func pgrep(_ pattern: String) -> [String] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-lf", pattern]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return [] }
        return text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.contains("pgrep") && !$0.contains("Cursor") }
    }
}
