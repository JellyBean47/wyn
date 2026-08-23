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
            if let error = vm.errorText {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
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
