//
//  LibraryView.swift
//  Wyn
//
//  This file is part of Wyn.
//

import SwiftUI
import WynKit

struct LibraryView: View {
    @ObservedObject var vm: LibraryVM

    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 180), spacing: 16)]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                statusStrip
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        platformSection
                        gamesSection
                        bottlesSection
                    }
                    .padding(20)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle("Wyn")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        vm.refresh()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(vm.isBusy)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        vm.quitSteam()
                    } label: {
                        Label("Quit", systemImage: "stop.fill")
                    }
                    // Enabled only when there is something to close, so it
                    // never reads as a way to quit Wyn itself.
                    .disabled(!vm.canQuit || vm.isBusy)
                    .help(vm.runningGameNames.isEmpty
                          ? "Exit Steam, like Steam's own Exit"
                          : "Quit \(vm.runningGameNames.joined(separator: ", ")) from its own window first")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        vm.playSelected()
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .disabled(vm.selectedGame == nil || vm.isBusy)
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
            .overlay {
                if vm.isBusy {
                    ZStack {
                        Color.black.opacity(0.18)
                        VStack(spacing: 10) {
                            ProgressView()
                            Text(vm.busyMessage.isEmpty ? vm.setupMessage : vm.busyMessage)
                                .font(.callout)
                                .multilineTextAlignment(.center)
                            VStack(spacing: 2) {
                                Text("Steam · \(vm.steamStatusLabel)")
                                Text("Connect · \(vm.ubisoftRunning ? "Running" : "Not running")")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            Button("Cancel") {
                                vm.cancelLaunch()
                            }
                            .keyboardShortcut(.cancelAction)
                        }
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .ignoresSafeArea()
                }
            }
            .alert("Wyn", isPresented: errorPresented) {
                Button("OK", role: .cancel) { vm.errorText = nil }
            } message: {
                Text(vm.errorText ?? "")
            }
            .sheet(isPresented: $vm.showSetup) {
                SetupView(vm: vm)
            }
            .onReceive(Timer.publish(every: 2.5, on: .main, in: .common).autoconnect()) { _ in
                vm.pollStatus()
            }
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { vm.errorText != nil && !vm.showSetup },
            set: { if !$0 { vm.errorText = nil } }
        )
    }

    private var statusStrip: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text("Steam")
                .fontWeight(.semibold)
            Text(vm.steamStatusLabel)
                .foregroundStyle(.secondary)
            Spacer()
            if let name = vm.selectedGame?.profile.name {
                Text(name)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var statusColor: Color {
        if vm.steamLoggedOn { return .green }
        if vm.steamRunning { return .orange }
        return .secondary
    }

    private var platformSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Platform")
                .font(.title3.weight(.semibold))
            if vm.platformRow.isEmpty {
                Text("No Windows launchers found.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(vm.platformRow) { item in
                        Button {
                            vm.activatePlatform(item)
                        } label: {
                            GameTile(
                                title: item.kind.displayName,
                                subtitle: vm.platformSubtitle(item),
                                systemImage: item.kind.systemImage,
                                isSelected: false,
                                platformKind: item.kind
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.kind.displayName)
                        .disabled(vm.isBusy)
                    }
                }
            }
        }
    }

    private var gamesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Games")
                .font(.title3.weight(.semibold))
            if vm.games.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(vm.games) { item in
                        Button {
                            vm.selectedID = item.id
                        } label: {
                            GameTile(
                                title: item.profile.name,
                                subtitle: item.profile.publisher ?? "Steam",
                                systemImage: "square.stack.3d.up.fill",
                                isSelected: vm.selectedID == item.id,
                                steamAppId: item.profile.steamAppId,
                                bottle: vm.bottle
                            )
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture(count: 2).onEnded {
                            vm.play(item)
                        })
                    }
                }
            }
        }
    }

    private var bottlesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bottles")
                .font(.title3.weight(.semibold))
            Text("A bottle is a separate Windows environment. Wyn sets each one up the first time something runs in it.")
                .font(.callout)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(vm.bottles) { item in
                    Button {
                        vm.openCDrive(for: item)
                    } label: {
                        GameTile(
                            title: item.name,
                            subtitle: item.subtitle,
                            systemImage: "shippingbox.fill",
                            isSelected: false
                        )
                    }
                    .buttonStyle(.plain)
                    .help(item.isInitialised
                          ? "Open the C: drive for \(item.name)"
                          : "\(item.name) is set up the first time something runs in it")
                    .accessibilityLabel("Bottle \(item.name)")
                }

                Button {
                    vm.showNewBottle = true
                } label: {
                    GameTile(
                        title: "New Bottle",
                        subtitle: "Create a Windows environment",
                        systemImage: "plus",
                        isSelected: false
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New bottle")
            }
        }
        .sheet(isPresented: $vm.showNewBottle) {
            NewBottleSheet { name, windows, graphics in
                vm.createBottle(name: name, windows: windows, graphics: graphics)
            } onCancel: {
                vm.showNewBottle = false
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(emptyTitle)
                .font(.headline)
            Text(emptySubtitle)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6]))
                .foregroundStyle(.secondary.opacity(0.4))
        }
    }

    private var emptyTitle: String {
        if vm.bottle == nil { return "No Steam bottle" }
        if !vm.steamInstalled { return "Steam is not installed" }
        return "No installed games yet"
    }

    private var emptySubtitle: String {
        if vm.bottle == nil || !vm.steamInstalled {
            return "Complete setup, then install a Windows game in Steam."
        }
        return "Install a game in Steam, then refresh."
    }
}
