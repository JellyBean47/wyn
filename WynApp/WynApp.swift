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

import SwiftUI
import WynKit

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
