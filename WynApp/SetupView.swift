//
//  SetupView.swift
//  Wyn
//
//  This file is part of Wyn.
//

import SwiftUI
import WynKit

struct SetupView: View {
    @ObservedObject var vm: LibraryVM

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set up Wyn")
                .font(.title2.weight(.semibold))
            Text("Wine and the Steam bottle need to be in place before the library can launch games. GPTK/D3DMetal is optional and never downloaded.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !vm.setupMessage.isEmpty {
                Text(vm.setupMessage)
                    .font(.callout)
            }
            // Setup is where a first-time person is most likely to get stuck,
            // and the alert is suppressed while this sheet is up — so this is
            // the only place the failure is shown. It gets the step, the
            // reason, what to try, and a way to send it.
            if let failure = vm.failure {
                VStack(alignment: .leading, spacing: 6) {
                    Text(failure.title)
                        .font(.callout)
                        .fontWeight(.semibold)
                        .foregroundStyle(.red)
                    Text(failure.reason)
                        .font(.callout)
                        .foregroundStyle(.red)
                    if let hint = failure.hint {
                        Text("Try: \(hint)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Button("Export Diagnostics…") {
                        vm.exportDiagnostics(note: failure.noteLine)
                    }
                    .buttonStyle(.link)
                    .disabled(vm.isBusy)
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            HStack {
                Spacer()
                if !GameLibrary.needsSetup() {
                    Button("Continue") {
                        vm.showSetup = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
                Button(vm.isBusy ? "Working…" : "Set Up") {
                    vm.runSetup()
                }
                .disabled(vm.isBusy)
            }
        }
        .padding(24)
        .frame(width: 460, height: 280)
        .onAppear {
            if vm.setupMessage.isEmpty {
                vm.setupMessage = "Wine or the Steam bottle is missing."
            }
        }
    }
}
