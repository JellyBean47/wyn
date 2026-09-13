//
//  CommandLineTool.swift
//  Wyn
//
//  This file is part of Wyn.
//
//  Wyn is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Wyn is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Wyn.
//  If not, see https://www.gnu.org/licenses/.
//

import AppKit
import Foundation

/// Puts the bundled `wyn` on PATH.
///
/// A source install gets the CLI from `scripts/build.sh`, which copies it to
/// `~/.local/bin` on every build. Someone who dragged Wyn.app out of the disk
/// image has neither, so the copy in `Contents/Resources` is the only one they
/// have — and `wyn profiles`, `wyn doctor` and the MCP server are otherwise
/// unreachable for them.
enum CommandLineTool {
    static let binDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".local/bin")

    /// The copy inside this bundle, if this build carries one. A build made
    /// before the CLI was bundled will not, and the menu item says so rather
    /// than failing when pressed.
    static var bundled: URL? {
        Bundle.main.url(forResource: "wyn", withExtension: nil)
    }

    static func install() {
        guard let source = bundled else {
            report(
                title: "This build does not carry the command line tool",
                body: "Install from source to get `wyn`:\n  ./install.sh",
                style: .warning
            )
            return
        }

        let fm = FileManager.default
        let destination = binDirectory.appending(path: "wyn")
        let alias = binDirectory.appending(path: "fly")

        do {
            try fm.createDirectory(at: binDirectory, withIntermediateDirectories: true)

            // Unlink rather than overwrite: replacing a binary that is running
            // fails with "Text file busy", and an MCP server started by an
            // editor is exactly that. The running process keeps the old inode
            // and the next start picks this one up.
            for path in [destination, alias] where fm.fileExists(atPath: path.path) {
                try fm.removeItem(at: path)
            }

            try fm.copyItem(at: source, to: destination)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            try fm.createSymbolicLink(at: alias, withDestinationURL: destination)
        } catch {
            report(
                title: "Could not install the command line tool",
                body: "\(binDirectory.path)\n\n\(error.localizedDescription)",
                style: .critical
            )
            return
        }

        let onPath = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .contains { $0 == binDirectory.path }

        var body = "Installed to \(destination.path), and linked as `fly`."
        if !onPath {
            body += """


            \(binDirectory.path) is not on your PATH. Add this to ~/.zshrc:
              export PATH="$HOME/.local/bin:$PATH"
            """
        }
        report(title: "Command line tool installed", body: body, style: .informational)
    }

    private static func report(title: String, body: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = style
        alert.runModal()
    }
}
