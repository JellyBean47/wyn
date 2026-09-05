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
    /// Names of library games whose EXE is running. Drives the Quit warning.
    @Published var runningGameNames: [String] = []
    /// Every registered bottle, for the Bottles section.
    @Published var bottles: [BottleRowItem] = []
    @Published var showNewBottle = false
    @Published var platformRow: [PlatformRowItem] = []
    @Published var isBusy = false
    @Published var busyMessage = ""
    /// What broke, at which step, and what to try. Replaces a bare error
    /// string: the step is the half a person needs and the half the old
    /// `errorText` always threw away.
    @Published var failure: Failure?
    @Published var lastDiagnosticsPath: String?
    @Published var showSetup = false
    @Published var setupMessage = ""

    /// Turns the running-process poll into launch records. Held here because it
    /// is a state machine across polls, not a query.
    private var launchObserver = LaunchObserver()
    private var launchTask: Task<Void, Never>?
    private var launchGeneration = 0
    /// Dedicated Epic/EA/Battle.net/GOG prefix in flight. Cancel may kill this bottle only — never Steam.
    private var inFlightStoreBottle: Bottle?

    /// Profile id → the runtimes it declares that this bottle does not have.
    /// Normally empty; recomputed by the games refresh. See
    /// `selectedRuntimeWarning`.
    @Published private var runtimeWarnings: [String: String] = [:]

    var selectedGame: GameLibraryItem? {
        games.first { $0.id == selectedID }
    }

    /// The selected game's graphics layer and — the part that used to be
    /// invisible — which process will actually start it. Choosing a layer
    /// silently chooses that, and on Solarpunk the hidden half cost an hour:
    /// the `-applaunch` path let Steam pick a prerequisite shim, which threw a
    /// Visual C++ dialog for a runtime that was already installed.
    var selectedLaunchLabel: String? {
        guard let profile = selectedGame?.profile, let bottle else { return nil }
        let path = LaunchPath.forProfile(profile, in: bottle)
        // With no profile the layer is not what decides the launch, so naming
        // it would point at the wrong thing.
        guard path != .noProfile else { return path.shortLabel }
        let layer = LaunchPath.effectiveLayer(profile: profile, bottle: bottle)
        return "\(layer.displayName) · \(path.shortLabel)"
    }

    /// The long form, for the tooltip.
    var selectedLaunchExplanation: String? {
        guard let profile = selectedGame?.profile, let bottle else { return nil }
        return LaunchPath.forProfile(profile, in: bottle).explanation
    }

    /// Nil in the normal case, which is the point — this only speaks up when a
    /// runtime the profile declares is genuinely absent from the bottle.
    ///
    /// A beta tester lives in the app and will never run `wyn profiles show`,
    /// so the check has to reach here too. It is a note, not a block: the
    /// probe is a registry heuristic, and refusing to launch on it would be
    /// worse than the silence it replaces.
    ///
    /// Filled in by the games refresh rather than computed on demand — reading
    /// the registry from a SwiftUI body would do it on every redraw.
    var selectedRuntimeWarning: String? {
        selectedID.flatMap { runtimeWarnings[$0] }
    }

    /// Set only when the bottle is running on a Wine tree that cannot deliver
    /// the layer the selected game's profile asks for.
    ///
    /// This is the one that cost two hours of play on the wrong layer with no
    /// symptom but a warm Mac, so it gets its own line rather than being
    /// folded into the launch label — the launch label would happily say
    /// "D3DMetal · runs the game directly" while DXVK was doing the work.
    @Published private(set) var layerMismatch: LayerReality.Mismatch?

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
        refreshBottles()
        showSetup = GameLibrary.needsSetup()
        Task { await refreshGamesOffMainThread() }
    }

    func refresh() {
        refreshMetadata()
        refreshBottles()
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

        // Work the runtime warnings out here, off the main thread and once per
        // refresh. As a computed property this re-read a 4 MB registry hive on
        // every SwiftUI body evaluation.
        let warnings = await Task.detached(priority: .utility) {
            let registry = WindowsRuntimes.Snapshot(bottle: steam)
            var found: [String: String] = [:]
            for item in loaded where !item.profile.winetricks.isEmpty {
                let missing = registry.missing(profile: item.profile)
                guard !missing.isEmpty else { continue }
                found[item.id] = "Missing: " + missing.map(\.displayName).joined(separator: ", ")
            }
            return found
        }.value

        guard generation == gamesRefreshGeneration else { return }
        games = loaded
        runtimeWarnings = warnings
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
        runningGameNames = SteamLauncher.runningGameNames(among: games.map(\.profile))

        // Only D3DMetal profiles can be downgraded by the running tree, and
        // only then is it worth the process walk. Recomputed on the poll
        // because it depends on which wineserver is alive, which changes
        // underneath the app whenever Steam starts or stops.
        if let profile = selectedGame?.profile,
           LaunchPath.effectiveLayer(profile: profile, bottle: bottle) == .d3dMetal {
            layerMismatch = LayerReality.mismatch(profile: profile, in: bottle)
        } else {
            layerMismatch = nil
        }

        recordFinishedLaunches()
    }

    /// Write down anything that just finished a real run.
    ///
    /// Rides the poll that already exists rather than adding a watchdog — a
    /// second process-watcher on a Wine host is how you get orphans. The
    /// observer only reports a game once its process is gone *and* it stayed up
    /// long enough to mean something, so nothing is written while playing.
    private func recordFinishedLaunches() {
        let profiles = games.map(\.profile)
        let running = SteamLauncher.runningProfileIDs(among: profiles)
        let byID = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for finished in launchObserver.update(running: running) {
            guard let profile = byID[finished.profileID] else { continue }
            LaunchRecordStore.append(
                LaunchRecordStore.makeRecord(
                    for: profile,
                    startedAt: finished.startedAt,
                    ranFor: finished.ranFor
                )
            )
        }
    }

    /// Reload the Bottles section from BottleData.
    ///
    /// Cheap — reads BottleVM.plist and each bottle's Metadata.plist, no Wine.
    func refreshBottles() {
        var data = BottleData()
        bottles = data.loadBottles().map(BottleRowItem.init)
    }

    /// Create a bottle and show it immediately.
    ///
    /// Metadata only; the Wine prefix is initialised on first use. Nothing here
    /// runs Wine, so it cannot hang and there is no busy overlay.
    func createBottle(name: String, windows: WinVersion, graphics: TranslationLayer) {
        do {
            _ = try BottleFactory.create(name: name, windows: windows, graphics: graphics)
            showNewBottle = false
            refreshBottles()
        } catch {
            failure = Failure(step: "Creating the bottle", error: error)
        }
    }

    func openCDrive(for item: BottleRowItem) {
        let drive = item.url.appending(path: "drive_c")
        guard FileManager.default.fileExists(atPath: drive.path(percentEncoded: false)) else {
            failure = Failure(
                step: "Opening the C: drive",
                reason: """
                \(item.name) has no C: drive yet. Wyn sets the Wine prefix up \
                the first time something runs in the bottle.
                """,
                hint: "Launch something in \(item.name) first, then try again."
            )
            return
        }
        NSWorkspace.shared.open(drive)
    }

    /// True when Quit has something to close.
    var canQuit: Bool {
        steamRunning || !runningKinds.isEmpty
    }

    /// Quit Steam the way Steam's own Exit does.
    ///
    /// A running game is never force-closed. Killing a game mid-frame loses
    /// unsaved progress, and on D3DMetal it is exactly the case the 120 s GPU
    /// settle exists to avoid — so if one is up, say so and stop. Steam itself
    /// behaves the same way.
    func quitSteam() {
        guard let bottle else { return }

        let playing = runningGameNames
        if !playing.isEmpty {
            failure = Failure(
                step: "Quitting Steam",
                reason: """
                \(playing.joined(separator: ", ")) is still running.

                Wyn will not force-close a game: you would lose unsaved \
                progress, and on D3DMetal a killed session can make the next \
                launch crash.
                """,
                hint: "Quit the game from its own window, then press Quit here."
            )
            return
        }

        startLaunch("Asking Steam to exit…") {
            let stopped = try await SteamLauncher.quitSteam(in: bottle)
            if !stopped {
                await MainActor.run {
                    self.failure = Failure(
                        step: "Quitting Steam",
                        reason: "Steam did not exit when Wyn asked it to.",
                        hint: "Use Steam → Exit from Steam's own window."
                    )
                }
            }
            await MainActor.run { self.pollStatus() }
        }
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
            failure = Failure(
                step: "Opening Steam",
                reason: "There is no Steam bottle yet.",
                hint: "Run Setup — it creates the bottle and installs Steam."
            )
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
            failure = Failure(
                step: "Starting the game",
                reason: "There is no Steam bottle yet.",
                hint: "Run Setup — it creates the bottle and installs Steam."
            )
            showSetup = true
            return
        }
        guard let item = selectedGame else {
            failure = Failure(
                step: "Starting the game",
                reason: "No game is selected.",
                hint: "Pick a game in the library, then press Play."
            )
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
            failure = Failure(step: "Stopping the bottle", error: error)
        }
    }

    func openLogs() {
        let folder = Wine.logsFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path(percentEncoded: false))
    }

    /// Put everything needed to diagnose a failure into one zip on the Desktop
    /// and reveal it in Finder.
    ///
    /// The bug that made this necessary — the black Steam login window — was
    /// diagnosed from a bottle's directory birth times, a grep of Steam's
    /// webhelper.txt and a count in bootstrap_log.txt. Three files nobody can
    /// be expected to find, inside a bottle, on a machine we cannot reach. The
    /// zip is the difference between "it was black" and a report we can act on.
    ///
    /// `note` carries whatever the person was doing when it broke, when we have
    /// it — an error message is the most useful sentence in the whole bundle.
    func exportDiagnostics(note: String? = nil) {
        let target = bottle
        let reporterNote = note ?? failure?.noteLine
        isBusy = true
        busyMessage = "Collecting diagnostics…"
        Task { [weak self] in
            let outcome = Result {
                try DiagnosticsBundle.create(bottle: target, note: reporterNote)
            }
            await MainActor.run {
                guard let self else { return }
                self.isBusy = false
                self.busyMessage = ""
                switch outcome {
                case .success(let bundle):
                    NSWorkspace.shared.activateFileViewerSelecting([bundle.url])
                    self.lastDiagnosticsPath = bundle.url.lastPathComponent
                case .failure(let error):
                    self.failure = Failure(step: "Exporting diagnostics", error: error)
                }
            }
        }
    }

    func openCDrive() {
        guard let bottle else { return }
        NSWorkspace.shared.open(bottle.url.appending(path: "drive_c"))
    }

    func runSetup() {
        Task {
            isBusy = true
            setupMessage = "Installing Wine runtime and Steam bottle…"
            failure = nil
            do {
                let result = try await WynInstaller.setup(installSteamClient: true)
                // GPTK/D3DMetal is optional and never auto-wired from Desktop/whisky-wine.
                var justInstalledSteam = false
                if let installer = result.steamInstallerPath, !SteamLauncher.isSteamInstalled(in: result.bottle) {
                    setupMessage = "Installing Steam…"
                    try await SteamLauncher.runSteamInstaller(in: result.bottle, installer: installer)
                    justInstalledSteam = SteamLauncher.isSteamInstalled(in: result.bottle)
                }
                refresh()
                showSetup = GameLibrary.needsSetup()
                setupMessage = showSetup ? "Setup unfinished." : "Ready."
                isBusy = false
                if justInstalledSteam {
                    launchSteam()
                }
            } catch {
                // The setup message says which of the two phases we reached,
                // so carry it into the step rather than saying "Setup".
                failure = Failure(step: setupMessage, error: error)
                setupMessage = "Setup failed."
                showSetup = true
                isBusy = false
            }
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
        failure = nil
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
            } catch {
                // `message` is what the busy overlay was showing when this
                // threw — "Opening Steam…", "Launching Satisfactory…". It is
                // the step, it was always right here, and the five
                // type-specific catch blocks this replaces each discarded it
                // and reported the same bare `localizedDescription`. They were
                // identical in behaviour, so there is nothing to lose by
                // collapsing them and a step name to gain.
                if generation == self.launchGeneration {
                    failure = Failure(step: message, error: error)
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
