//
//  WynApp.swift
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
import SwiftUI
import WynKit

/// The About panel's contents.
///
/// GPL-3 §6 is answered by the download page carrying the source link beside
/// the binary, but someone who was handed the DMG directly never sees that
/// page. The app has to be able to say what it is on its own.
private enum About {
    static let sourceURL = URL(string: "https://github.com/JellyBean47/wyn")!

    static func show() {
        let body = """
        Wyn runs Windows games on macOS through Wine and a Direct3D→Metal layer.

        Copyright (C) 2024–2026 Wyn contributors
        Copyright (C) 2023 Isaac Marovitz and Whisky contributors

        Free software under GPL-3.0-or-later, with NO WARRANTY, to the extent \
        permitted by law. Wyn ships no Apple Game Porting Toolkit, no Wine, and \
        no games; those are fetched or supplied by you. Full notices are in \
        Legal/ on the disk image.

        Source, and the corresponding source for this build:
        """

        let credits = NSMutableAttributedString(
            string: body + "\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        credits.append(
            NSAttributedString(
                string: sourceURL.absoluteString,
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .link: sourceURL,
                ]
            )
        )

        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

@main
struct WynApp: App {
    @StateObject private var vm = LibraryVM()

    var body: some Scene {
        WindowGroup {
            LibraryView(vm: vm)
                .frame(minWidth: 760, minHeight: 520)
                .onAppear {
                    NSWindow.allowsAutomaticWindowTabbing = false
                }
        }
        .defaultSize(width: 960, height: 640)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("About Wyn") {
                    About.show()
                }
            }
            CommandGroup(replacing: .help) {
                Button("Wyn Source Code (GPL-3.0)") {
                    NSWorkspace.shared.open(About.sourceURL)
                }
            }
            CommandGroup(after: .importExport) {
                Button("Refresh Library") {
                    vm.refresh()
                }
                .keyboardShortcut("R", modifiers: [.command])
                Divider()
                Button("Open Logs") {
                    vm.openLogs()
                }
                .keyboardShortcut("L", modifiers: [.command])
                Button("Open C: Drive") {
                    vm.openCDrive()
                }
                Button("Export Diagnostics…") {
                    vm.exportDiagnostics()
                }
                .keyboardShortcut("D", modifiers: [.command, .shift])
                Button("Kill Bottle") {
                    vm.killBottle()
                }
                .keyboardShortcut("K", modifiers: [.command, .shift])
            }
        }
    }
}
