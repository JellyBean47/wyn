//
//  NewBottleSheet.swift
//  Wyn
//
//  The New Bottle form. Same three inputs as `wyn create`, so the app and the
//  CLI stay one feature rather than two.
//

import SwiftUI
import WynKit

struct NewBottleSheet: View {
    let onCreate: (String, WinVersion, TranslationLayer) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var windows: WinVersion = .win10
    @State private var graphics: TranslationLayer = .dxmt
    @FocusState private var nameFocused: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Checked here as well as in BottleFactory so the button disables instead
    /// of letting someone submit into an error.
    private var nameProblem: String? {
        if trimmedName.isEmpty { return nil }
        if BottleFactory.isReservedName(trimmedName) {
            return "Wyn uses that name for one of its own bottles."
        }
        if BottleFactory.existingNames().contains(where: {
            $0.lowercased() == trimmedName.lowercased()
        }) {
            return "A bottle with that name already exists."
        }
        return nil
    }

    private var canCreate: Bool {
        !trimmedName.isEmpty && nameProblem == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Bottle")
                .font(.title2.weight(.semibold))

            Form {
                TextField("Name", text: $name, prompt: Text("My Games"))
                    .focused($nameFocused)
                Picker("Windows", selection: $windows) {
                    ForEach(WinVersion.allCases, id: \.self) { version in
                        Text(version.pretty()).tag(version)
                    }
                }
                Picker("Graphics", selection: $graphics) {
                    ForEach(TranslationLayer.allCases, id: \.self) { layer in
                        Text(layer.rawValue.uppercased()).tag(layer)
                    }
                }
            }
            .formStyle(.grouped)

            if let nameProblem {
                Label(nameProblem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else {
                Text("The Windows environment is set up the first time you run something in this bottle.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    onCreate(trimmedName, windows, graphics)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { nameFocused = true }
    }
}
