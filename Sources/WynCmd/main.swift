import ArgumentParser
import WynKit
import Foundation
import SemanticVersion
import SwiftyTextTable

extension WinVersion: @retroactive ExpressibleByArgument {}
extension TranslationLayer: @retroactive ExpressibleByArgument {}

@main
struct WynCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wyn",
        abstract: "Wyn — a macOS Wine wrapper for Windows games (DXVK/DXMT; optional user-supplied D3DMetal).",
        subcommands: [
            Install.self,
            List.self,
            Create.self,
            Delete.self,
            Run.self,
            Play.self,
            Doctor.self,
            Shellenv.self,
            Profiles.self,
            Runtime.self,
            Steam.self,
            GPTK.self
        ]
    )
}

// MARK: - Bottles

extension WynCLI {
    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List registered bottles.")

        mutating func run() throws {
            var data = BottleData()
            let bottles = data.loadBottles()

            let nameCol = TextTableColumn(header: "Name")
            let winCol = TextTableColumn(header: "Windows")
            let layerCol = TextTableColumn(header: "Graphics")
            let pathCol = TextTableColumn(header: "Path")

            var table = TextTable(columns: [nameCol, winCol, layerCol, pathCol])
            for bottle in bottles {
                table.addRow(values: [
                    bottle.settings.name,
                    bottle.settings.windowsVersion.pretty(),
                    bottle.settings.translationLayer.displayName,
                    bottle.url.prettyPath()
                ])
            }

            print(table.render())
        }
    }

    struct Create: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a new bottle.")

        @Argument(help: "Display name for the bottle.")
        var name: String

        @Option(name: .long, help: "Windows version preset.")
        var windows: WinVersion = .win10

        @Option(name: .long, help: "Graphics translation layer.")
        var graphics: TranslationLayer = .dxmt

        mutating func run() throws {
            let bottleURL = BottleData.defaultBottleDir.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: bottleURL, withIntermediateDirectories: true)

            let bottle = Bottle(bottleUrl: bottleURL, inFlight: true)
            bottle.settings.name = name
            bottle.settings.windowsVersion = windows
            bottle.settings.translationLayer = graphics
            bottle.settings.dxvk = graphics == .dxvk

            var data = BottleData()
            data.paths.append(bottleURL)

            print("Created bottle \"\(name)\" at \(bottleURL.prettyPath())")
        }
    }

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a bottle from disk.")

        @Argument var name: String

        @Flag(name: .long, help: "Remove from registry only, keep files on disk.")
        var keepFiles: Bool = false

        mutating func run() throws {
            var data = BottleData()
            let bottles = data.loadBottles()

            guard let bottle = bottles.first(where: { $0.settings.name == name }) else {
                throw ValidationError("No bottle named \"\(name)\".")
            }

            data.paths.removeAll { $0 == bottle.url }

            if !keepFiles {
                try FileManager.default.removeItem(at: bottle.url)
            }

            print(keepFiles ? "Removed \"\(name)\" from registry." : "Deleted \"\(name)\".")
        }
    }

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Run a Windows executable in a bottle.")

        @Argument var bottleName: String
        @Argument var executable: String
        @Argument var args: [String] = []

        @Option(name: .long, help: "Apply a game profile by id (e.g. elden-ring).")
        var profile: String?

        @Flag(name: .long, help: "Auto-detect profile from executable name.")
        var autoProfile: Bool = false

        @Flag(name: .long, help: "Launch in Terminal instead of directly.")
        var terminal: Bool = false

        @Flag(name: .long, help: "God-level diagnostics: dump DLL/env state and stream Wine output.")
        var debug: Bool = false

        mutating func run() async throws {
            var data = BottleData()
            guard let bottle = data.loadBottles().first(where: { $0.settings.name == bottleName }) else {
                throw ValidationError("No bottle named \"\(bottleName)\".")
            }

            guard WynWineInstaller.isWynWineInstalled() else {
                throw ValidationError("WynWine runtime not installed. Run: wyn runtime install")
            }

            let url = URL(fileURLWithPath: executable)
            let program = Program(url: url, bottle: bottle)

            var matchedProfile: GameProfile?
            if let profileId = profile {
                matchedProfile = ProfileStore.profile(id: profileId)
                if matchedProfile == nil {
                    throw ValidationError("Unknown profile \"\(profileId)\".")
                }
            } else if autoProfile {
                matchedProfile = ProfileStore.match(executable: url)
                if let matchedProfile {
                    print("Matched profile: \(matchedProfile.name)")
                }
            }

            if let matchedProfile {
                ProfileApplicator.apply(profile: matchedProfile, to: bottle)
            }

            let environment = ProfileApplicator.launchEnvironment(profile: matchedProfile, program: program)
            var launchArgs = ProfileApplicator.launchArguments(profile: matchedProfile, program: program)
            launchArgs.append(contentsOf: args)

            if debug {
                let report = LaunchDiagnostics.inspect(
                    bottle: bottle,
                    profile: matchedProfile,
                    executable: url,
                    environment: environment,
                    phase: "preflight"
                )
                print(report.rendered)
            }

            if terminal {
                program.runInTerminal(profile: matchedProfile)
            } else {
                try await Wine.runProgram(
                    at: url, args: launchArgs, bottle: bottle, environment: environment,
                    options: Wine.LaunchOptions(debug: debug, echoOutput: debug)
                )

                if debug {
                    let post = LaunchDiagnostics.inspect(
                        bottle: bottle,
                        profile: matchedProfile,
                        executable: url,
                        environment: environment,
                        phase: "postflight (after DLL deploy)"
                    )
                    print(post.rendered)
                }
            }
        }
    }

    struct Shellenv: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print shell export statements for a bottle (eval $(wyn shellenv <name>))."
        )

        @Argument var bottleName: String

        mutating func run() throws {
            var data = BottleData()
            guard let bottle = data.loadBottles().first(where: { $0.settings.name == bottleName }) else {
                throw ValidationError("No bottle named \"\(bottleName)\".")
            }

            print(Wine.generateTerminalEnvironmentCommand(bottle: bottle))
        }
    }
}

// MARK: - Profiles

extension WynCLI {
    struct Profiles: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manage game compatibility profiles.",
            subcommands: [ProfilesList.self, ProfilesShow.self, ProfilesApply.self]
        )
    }

    struct ProfilesList: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List available game profiles."
        )

        mutating func run() throws {
            let profiles = ProfileStore.loadAll()

            let idCol = TextTableColumn(header: "ID")
            let nameCol = TextTableColumn(header: "Game")
            let layerCol = TextTableColumn(header: "Graphics")

            var table = TextTable(columns: [idCol, nameCol, layerCol])
            for profile in profiles {
                table.addRow(values: [
                    profile.id,
                    profile.name,
                    profile.bottle?.translationLayer?.displayName ?? "—"
                ])
            }

            print(table.render())
        }
    }

    struct ProfilesShow: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Show details for a game profile."
        )

        @Argument var id: String

        mutating func run() throws {
            guard let profile = ProfileStore.profile(id: id) else {
                throw ValidationError("Unknown profile \"\(id)\".")
            }

            print("Name:       \(profile.name)")
            if let publisher = profile.publisher { print("Publisher:  \(publisher)") }
            if let steam = profile.steamAppId { print("Steam ID:   \(steam)") }
            print("Patterns:   \(profile.exePatterns.joined(separator: ", "))")
            if let layer = profile.bottle?.translationLayer {
                print("Graphics:   \(layer.displayName)")
            }
            if !profile.environment.isEmpty {
                print("Environment:")
                for (key, value) in profile.environment.sorted(by: { $0.key < $1.key }) {
                    print("  \(key)=\(value)")
                }
            }
            if !profile.winetricks.isEmpty {
                print("Winetricks: \(profile.winetricks.joined(separator: ", "))")
            }
            if let launchArgs = profile.launchArgs, !launchArgs.isEmpty {
                print("Launch args: \(launchArgs)")
            }
            if let unreal = profile.unrealProject {
                print("Unreal project: \(unreal)")
            }
            if let notes = profile.notes {
                print("\nNotes: \(notes)")
            }
        }
    }

    struct ProfilesApply: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "apply",
            abstract: "Apply a profile's bottle settings to an existing bottle."
        )

        @Argument var profileId: String
        @Argument var bottleName: String

        mutating func run() throws {
            guard let profile = ProfileStore.profile(id: profileId) else {
                throw ValidationError("Unknown profile \"\(profileId)\".")
            }

            var data = BottleData()
            guard let bottle = data.loadBottles().first(where: { $0.settings.name == bottleName }) else {
                throw ValidationError("No bottle named \"\(bottleName)\".")
            }

            ProfileApplicator.apply(profile: profile, to: bottle)
            print("Applied \"\(profile.name)\" settings to bottle \"\(bottleName)\".")
        }
    }
}

// MARK: - Install

extension WynCLI {
    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "One-shot Wyn setup: WynWine runtime + Steam bottle.",
            discussion: """
            Downloads the Wine/GPTK runtime (~500 MB) and creates a \"Steam\" bottle.
            After this, run `wyn steam install` once to install the Steam client.
            """
        )

        @Flag(name: .long, help: "Skip downloading the WynWine runtime if already installed.")
        var skipRuntime: Bool = false

        @Flag(name: .long, help: "Do not download SteamSetup.exe.")
        var skipSteamDownload: Bool = false

        mutating func run() async throws {
            if skipRuntime && WynWineInstaller.isWynWineInstalled() {
                let bottle = try SteamLauncher.ensureSteamBottle()
                print(WynInstaller.postInstallInstructions(result: WynInstallResult(
                    runtimeInstalled: true,
                    bottleCreated: false,
                    steamInstallerPath: nil,
                    bottle: bottle
                )))
                return
            }

            print("Setting up Wyn (runtime + Steam bottle)...")
            print("This downloads ~500 MB of Wine/GPTK binaries. Grab a coffee.\n")

            let result = try await WynInstaller.setup(installSteamClient: !skipSteamDownload)
            print(WynInstaller.postInstallInstructions(result: result))
        }
    }
}

// MARK: - Play

extension WynCLI {
    struct Play: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Launch a game by profile id (uses the Steam bottle).",
            discussion: """
            Looks up the game in steamapps via its Steam app id and applies the profile.

            Single-host (FOSS winecx + D3DMetal in Libraries/):
              wyn steam launch          # game-host Steam UI — log in, Remember me, then Play
              wyn play <id>             # fallback: D3DMetal direct EXE (skips Steam launchers)

            Rollback frankea (auth-only / emergency):
              wyn steam launch --frankea-steam
              wyn play <id>             # then frankea + DXVK-macOS if Steam stays on frankea

            DXMT/DXVK profiles: steam.exe -applaunch. Use --direct for EXE without Steam.
            """
        )

        @Argument(help: "Profile id (e.g. rv-there-yet, ready-or-not).")
        var profileId: String

        @Flag(name: .long, help: "God-level diagnostics: dump DLL/env state and stream Wine output.")
        var debug: Bool = false

        @Flag(name: .long, help: "Auth/launch signal only (wineserver, Logged On, FactoryGame.log) — no MoltenVK spam. Always printed on play; this flag is reserved for future verbosity.")
        var authDebug: Bool = false

        @Flag(name: .long, help: "Force-migrate frankea Steam → game-host Wine for D3DMetal (default play already migrates unless Steam was started with --frankea-steam).")
        var d3dmetal: Bool = false

        @Flag(name: .customLong("frankea-steam"), help: "Keep frankea Steam (no game-host migrate). D3DMetal profiles fall back to frankea + DXVK-macOS on the same wineserver as Connect.")
        var frankeaSteam: Bool = false

        @Flag(name: .long, help: "DXMT/DXVK only: run game EXE without steam.exe -applaunch. Ignored for D3DMetal (always direct).")
        var direct: Bool = false

        mutating func run() async throws {
            guard let profile = ProfileStore.profile(id: profileId) else {
                throw ValidationError("Unknown profile \"\(profileId)\". Run: wyn profiles list")
            }

            guard WynWineInstaller.isWynWineInstalled() else {
                throw ValidationError("WynWine not installed. Run: wyn install")
            }

            var data = BottleData()
            guard let bottle = data.loadBottles().first(where: { $0.settings.name == SteamLauncher.defaultBottleName }) else {
                throw ValidationError("No Steam bottle. Run: wyn install")
            }

            guard let appId = profile.steamAppId else {
                throw ValidationError("Profile \"\(profileId)\" has no Steam app id.")
            }

            guard let exe = SteamLauncher.findGameExecutable(forAppId: appId, in: bottle, profile: profile) else {
                throw ValidationError("""
                Game not found in Steam bottle. Install it first:
                  1. wyn steam launch
                  2. Install \"\(profile.name)\" in Steam
                  3. wyn play \(profileId)
                """)
            }

            ProfileApplicator.apply(profile: profile, to: bottle)
            let launchArgs = ProfileApplicator.launchArguments(
                profile: profile,
                program: Program(url: exe, bottle: bottle)
            )
            let layer = profile.bottle?.translationLayer
                ?? bottle.settings.translationLayer
            let appleDirect = layer == .d3dMetal
            let diagProgram = Program(
                url: (appleDirect || direct) ? exe : SteamLauncher.steamExePath(in: bottle),
                bottle: bottle
            )
            let environment = ProfileApplicator.launchEnvironment(profile: profile, program: diagProgram)
            var launchOptions = Wine.LaunchOptions(debug: debug, echoOutput: debug)
            launchOptions.preferD3DMetalAuth = d3dmetal
            if frankeaSteam && d3dmetal {
                throw ValidationError("Use either --frankea-steam (DXVK on frankea) or --d3dmetal (migrate), not both.")
            }
            launchOptions.preferFrankeaSteam = frankeaSteam

            print("Launching \(profile.name)...")
            if appleDirect {
                if frankeaSteam {
                    print("Mode: --frankea-steam — keep frankea Steam+Connect; DXVK-macOS (not D3DMetal)")
                } else if d3dmetal {
                    print("Mode: --d3dmetal — migrate frankea→game-host if needed; frankea+DXVK only if migrate fails")
                } else {
                    print("Mode: single-host — D3DMetal on Libraries/ Wine; migrate frankea Steam if needed")
                }
                print("Tip: wyn steam launch → confirm Logged On → wyn play \(profileId)")
            } else if direct {
                print("Mode: direct EXE (no Steam -applaunch)")
            } else {
                print("Mode: steam.exe -applaunch \(appId)")
            }
            print("Executable: \(exe.path(percentEncoded: false))")
            if !launchArgs.isEmpty {
                print("Game args: \(launchArgs.joined(separator: " "))")
            }

            // Always-on compact auth signal (no MoltenVK). `--debug` still dumps full DLL report.
            LaunchDiagnostics.printAuthSignal(
                bottle: bottle,
                profile: profile,
                layer: layer,
                phase: "play entry"
            )
            if authDebug {
                print("(auth-debug: detailed signal is always printed around launch; see pre/post blocks)")
            }

            if debug {
                let report = LaunchDiagnostics.inspect(
                    bottle: bottle,
                    profile: profile,
                    executable: exe,
                    environment: environment,
                    phase: "preflight"
                )
                print(report.rendered)
            }

            do {
                _ = try await SteamLauncher.launchGame(
                    profile: profile,
                    in: bottle,
                    direct: direct,
                    options: launchOptions
                )
            } catch let error as SteamError {
                throw ValidationError(error.localizedDescription)
            } catch let error as Wine.D3DMetalError {
                throw ValidationError(error.localizedDescription)
            }

            if debug {
                let post = LaunchDiagnostics.inspect(
                    bottle: bottle,
                    profile: profile,
                    executable: exe,
                    environment: environment,
                    phase: "postflight (after DLL deploy)"
                )
                print(post.rendered)
                if appleDirect {
                    print("""

                    Option A sign-off:
                    - Process: GPTK wineserver + game EXE (not steam.exe -applaunch)
                    - Logs: look for D3DM prefix / libd3dshared load
                    - Fail: Unreal "Feature Level 11.0" / fake GeForce dialog = D3DMetal not engaged
                    Logs: ~/Library/Logs/com.fly.gaming/
                    """)
                } else {
                    print("""

                    Tip: wyn play restarts Wine Steam then -applaunch (so DXMT env sticks).
                    In Ride.log, adapter should be Apple/M-series — NOT "NVIDIA GeForce 6800"
                    (that means Wine-builtin d3d11; overrides did not apply).
                    Look for loaddll lines with d3d11.dll "...: native".
                    Logs: ~/Library/Logs/com.fly.gaming/
                    """)
                }
            }
        }
    }
}

// MARK: - Doctor

extension WynCLI {
    struct Doctor: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Dump god-level diagnostics for WynWine, bottles, and graphics DLLs."
        )

        @Option(name: .long, help: "Bottle name to inspect (default: Steam).")
        var bottle: String = SteamLauncher.defaultBottleName

        @Option(name: .long, help: "Optional profile id to include in the report.")
        var profile: String?

        mutating func run() throws {
            guard WynWineInstaller.isWynWineInstalled() else {
                print("WynWine is NOT installed. Run: wyn install")
                return
            }

            var data = BottleData()
            let bottles = data.loadBottles()

            print("Registered bottles: \(bottles.count)")
            for b in bottles {
                let effective = LaunchDiagnostics.effectiveLayer(for: b)
                print("  - \(b.settings.name): layer=\(b.settings.translationLayer.rawValue) dxvk=\(b.settings.dxvk) effective=\(effective.layer.rawValue)")
            }
            print("")

            guard let target = bottles.first(where: { $0.settings.name == bottle }) else {
                throw ValidationError("No bottle named \"\(bottle)\".")
            }

            let matched = profile.flatMap { ProfileStore.profile(id: $0) }
            var environment: [String: String] = [:]
            var exe: URL?
            if let matched {
                ProfileApplicator.apply(profile: matched, to: target)
                if let appId = matched.steamAppId {
                    exe = SteamLauncher.findGameExecutable(forAppId: appId, in: target, profile: matched)
                }
                if let exe {
                    let program = Program(url: exe, bottle: target)
                    environment = ProfileApplicator.launchEnvironment(profile: matched, program: program)
                }
            }

            let report = LaunchDiagnostics.inspect(
                bottle: target,
                profile: matched,
                executable: exe,
                environment: environment,
                phase: "doctor"
            )
            print(report.rendered)

            LaunchDiagnostics.printAuthSignal(
                bottle: target,
                profile: matched,
                layer: matched?.bottle?.translationLayer ?? target.settings.translationLayer,
                phase: "doctor"
            )

            print("Recent logs (~/Library/Logs/com.fly.gaming/):")
            if let logs = try? FileManager.default.contentsOfDirectory(
                at: Wine.logsFolder, includingPropertiesForKeys: [.contentModificationDateKey]
            ).sorted(by: {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }).prefix(5) {
                for log in logs {
                    print("  \(log.lastPathComponent)")
                }
            } else {
                print("  (none)")
            }
        }
    }
}

// MARK: - Steam

extension WynCLI {
    struct Steam: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Install and launch the Steam client.",
            subcommands: [SteamInstall.self, SteamLaunch.self]
        )
    }

    struct SteamInstall: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "install",
            abstract: "Download SteamSetup.exe; msiexec /qn Wine Mono, then run the wizard."
        )

        mutating func run() async throws {
            guard WynWineInstaller.isWynWineInstalled() else {
                throw ValidationError("WynWine not installed. Run: wyn install")
            }

            let bottle = try SteamLauncher.ensureSteamBottle()

            if SteamLauncher.isSteamInstalled(in: bottle) {
                print("Steam is already installed. Launch with: wyn steam launch")
                return
            }

            print("Wine Mono: msiexec /qn (no installer window), then Steam setup.")
            print("Downloading Steam installer...")
            let installer = try await SteamLauncher.downloadInstaller()
            print("Starting Steam setup wizard (follow the on-screen prompts)...")
            print("Install to the default location: C:\\Program Files (x86)\\Steam\n")

            try await SteamLauncher.runSteamInstaller(in: bottle, installer: installer)

            if SteamLauncher.isSteamInstalled(in: bottle) {
                print("\nSteam installed. Launch with: wyn steam launch")
            } else {
                print("\nIf setup finished, launch with: wyn steam launch")
                print("If the wizard did not appear, try: wyn run Steam \"\(installer.path)\"")
            }
        }
    }

    struct SteamLaunch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "launch",
            abstract: "Open the Steam client in the Steam bottle (game-host Libraries/ by default)."
        )

        @Flag(name: .long, help: "Stream Wine output (useful when Steam fails to open).")
        var debug: Bool = false

        @Flag(name: .long, help: "Steam on game-host Wine (Libraries/ — default after P0-c).")
        var gptkSteam: Bool = false

        @Flag(name: .long, help: "Rollback: frankea Steam UI (Libraries.steam).")
        var frankeaSteam: Bool = false

        mutating func run() async throws {
            guard WynWineInstaller.isWynWineInstalled() else {
                throw ValidationError("WynWine not installed. Run: wyn install")
            }

            let bottle = try SteamLauncher.ensureSteamBottle()

            guard SteamLauncher.isSteamInstalled(in: bottle) else {
                throw ValidationError("Steam not installed. Run: wyn steam install")
            }

            var options = Wine.LaunchOptions(debug: debug, echoOutput: debug)
            // Default: game host (FOSS winecx). --frankea-steam rolls back; --gptk-steam pins game host.
            let fossWine = !GPTKInstaller.isWineGPTKAware()
            options.preferFrankeaSteam = (frankeaSteam || fossWine) && !gptkSteam
            options.preferGPTKSteam = !options.preferFrankeaSteam
            if options.preferFrankeaSteam {
                options.wineTree = .steam
                print("Launching Windows Steam on frankea Wine (DXMT/DXVK)…")
            } else {
                options.wineTree = .game
                print("Launching Windows Steam on game-host Wine (Libraries/ — FOSS winecx + D3DMetal)…")
            }
            print("Log in here and check Remember me. Press Play in Steam — that should start the game.")
            print("wyn play <game> is fallback if Play hits a launcher/picker instead of the game EXE.")
            print("(If the window is blank, quit and run again. Use --debug if it exits instantly.)\n")
            try await SteamLauncher.launchSteam(in: bottle, options: options)
        }
    }
}

// MARK: - Runtime

extension WynCLI {
    struct Runtime: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Manage the WynWine runtime (Wine + GPTK + DXVK).",
            subcommands: [RuntimeStatus.self, RuntimeInstall.self]
        )
    }

    struct RuntimeStatus: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Show installed runtime information."
        )

        mutating func run() throws {
            let status = RuntimeManager.status()

            print("Installed:  \(status.installed ? "yes" : "no")")
            print("Source:     \(status.source.displayName)")
            if let version = status.version {
                print("Version:    \(version.major).\(version.minor).\(version.patch)")
            }
            print("Wine binary: \(status.wineBinary.path(percentEncoded: false))")
            print("GPTK aware:  \(GPTKInstaller.isWineGPTKAware() ? "yes (FOSS winecx + CX_APPLEGPTK)" : "no")")
            print("GPTK files:  \(GPTKInstaller.isInstalled() ? "yes (external/)" : "not installed")")
            print("GPTK stubs:  \(GPTKInstaller.isWineModulesWired() ? "wired" : "not wired")")
            let steamOK = WynWineInstaller.isSteamWineInstalled()
            print("Steam Wine:  \(steamOK ? "yes (frankea fallback) — \(WynWineInstaller.steamLibraryFolder.path)" : "no frankea fallback (optional; one-Wine uses Libraries/)")")
            print("")
            print(GameHostIdentity.inspect().rendered)
        }
    }

    struct RuntimeInstall: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "install",
            abstract: "Install the WynWine runtime."
        )

        @Option(name: .long, help: "Install from a local Libraries.tar.gz (frankea FOSS path only).")
        var from: String?

        @Option(name: .long, help: "Local FOSS winecx prefix, Wine root, or Libraries directory. Proprietary Wine.app bundles are refused.")
        var directory: String?

        @Flag(name: .long, help: "Download from community WhiskyWine host (DXMT/DXVK; no D3DMetal).")
        var whisky: Bool = false

        @Flag(name: .long, help: "Install user-built FOSS winecx as the D3DMetal game-host. Does not download Wine.")
        var gptkAware: Bool = false

        @Flag(name: .long, help: "With --gptk-aware, symlink the winecx tree instead of copying.")
        var link: Bool = false

        @Flag(name: .long, help: "Sanity-check Libraries/Wine identity (FOSS winecx vs proprietary loader vs Whisky). No copy.")
        var check: Bool = false

        mutating func run() async throws {
            if whisky && gptkAware {
                throw ValidationError("--whisky is frankea DXMT/DXVK; --gptk-aware is FOSS winecx game-host. Not both.")
            }

            if check {
                let report = GameHostIdentity.inspect()
                print(report.rendered)
                try GameHostIdentity.assertGameHost()
                print("Game-host identity ok. Next: wyn gptk install --from /path/to/Apple/GPTK/redist")
                return
            }

            if gptkAware {
                if let path = from {
                    throw ValidationError("""
                    --gptk-aware does not unpack tarballs (they may contain Apple GPTK or Whisky Wine).
                    Build FOSS winecx, then:
                      wyn runtime install --gptk-aware --directory <wine-root>
                    Refused path: \(path)
                    """)
                }
                guard let dir = directory else {
                    throw ValidationError(GameHostIdentity.howToObtain)
                }
                print("Installing FOSS winecx game-host from \(dir)\(link ? " (link)" : "")…")
                try GameHostIdentity.install(from: URL(fileURLWithPath: dir), link: link)
                RuntimeManager.activeSource = .gptkAware
                print("Staging Wine Mono MSI for winecx (WineHQ; msiexec /qn at wyn steam install)…")
                try await WineMono.ensureDatadirPackage()
                print(GameHostIdentity.inspect().rendered)
                print("FOSS GPTK game-host installed. Next: wyn gptk install --from /path/to/Apple/GPTK/redist")
                return
            }

            if let path = from {
                let url = URL(fileURLWithPath: path)
                try WynWineInstaller.install(from: url)
                print("Installed WynWine from \(path)")
                printGPTKHint()
                return
            }

            if let dir = directory {
                try WynWineInstaller.installFromDirectory(URL(fileURLWithPath: dir))
                print("Installed WynWine from directory \(dir)")
                printGPTKHint()
                return
            }

            // Default: hash-pinned community WhiskyWine (frankea DXMT/DXVK rollback).
            RuntimeManager.activeSource = .whiskyCDN
            let pin = RuntimeIntegrity.whiskyCDN
            print("Downloading WynWine \(pin.version) (hash-pinned frankea; not the D3DMetal game-host)…")
            print("  \(pin.url.absoluteString)")
            let tarball = try await downloadFile(from: pin.url)
            try WynWineInstaller.install(from: tarball, expectedSHA256: pin.sha256)
            print("WynWine installed successfully (DXMT/DXVK).")
            printGPTKHint()
        }

        private func printGPTKHint() {
            if GPTKInstaller.isWineGPTKAware() {
                print("Wine is FOSS GPTK-aware. Next: wyn gptk install --from /path/to/redist")
            } else {
                print("Wine is not the D3DMetal game-host (DXMT/DXVK only).")
                print("For D3DMetal: ./scripts/build-foss-game-host.sh then wyn runtime install --gptk-aware --directory <wine-root>")
            }
        }

        private func downloadFile(from url: URL) async throws -> URL {
            let (tempURL, _) = try await URLSession.shared.download(from: url)
            let dest = FileManager.default.temporaryDirectory
                .appending(path: "WynWine-\(UUID().uuidString).tar.gz")
            try FileManager.default.moveItem(at: tempURL, to: dest)
            return dest
        }
    }
}

// MARK: - GPTK (Apple D3DMetal — local install only)

extension WynCLI {
    struct GPTK: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "gptk",
            abstract: "Install Apple GPTK/D3DMetal into WynWine (from a local redist; never downloaded by Wyn).",
            subcommands: [GPTKStatus.self, GPTKInstall.self],
            defaultSubcommand: GPTKStatus.self
        )
    }

    struct GPTKStatus: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Show whether D3DMetal is wired into WynWine."
        )

        mutating func run() throws {
            print("WynWine installed: \(WynWineInstaller.isWynWineInstalled() ? "yes" : "no")")
            print("Wine GPTK-aware:   \(GPTKInstaller.isWineGPTKAware() ? "yes (FOSS winecx + CX_APPLEGPTK)" : "no")")
            print("GPTK files:        \(GPTKInstaller.isInstalled() ? "yes (external/)" : "no")")
            if let ver = GPTKInstaller.installedD3DMetalVersion() {
                print("D3DMetal version:  \(ver)")
            }
            print("Wine GPTK stubs:   \(GPTKInstaller.isWineModulesWired() ? "yes" : "no")")
            print("MetalFX/nvngx:     \(GPTKInstaller.isMetalFXWired() ? "yes (nvngx + nvapi64)" : "no — re-run wyn gptk install")")
            if GPTKInstaller.isMetalFXWired() {
                print("nvngx.dll:         \(GPTKInstaller.nvngxDLLURL.path(percentEncoded: false))")
            }
            print("external/:         \(GPTKInstaller.externalFolder.path(percentEncoded: false))")
            if let src = GPTKInstaller.findLocalSource() {
                let fw = src.appending(path: "external").appending(path: "D3DMetal.framework")
                let srcVer = GPTKInstaller.versionFromFramework(at: fw).map { " (D3DMetal \($0))" } ?? ""
                print("Auto-detect src:   \(src.path(percentEncoded: false))\(srcVer)")
            } else {
                print("Auto-detect src:   (none — pass --from)")
            }
            if !GPTKInstaller.isWineGPTKAware() {
                print("""
                Note: current Wine cannot load D3DMetal. Build FOSS winecx:
                  ./scripts/build-foss-game-host.sh
                  wyn runtime install --gptk-aware --directory <wine-root>
                Then: wyn gptk install --from /path/to/redist
                """)
            } else if !GPTKInstaller.isInstalled() {
                print("Next: wyn gptk install --from /path/to/redist")
            } else if !GPTKInstaller.isWineModulesWired() {
                print("Next: wyn gptk install --from /path/to/redist  (will wire PE/unix stubs on this GPTK-aware Wine)")
            } else if !GPTKInstaller.isMetalFXWired() {
                print("Next: wyn gptk install --from /path/to/redist  (will wire MetalFX nvngx/nvapi64)")
            } else {
                print("Ready for translationLayer=d3dmetal profiles (D3DMetal + MetalFX).")
            }
        }
    }

    struct GPTKInstall: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "install",
            abstract: "Copy a local GPTK redist into WynWine lib/external (D3DMetal.framework + libd3dshared)."
        )

        @Option(name: .long, help: "Path to a local GPTK redist (required). Wyn never downloads Apple GPTK.")
        var from: String

        mutating func run() throws {
            guard WynWineInstaller.isWynWineInstalled() else {
                throw ValidationError("WynWine not installed. Run: wyn install")
            }
            let source = URL(fileURLWithPath: from)
            let installed = try GPTKInstaller.install(from: source)
            print("GPTK/D3DMetal files → \(installed.path(percentEncoded: false))")
            if let ver = GPTKInstaller.installedD3DMetalVersion() {
                print("D3DMetal version: \(ver)")
            }
            if GPTKInstaller.isWineModulesWired() {
                if GPTKInstaller.isWineGPTKAware() {
                    print("Wine PE/unix stubs overlaid (GPTK-aware Wine).")
                } else {
                    print("FLY_GPTK_WIRE_WINE=1 — stubs overlaid on non-aware Wine (may break Steam).")
                }
                print("MetalFX/nvngx: \(GPTKInstaller.isMetalFXWired() ? "wired" : "MISSING (redist may lack nvngx-on-metalfx)")")
            } else {
                print("Wine stubs not overlaid. Need FOSS winecx: wyn runtime install --gptk-aware --directory <wine-root>")
            }
        }
    }
}
