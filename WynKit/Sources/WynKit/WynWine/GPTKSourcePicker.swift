//  GPTKSourcePicker.swift
//  WynKit
//
//  Finder-backed source selection for `wyn gptk install`.
//
//  GPTK is user-supplied: Apple's DMG lands wherever the browser puts it. That
//  is usually ~/Downloads, which is why auto-detect looks there first — but it
//  is not a guarantee, and "not in ~/Downloads" used to be a dead end that told
//  the user to move their file. This lets them point at it instead.
//
//  Wyn still never downloads GPTK. This only chooses a path the user already has.
//

import Foundation

public enum GPTKSourcePicker {
    /// Folder the last successful install read GPTK from.
    private static let lastFolderKey = "WynGPTKLastSourceFolder"

    /// Preference store. Injectable so tests exercise the real read/write path
    /// without writing into the user's actual `com.fly.gaming` preferences.
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    /// Remembered folder, or `nil` if never set or since deleted (external drive
    /// unplugged, folder renamed). A stale pointer must never shadow ~/Downloads.
    public static var rememberedFolder: URL? {
        get {
            guard let raw = defaults.string(forKey: lastFolderKey),
                  !raw.isEmpty else { return nil }
            let url = URL(fileURLWithPath: raw)
            guard isDirectory(url) else { return nil }
            return url
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: lastFolderKey)
                return
            }
            defaults.set(newValue.path(percentEncoded: false), forKey: lastFolderKey)
        }
    }

    /// Record where a working source came from, so the next install checks there
    /// first and the picker opens there. A file remembers its parent folder; a
    /// directory redist remembers itself.
    public static func remember(source: URL) {
        guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false)) else { return }
        rememberedFolder = isDirectory(source) ? source : source.deletingLastPathComponent()
    }

    /// Forget the remembered folder (`wyn gptk install --forget-source`).
    public static func forget() {
        rememberedFolder = nil
    }

    /// A GPTK candidate in the remembered folder, if one is there.
    /// Skipped when the remembered folder *is* ~/Downloads — that is already
    /// searched, and scanning it twice would just reorder identical results.
    public static func rememberedCandidate() -> URL? {
        guard let folder = rememberedFolder else { return nil }
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")
        if folder.standardizedFileURL == downloads.standardizedFileURL { return nil }
        return GPTKInstaller.gptkCandidate(in: folder)
    }

    /// True when a Finder dialog makes sense: a terminal on both ends.
    ///
    /// CI, pipes, `wyn … < /dev/null` and scheduled runs must fail with the
    /// printable "put it in ~/Downloads or pass --from" error rather than block
    /// forever on a window nobody is there to answer.
    public static var isInteractive: Bool {
        isatty(FileHandle.standardInput.fileDescriptor) == 1
            && isatty(FileHandle.standardOutput.fileDescriptor) == 1
    }

    /// Where the picker should open. Remembered folder, else ~/Downloads, else home.
    public static func pickerStartFolder() -> URL {
        let fm = FileManager.default
        if let remembered = rememberedFolder { return remembered }
        let downloads = fm.homeDirectoryForCurrentUser.appending(path: "Downloads")
        if isDirectory(downloads) { return downloads }
        return fm.homeDirectoryForCurrentUser
    }

    /// Open Finder at `folder` and return what the user chose.
    ///
    /// Returns `nil` when the user cancels — cancelling is a normal outcome, not
    /// an error, and the caller reports the ordinary "not found" guidance.
    ///
    /// Uses `osascript` rather than `NSOpenPanel`: `wyn` is a plain CLI binary,
    /// not an app bundle, and AppKit panels from a non-bundled executable need an
    /// activation policy and can fail silently. `choose file` is a real Finder
    /// window and needs neither.
    public static func chooseSource(
        startingAt folder: URL? = nil,
        prompt: String = "Choose the Apple Game Porting Toolkit disk image or redist folder"
    ) -> URL? {
        let start = folder ?? pickerStartFolder()
        let script = """
        set theItem to choose file with prompt "\(escapeForAppleScript(prompt))" \
        default location POSIX file "\(escapeForAppleScript(start.path(percentEncoded: false)))" \
        without invisibles
        return POSIX path of theItem
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        _ = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // Non-zero is overwhelmingly "User canceled." (-128). Either way there is
        // no path to hand back.
        guard process.terminationStatus == 0 else { return nil }

        let path = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }

        let chosen = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: chosen.path(percentEncoded: false)) else { return nil }
        return chosen
    }

    // MARK: - Helpers

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: url.path(percentEncoded: false),
            isDirectory: &isDir
        )
        return exists && isDir.boolValue
    }

    /// AppleScript string literals take backslash and double-quote escapes.
    /// Folder names contain both often enough to matter.
    static func escapeForAppleScript(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
