//
//  UnrealCompatibility.swift
//  WynKit
//

import Foundation

/// Helpers for Unreal Engine titles that default to D3D12 (unavailable under DXMT).
public enum UnrealCompatibility {
    /// True when profile launch args request D3D11 (`-dx11` / `-d3d11`).
    public static func wantsDX11(launchArgs: [String]) -> Bool {
        launchArgs.contains { arg in
            let lower = arg.lowercased()
            return lower == "-dx11" || lower == "-d3d11"
        }
    }

    /// Force D3D11 into Saved Engine.ini (no perf-killing RHI bypass pins).
    ///
    /// Target: `drive_c/users/<user>/AppData/Local/<project>/Saved/Config/Windows/Engine.ini`
    ///
    /// Note: do **not** write `r.RHIThread.Enable` — UE 5.6+ registers that name as a
    /// different console-object type, and a SystemSettings bool fatal-errors on boot.
    /// Do **not** leave `r.RHICmdBypass=1` on DXVK — it serializes the RHI and tanks FPS.
    @discardableResult
    public static func pinDX11(in bottle: Bottle, projectName: String) throws -> [URL] {
        try mutateConfigIni(in: bottle, projectName: projectName, fileName: "Engine.ini") { url in
            try upsertKey(
                in: url,
                section: "[/Script/WindowsTargetPlatform.WindowsTargetSettings]",
                key: "DefaultGraphicsRHI",
                value: "DefaultGraphicsRHI_DX11"
            )
            // Strip legacy pins that crash UE 5.6 or destroy DXVK performance.
            try removeKey(in: url, section: "[SystemSettings]", key: "r.RHIThread.Enable")
            try removeKey(in: url, section: "[SystemSettings]", key: "r.RHICmdBypass")
            try upsertKey(in: url, section: "[SystemSettings]", key: "r.GPUStats", value: "0")
        }
    }

    /// Cap resolution / FPS and pull Unreal scalability to Low for translated GPUs.
    ///
    /// Writes `GameUserSettings.ini` under the same Saved/Config/Windows tree.
    /// Intended for DXVK/MoltenVK titles where Epic defaults are unplayable.
    @discardableResult
    public static func pinLowScalability(
        in bottle: Bottle,
        projectName: String,
        width: Int = 1280,
        height: Int = 720,
        frameRateLimit: Double = 40
    ) throws -> [URL] {
        try mutateConfigIni(in: bottle, projectName: projectName, fileName: "GameUserSettings.ini") { url in
            let userSection = "[/Script/\(projectName).FGGameUserSettings]"
            // FactoryGame uses FGGameUserSettings; fall back to generic if absent.
            let section: String
            if (try? String(contentsOf: url, encoding: .utf8))?.contains(userSection) == true {
                section = userSection
            } else if (try? String(contentsOf: url, encoding: .utf8))?
                .contains("[/Script/Engine.GameUserSettings]") == true {
                section = "[/Script/Engine.GameUserSettings]"
            } else {
                section = userSection
            }

            try upsertKey(in: url, section: section, key: "ResolutionSizeX", value: "\(width)")
            try upsertKey(in: url, section: section, key: "ResolutionSizeY", value: "\(height)")
            try upsertKey(in: url, section: section, key: "LastUserConfirmedResolutionSizeX", value: "\(width)")
            try upsertKey(in: url, section: section, key: "LastUserConfirmedResolutionSizeY", value: "\(height)")
            try upsertKey(in: url, section: section, key: "FrameRateLimit", value: String(format: "%.6f", frameRateLimit))
            try upsertKey(in: url, section: section, key: "bUseVSync", value: "False")
            try upsertKey(in: url, section: section, key: "bUseDynamicResolution", value: "False")
            // Borderless windowed — slightly cheaper than exclusive FS under Wine.
            try upsertKey(in: url, section: section, key: "FullscreenMode", value: "1")
            try upsertKey(in: url, section: section, key: "PreferredFullscreenMode", value: "1")

            let low = "0"
            let tex = "1" // slightly above Low — 0 can look broken / thrash streaming
            try upsertKey(in: url, section: "[ScalabilityGroups]", key: "sg.ResolutionQuality", value: "50")
            try upsertKey(in: url, section: "[ScalabilityGroups]", key: "sg.ViewDistanceQuality", value: low)
            try upsertKey(in: url, section: "[ScalabilityGroups]", key: "sg.AntiAliasingQuality", value: low)
            try upsertKey(in: url, section: "[ScalabilityGroups]", key: "sg.ShadowQuality", value: low)
            try upsertKey(in: url, section: "[ScalabilityGroups]", key: "sg.GlobalIlluminationQuality", value: low)
            try upsertKey(in: url, section: "[ScalabilityGroups]", key: "sg.ReflectionQuality", value: low)
            try upsertKey(in: url, section: "[ScalabilityGroups]", key: "sg.PostProcessQuality", value: low)
            try upsertKey(in: url, section: "[ScalabilityGroups]", key: "sg.TextureQuality", value: tex)
            try upsertKey(in: url, section: "[ScalabilityGroups]", key: "sg.EffectsQuality", value: low)
            try upsertKey(in: url, section: "[ScalabilityGroups]", key: "sg.FoliageQuality", value: low)
            try upsertKey(in: url, section: "[ScalabilityGroups]", key: "sg.ShadingQuality", value: low)
            try upsertKey(in: url, section: "[ScalabilityGroups]", key: "sg.LandscapeQuality", value: low)
        }
    }

    /// Enable Unreal hitch detection logging so flat→spike frame pacing shows up in FactoryGame.log.
    /// Threshold 33.3 ms ≈ below 30 FPS; anything slower is logged as a hitch.
    @discardableResult
    public static func pinHitchLogging(in bottle: Bottle, projectName: String) throws -> [URL] {
        try mutateConfigIni(in: bottle, projectName: projectName, fileName: "Engine.ini") { url in
            try upsertKey(
                in: url,
                section: "[ConsoleVariables]",
                key: "t.HitchFrameTimeThreshold",
                value: "33.3"
            )
            try upsertKey(
                in: url,
                section: "[ConsoleVariables]",
                key: "t.DumpHitches",
                value: "1"
            )
            // Keep GPU stats off by default (noise); perf profile can override via ExecCmds.
            try upsertKey(in: url, section: "[Core.Log]", key: "LogHitchDetection", value: "Verbose")
        }
    }

    // MARK: - Private

    private static func mutateConfigIni(
        in bottle: Bottle,
        projectName: String,
        fileName: String,
        _ body: (URL) throws -> Void
    ) throws -> [URL] {
        let trimmed = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let usersRoot = bottle.url.appending(path: "drive_c").appending(path: "users")
        guard FileManager.default.fileExists(atPath: usersRoot.path(percentEncoded: false)) else {
            return []
        }

        let skipped: Set<String> = ["Public", "Default", "Default User", "All Users"]
        let users = (try? FileManager.default.contentsOfDirectory(
            at: usersRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var written: [URL] = []
        for userDir in users {
            let name = userDir.lastPathComponent
            guard !skipped.contains(name) else { continue }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: userDir.path(percentEncoded: false), isDirectory: &isDir
            ), isDir.boolValue else { continue }

            let configDir = userDir
                .appending(path: "AppData")
                .appending(path: "Local")
                .appending(path: trimmed)
                .appending(path: "Saved")
                .appending(path: "Config")
                .appending(path: "Windows")

            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            let ini = configDir.appending(path: fileName)
            try body(ini)
            written.append(ini)
        }
        return written
    }

    private static func mutateEngineIni(
        in bottle: Bottle,
        projectName: String,
        _ body: (URL) throws -> Void
    ) throws -> [URL] {
        try mutateConfigIni(in: bottle, projectName: projectName, fileName: "Engine.ini", body)
    }

    /// The file's dominant line ending. UE writes these inis CRLF inside a Wine
    /// prefix; splicing bare "\n" into one leaves mixed endings behind.
    static func lineEnding(of contents: String) -> String {
        contents.contains("\r\n") ? "\r\n" : "\n"
    }

    static func upsertKey(
        in file: URL, section: String, key: String, value: String
    ) throws {
        var contents = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let original = contents
        let eol = lineEnding(of: contents)

        // Repair "[Section]Key=" smashes written by earlier versions of this file.
        contents = contents.replacingOccurrences(
            of: "\(section)\(key)=",
            with: "\(section)\(eol)\(key)="
        )

        if let updated = replaceKey(in: contents, section: section, key: key, value: value) {
            if updated != original {
                try updated.write(to: file, atomically: true, encoding: .utf8)
            }
            return
        }

        // Section absent: append it. Trim only trailing line breaks — the old
        // code trimmed all whitespace, which ate the last line's own ending and
        // converted it to the separator's.
        var body = contents
        while body.hasSuffix("\n") || body.hasSuffix("\r") { body.removeLast() }
        if !body.isEmpty { body += eol + eol }
        body += "; Written by Wyn\(eol)\(section)\(eol)\(key)=\(value)\(eol)"
        try body.write(to: file, atomically: true, encoding: .utf8)
    }

    static func removeKey(in file: URL, section: String, key: String) throws {
        guard var contents = try? String(contentsOf: file, encoding: .utf8), !contents.isEmpty else {
            return
        }
        contents = contents.replacingOccurrences(
            of: "\(section)\(key)=",
            with: "\(section)\(lineEnding(of: contents))\(key)="
        )
        guard let sectionRange = contents.range(of: section) else { return }

        let afterSection = contents[sectionRange.upperBound...]
        let nextSection = afterSection.range(of: "\n[")?.lowerBound ?? afterSection.endIndex
        let sectionBody = String(afterSection[..<nextSection])

        // `[ \t]` not `\s`: \s matches newlines, so `^\s*KEY=` reaches back over the
        // line break before the key and deletes it too, merging this line into
        // the one above — the same defect that produced "[Section]Key=value".
        guard let regex = try? NSRegularExpression(
            pattern: "(?m)^[ \\t]*\(NSRegularExpression.escapedPattern(for: key))[ \\t]*=[^\\r\\n]*\\r?\\n?"
        ) else { return }

        let full = NSRange(location: 0, length: (sectionBody as NSString).length)
        let newBody = regex.stringByReplacingMatches(in: sectionBody, range: full, withTemplate: "")
        guard newBody != sectionBody else { return }

        var result = contents
        result.replaceSubrange(sectionRange.upperBound..<nextSection, with: newBody)
        try result.write(to: file, atomically: true, encoding: .utf8)
    }

    /// Replace `key=…` inside an existing UE ini section, or return nil if section is missing.
    static func replaceKey(
        in contents: String, section: String, key: String, value: String
    ) -> String? {
        guard let sectionRange = contents.range(of: section) else { return nil }
        let eol = lineEnding(of: contents)

        let afterSection = contents[sectionRange.upperBound...]
        let nextSection = afterSection.range(of: "\n[")?.lowerBound ?? afterSection.endIndex
        var sectionBody = String(afterSection[..<nextSection])
        // Always keep a line break between the section header and the first key.
        // CRLF files start this run with "\r\n", which the old "\n"-only check
        // missed — it then prepended a bare "\n", leaving mixed endings.
        if !sectionBody.hasPrefix("\n") && !sectionBody.hasPrefix("\r\n") {
            sectionBody = eol + sectionBody
        }

        // Two deliberate details:
        //  * `[ \t]` not `\s` — \s matches newlines, so `^\s*KEY` matched the line
        //    break before the key and the replacement was spliced onto the
        //    section header. That is how "[SystemSettings]r.GPUStats=0" and
        //    "[/Script/…WindowsTargetSettings]DefaultGraphicsRHI=…" were written,
        //    and why the "]Key=" repair above could never win: this regex
        //    re-smashed the line on the very next pass.
        //  * `[^\r\n]*` not `.*$` — `.` matches \r, so `.*$` swallowed the CR and
        //    silently converted that one line to LF inside a CRLF file.
        guard let regex = try? NSRegularExpression(
            pattern: "(?m)^[ \\t]*\(NSRegularExpression.escapedPattern(for: key))[ \\t]*=[^\\r\\n]*"
        ) else { return nil }

        let full = NSRange(location: 0, length: (sectionBody as NSString).length)
        let replacement = "\(key)=\(value)"

        let newBody: String
        if regex.firstMatch(in: sectionBody, range: full) != nil {
            newBody = regex.stringByReplacingMatches(
                in: sectionBody, range: full, withTemplate: replacement
            )
        } else {
            var inserted = sectionBody
            if !inserted.hasSuffix("\n") { inserted += eol }
            inserted += "\(replacement)\(eol)"
            newBody = inserted
        }

        var result = contents
        result.replaceSubrange(sectionRange.upperBound..<nextSection, with: newBody)
        return result
    }
}
