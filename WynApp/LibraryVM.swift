//
//  LibraryVM.swift
//  Wyn
//
//  This file is part of Wyn.
//

import AppKit
import Foundation
import SwiftUI
import WynKit

@MainActor
final class LibraryVM: ObservableObject {
    @Published var bottle: Bottle?
    @Published var games: [GameLibraryItem] = []
    @Published var platforms: [InstalledPlatform] = []
    @Published var selectedID: String?
    @Published var steamInstalled = false
    @Published var steamRunning = false
    @Published var steamLoggedOn = false
    @Published var ubisoftRunning = false
    @Published var rockstarRunning = false
    @Published var runningKinds: Set<PlatformKind> = []
    @Published var platformRow: [PlatformRowItem] = []
    @Published var isBusy = false
    @Published var busyMessage = ""
    @Published var errorText: String?
    @Published var showSetup = false
    @Published var setupMessage = ""

    private var launchTask: Task<Void, Never>?
    private var launchGeneration = 0
    /// Dedicated Epic/EA/Battle.net/GOG prefix in flight. Cancel may kill this bottle only — never Steam.
    private var inFlightStoreBottle: Bottle?

    var selectedGame: GameLibraryItem? {
        games.first { $0.id == selectedID }
    }

    var steamStatusLabel: String {
        if bottle == nil { return "No Steam bottle" }
        if !steamInstalled { return "Steam not installed" }
        if steamLoggedOn { return "Logged On" }
        if steamRunning { return "Running — not logged on" }
        return "Not running"
    }

    func platformSubtitle(_ item: PlatformRowItem) -> String {
        if item.kind == .epic || item.kind == .gog {
            if runningKinds.contains(item.kind) { return "Heroic running" }
            if HeroicLauncher.isInstalled() { return "Heroic" }
            return "Install Heroic first"
        }
        if item.needsInstall {
            return "Click to install"
        }
        switch item.kind {
        case .steam:
            return steamStatusLabel
        default:
            return runningKinds.contains(item.kind) ? "Running" : "Installed"
        }
    }

    private var gamesRefreshGeneration = 0

    init() {
        refreshMetadata()
        showSetup = GameLibrary.needsSetup()
        Task { await refreshGamesOffMainThread() }
    }

    func refresh() {
        refreshMetadata()
        Task { await refreshGamesOffMainThread() }
    }

    /// Platforms only. `GameLibrary.installed` walks Steam `common` (Ride) on
    /// the main thread and can leave Wyn with no window. Battle.net Play needs
    /// the window first. Do not wineserver -k Steam.
    private func refreshMetadata() {
        let steam = GameLibrary.steamBottle()
        bottle = steam
        platforms = PlatformCatalog.installed()
        platformRow = PlatformCatalog.platformRow()
        runningKinds = Set(PlatformKind.allCases.filter { PlatformCatalog.isRunning($0) })
        ubisoftRunning = runningKinds.contains(.ubisoft)
        rockstarRunning = runningKinds.contains(.rockstar)
        if let steam {
            steamInstalled = SteamLauncher.isSteamInstalled(in: steam)
            steamRunning = SteamLauncher.isSteamClientRunning(in: steam)
            steamLoggedOn = SteamLauncher.isSteamLoggedOn(in: steam)
        } else {
            games = []
            steamInstalled = false
            steamRunning = false
            steamLoggedOn = false
        }
        showSetup = GameLibrary.needsSetup()
    }

    private func refreshGamesOffMainThread() async {
        gamesRefreshGeneration += 1
        let generation = gamesRefreshGeneration
        guard let steam = bottle else {
            games = []
            selectedID = nil
            return
        }
        let loaded = await Task.detached(priority: .utility) {
            GameLibrary.installed(in: steam)
        }.value
        guard generation == gamesRefreshGeneration else { return }
        games = loaded
        if let selectedID, !games.contains(where: { $0.id == selectedID }) {
            self.selectedID = games.first?.id
        } else if selectedID == nil {
            selectedID = games.first?.id
        }
    }

    func pollStatus() {
        runningKinds = Set(PlatformKind.allCases.filter { PlatformCatalog.isRunning($0) })
        ubisoftRunning = runningKinds.contains(.ubisoft)
        rockstarRunning = runningKinds.contains(.rockstar)
        guard let bottle else { return }
        steamInstalled = SteamLauncher.isSteamInstalled(in: bottle)
        steamRunning = SteamLauncher.isSteamClientRunning(in: bottle)
        steamLoggedOn = SteamLauncher.isSteamLoggedOn(in: bottle)
    }

    func launchPlatform(_ item: InstalledPlatform) {
        startLaunch("Opening \(item.kind.displayName)…") {
            if item.kind.dedicatedBottleName != nil {
                await MainActor.run { self.inFlightStoreBottle = item.bottle() }
            }
            try await PlatformCatalog.launch(item)
            await MainActor.run { self.clearInFlight(item.bottle()) }
        }
    }

    func activatePlatform(_ item: PlatformRowItem) {
        if item.kind == .epic || item.kind == .gog {
            startLaunch("Opening \(item.kind.displayName)…") {
                try await HeroicLauncher.ensureAndOpen()
            }
            return
        }
        if let installed = item.installed {
            launchPlatform(installed)
            return
        }
        // Leftover GOG web installer still up and the client EXE is missing
        // from the probe — do not spawn a second GOG_Galaxy_2.0.exe.
        if PlatformCatalog.isStoreInstallerRunning(item.kind) {
            return
        }
        startLaunch("Installing \(item.kind.displayName)…") {
            let bottle = try StoreInstaller.ensureBottle(for: item.kind)
            await MainActor.run { self.inFlightStoreBottle = bottle }
            try await StoreInstaller.install(item.kind)
            await MainActor.run { self.clearInFlight(bottle) }
        }
    }

    func launchSteam() {
        guard let bottle else {
            errorText = "No Steam bottle. Run setup first."
            showSetup = true
            return
        }
        startLaunch("Opening Steam…") {
            var options = Wine.LaunchOptions()
            options.detachAfterStart = true
            try await SteamLauncher.launchSteam(in: bottle, options: options)
        }
    }

    func playSelected() {
        guard let bottle else {
            errorText = "No Steam bottle. Run setup first."
            showSetup = true
            return
        }
        guard let item = selectedGame else {
            errorText = "Select a game, then press Play."
            return
        }
        startLaunch("Launching \(item.profile.name)…") {
            var options = Wine.LaunchOptions()
            options.detachAfterStart = true
            _ = try await SteamLauncher.launchGame(
                profile: item.profile,
                in: bottle,
                options: options
            )
        }
    }

    func cancelLaunch() {
        launchGeneration += 1
        launchTask?.cancel()
        launchTask = nil
        isBusy = false
        busyMessage = ""
        let bottle = inFlightStoreBottle
        inFlightStoreBottle = nil
        guard let bottle, bottle.settings.name == PlatformKind.ea.dedicatedBottleName
            || bottle.settings.name == PlatformKind.epic.dedicatedBottleName
            || bottle.settings.name == PlatformKind.battlenet.dedicatedBottleName
            || bottle.settings.name == PlatformKind.gog.dedicatedBottleName
        else {
            return
        }
        Task {
            try? await Wine.killBottleAndWait(bottle: bottle)
        }
    }

    private func clearInFlight(_ bottle: Bottle) {
        if inFlightStoreBottle?.url.lastPathComponent == bottle.url.lastPathComponent {
            inFlightStoreBottle = nil
        }
    }

    func play(_ item: GameLibraryItem) {
        selectedID = item.id
        playSelected()
    }

    func killBottle() {
        guard let bottle else { return }
        do {
            try Wine.killBottle(bottle: bottle)
            pollStatus()
        } catch {
            errorText = error.localizedDescription
        }
    }

    func openLogs() {
        let folder = Wine.logsFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path(percentEncoded: false))
    }

    func openCDrive() {
        guard let bottle else { return }
        NSWorkspace.shared.open(bottle.url.appending(path: "drive_c"))
    }

    func runSetup() {
        Task {
            isBusy = true
            setupMessage = "Installing Wine runtime and Steam bottle…"
            errorText = nil
            do {
                let result = try await WynInstaller.setup(installSteamClient: true)
                // GPTK/D3DMetal is optional and never auto-wired from Desktop/whisky-wine.
                if let installer = result.steamInstallerPath, !SteamLauncher.isSteamInstalled(in: result.bottle) {
                    setupMessage = "Installing Steam (complete the wizard)…"
                    try await SteamLauncher.runSteamInstaller(in: result.bottle, installer: installer)
                }
                refresh()
                showSetup = GameLibrary.needsSetup()
                setupMessage = showSetup ? "Setup unfinished." : "Ready."
            } catch {
                errorText = error.localizedDescription
                setupMessage = "Setup failed."
                showSetup = true
            }
            isBusy = false
        }
    }

    private func startLaunch(_ message: String, _ work: @escaping () async throws -> Void) {
        launchTask?.cancel()
        launchGeneration += 1
        let generation = launchGeneration
        launchTask = Task {
            await self.runLaunch(generation, message, work)
        }
    }

    private func runLaunch(
        _ generation: Int,
        _ message: String,
        _ work: @escaping () async throws -> Void
    ) async {
        isBusy = true
        busyMessage = message
        errorText = nil
        let sink: @Sendable (String) -> Void = { text in
            Task { @MainActor in
                LibraryVM.progressHost?.handleProgress(text)
            }
        }
        Self.progressHost = self
        await LaunchProgress.$sink.withValue(sink) {
            do {
                try Task.checkCancellation()
                try await work()
            } catch is CancellationError {
                // Overlay dismiss / Cancel — do not surface as an error.
            } catch let error as SteamError {
                if generation == self.launchGeneration {
                    errorText = error.localizedDescription
                }
            } catch let error as PlatformLaunchError {
                if generation == self.launchGeneration {
                    errorText = error.localizedDescription
                }
            } catch let error as StoreInstallError {
                if generation == self.launchGeneration {
                    errorText = error.localizedDescription
                }
            } catch let error as Wine.D3DMetalError {
                if generation == self.launchGeneration {
                    errorText = error.localizedDescription
                }
            } catch {
                if generation == self.launchGeneration {
                    errorText = error.localizedDescription
                }
            }
        }
        if generation == launchGeneration {
            isBusy = false
            busyMessage = ""
            launchTask = nil
            pollStatus()
            refresh()
        }
    }

    private static weak var progressHost: LibraryVM?

    private func handleProgress(_ message: String) {
        guard isBusy else { return }
        busyMessage = message
    }
}
