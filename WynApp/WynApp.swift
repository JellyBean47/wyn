//
//  WynApp.swift
//  Wyn
//
//  This file is part of Wyn.
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
                Button("Kill Bottle") {
                    vm.killBottle()
                }
                .keyboardShortcut("K", modifiers: [.command, .shift])
            }
        }
    }
}
