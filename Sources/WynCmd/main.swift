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
            GPTK.self,
            Renderer.self,
            MCP.self
        ]
    )
}

// MARK: - MCP

extension WynCLI {
    /// Wyn as an MCP server, so the person's own Claude can add games.
    ///
    /// Server, not client: no API key lives in Wyn, no model call costs the
    /// project anything, and there is no LLM in the binary. Whoever is talking
    /// to it brings their own.
    struct MCP: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "mcp",
            abstract: "Run Wyn as an MCP server over stdio (for Claude Desktop / Claude Code).",
            discussion: """
            Point an MCP client at this command. For Claude Desktop, in \
            claude_desktop_config.json:

              {
                "mcpServers": {
                  "wyn": { "command": "/usr/local/bin/wyn", "args": ["mcp"] }
                }
              }

            For Claude Code: claude mcp add wyn -- /usr/local/bin/wyn mcp

            It speaks JSON-RPC on stdin/stdout and logs to stderr, so running it \
            in a terminal looks like it has hung. That is correct: it is waiting \
            for a client.
            """
        )

        mutating func run() throws {
            MCPServer().run()
        }
    }
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
            // Shared with the app's New Bottle tile so the two cannot drift.
            let bottle = try BottleFactory.create(
                name: name,
                windows: windows,
                graphics: graphics
            )
            print("Created bottle \"\(bottle.settings.name)\" at \(bottle.url.prettyPath())")
            print("The Wine prefix is set up the first time something runs in it.")
        }
    }

    struct Delete: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a bottle from disk.")

        @Argument var name: String

        @Flag(name: .long, help: "Remove from registry only, keep files on disk.")
        var keepFiles: Bool = false

        @Flag(name: [.customLong("yes"), .customShort("y")],
              help: "Delete without asking. Required when stdin is not a terminal.")
        var assumeYes: Bool = false

        mutating func run() throws {
            var data = BottleData()
            let bottles = data.loadBottles()

            // Case-insensitive, to match bottle creation: `wyn create` refuses a
            // name that differs only in case, so `wyn delete` must find it.
            guard let bottle = bottles.first(where: {
                $0.settings.name.lowercased() == name.lowercased()
            }) else {
                throw ValidationError("No bottle named \"\(name)\".")
            }
            let actualName = bottle.settings.name

            // Deleting a prefix out from under a live wineserver corrupts the
            // session rather than ending it.
            if SteamLauncher.isBottleWineserverRunning(in: bottle) {
                throw ValidationError("""
                "\(actualName)" is running. Quit what is using it first \
                (Steam → Exit, or: wyn steam quit), then delete.
                """)
            }

            if !keepFiles {
                let size = Delete.humanSize(of: bottle.url)
                print("Deleting \"\(actualName)\" removes \(bottle.url.prettyPath())")
                if let size {
                    // Games live inside the bottle. 28 GB of installs is an easy
                    // thing to destroy with a one-word command and no warning.
                    print("This is \(size) on disk, including anything installed in it.")
                }

                if !assumeYes {
                    guard isatty(FileHandle.standardInput.fileDescriptor) == 1 else {
                        throw ValidationError("""
                        Refusing to delete without confirmation. Re-run with --yes, \
                        or --keep-files to unregister the bottle and keep the files.
                        """)
                    }
                    print("Type the bottle name to confirm: ", terminator: "")
                    let typed = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard typed.lowercased() == actualName.lowercased() else {
                        print("Not deleted.")
                        return
                    }
                }
            }

            // Files first, registry second. The old order deregistered before
            // deleting, so a failed removeItem left the directory orphaned:
            // gone from `wyn list`, still occupying the disk, with nothing left
            // pointing at it. StoreInstaller.reset already does it this way.
            if !keepFiles {
                try FileManager.default.removeItem(at: bottle.url)
            }
            data.paths.removeAll { $0 == bottle.url }

            print(keepFiles
                  ? "Removed \"\(actualName)\" from the registry. Files kept at \(bottle.url.prettyPath())"
                  : "Deleted \"\(actualName)\".")
        }

        /// `du -sh` for the bottle, or nil when it cannot be measured.
        /// Best effort: never block a delete because sizing failed.
        private static func humanSize(of url: URL) -> String? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
            process.arguments = ["-sh", url.path(percentEncoded: false)]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(decoding: data, as: UTF8.self)
                .split(separator: "\t").first
                .map { $0.trimmingCharacters(in: .whitespaces) }
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
            subcommands: [
                ProfilesList.self, ProfilesShow.self, ProfilesApply.self, ProfilesEvidence.self,
                ProfilesPerformance.self
            ]
        )
    }

    /// What the last session actually did, from the game's own log.
    ///
    /// Separate from `evidence` on purpose: evidence says a game ran, this says
    /// how it ran and — the part nothing else can answer — which translation
    /// layer it really got.
    struct ProfilesPerformance: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "performance",
            abstract: "Which layer actually ran, and how fast, from the game's own log."
        )

        @Argument(help: "Profile id, e.g. \"solarpunk\".") var id: String

        mutating func run() throws {
            guard let profile = ProfileStore.profile(id: id) else {
                throw ValidationError("Unknown profile \"\(id)\". Run: wyn profiles list")
            }
            guard let bottle = GameLibrary.steamBottle() else {
                throw ValidationError("No Steam bottle. Run: wyn install")
            }
            print(SessionPerformance.report(profile: profile, in: bottle))
        }
    }

    /// What this machine has actually run, and which profiles that vouches for.
    ///
    /// Wyn ships 120 profiles and exactly one was ever measured. Everything
    /// else is inference until somebody's machine says otherwise, and this is
    /// where that shows up.
    struct ProfilesEvidence: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "evidence",
            abstract: "Show launch evidence recorded on this machine."
        )

        @Flag(name: .long, help: "List every profile, including ones with no evidence.")
        var all: Bool = false

        mutating func run() throws {
            let records = LaunchRecordStore.load()
            let profiles = ProfileStore.loadAll()

            print("Launch records: \(records.count)")
            print("Stored at: \(LaunchRecordStore.fileURL.path(percentEncoded: false))")
            print("")

            var counts: [ProfileStatus: Int] = [:]
            for profile in profiles.sorted(by: { $0.id < $1.id }) {
                let status = LaunchRecordStore.effectiveStatus(for: profile, in: records)
                counts[status, default: 0] += 1
                guard all || status != .guessed else { continue }
                let evidence = LaunchRecordStore.evidence(for: profile, in: records)
                let detail = evidence.isEmpty
                    ? ""
                    : "  (\(evidence.count) run(s), longest "
                        + String(format: "%.0f", (evidence.map(\.ranForSeconds).max() ?? 0) / 60)
                        + " min)"
                print("  \(status.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) \(profile.id)\(detail)")
            }

            print("")
            for status in ProfileStatus.allCases {
                print("  \(status.rawValue): \(counts[status] ?? 0)")
            }
            if (counts[.launched] ?? 0) == 0, (counts[.verified] ?? 0) <= 1 {
                print("")
                print("Play something for a minute and it will show up here.")
            }
        }
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

            // The layer decides the launch mechanism as well as the graphics,
            // and that half of it used to be invisible until something broke.
            let steamBottle = GameLibrary.steamBottle()
            let layer = profile.bottle?.translationLayer
                ?? steamBottle?.settings.translationLayer
            if let layer {
                print("Graphics:   \(layer.displayName)")
                print("Launch:     \(LaunchPath.forLayer(layer).shortLabel)")
            }
            if !profile.environment.isEmpty {
                print("Environment:")
                for (key, value) in profile.environment.sorted(by: { $0.key < $1.key }) {
                    print("  \(key)=\(value)")
                }
            }
            if !profile.winetricks.isEmpty {
                // Listing the verbs alone reads as "Wyn installed these". It
                // never did. Say what is actually in the bottle.
                print("Runtimes:")
                if let steamBottle {
                    for requirement in WindowsRuntimes.check(profile: profile, in: steamBottle) {
                        print("  \(requirement.summary)")
                    }
                } else {
                    for verb in profile.winetricks {
                        print("  \(verb): not checked — no Steam bottle yet")
                    }
                }
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

        // Without this there is no way to run a game in any bottle but "Steam",
        // so a second bottle made to test another translation layer cannot be
        // played from the CLI at all — the reason the 5 Sep DXMT attempt had to
        // go through Steam's own Play button and silently measured D3DMetal.
        @Option(name: .customLong("bottle"), help: "Bottle to play in (default: Steam).")
        var bottleName: String = SteamLauncher.defaultBottleName

        mutating func run() async throws {
            guard let profile = ProfileStore.profile(id: profileId) else {
                throw ValidationError("Unknown profile \"\(profileId)\". Run: wyn profiles list")
            }

            guard WynWineInstaller.isWynWineInstalled() else {
                throw ValidationError("WynWine not installed. Run: wyn install")
            }

            var data = BottleData()
            guard let bottle = data.loadBottles().first(where: { $0.settings.name == bottleName }) else {
                if bottleName == SteamLauncher.defaultBottleName {
                    throw ValidationError("No Steam bottle. Run: wyn install")
                }
                throw ValidationError("No bottle named \"\(bottleName)\". Run: wyn list")
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
            // Same honesty as `steam launch`: the tree decides the layer. A
            // dxmt profile played on the game-host tree renders through
            // D3DMetal, and the numbers that come back are not evidence about
            // dxmt.
            if let notice = DeclaredLayerNotice.message(
                declared: layer,
                tree: frankeaSteam ? .frankea : .gameHost
            ) {
                print(notice)
            }
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

            // The layer the profile names is not the layer the game gets if a
            // wineserver from another tree is already up. Measured: a two-hour
            // session ran on DXVK under a d3dmetal profile, and the only trace
            // was one adapter line in the game's own log.
            if let mismatch = LayerReality.mismatch(profile: profile, in: bottle) {
                print("""

                ⚠︎  WRONG TRANSLATION LAYER
                \(mismatch.summary)
                \(mismatch.remedy)
                \(mismatch.howToVerify)
                Launching anyway — this is a warning, not a block.
                """)
            }

            // A warning, never a block: this is a registry heuristic, and
            // refusing to launch on it would be worse than the old silence.
            // Printed before the game starts so it is above the log spew.
            let missingRuntimes = WindowsRuntimes.missing(profile: profile, in: bottle)
            if !missingRuntimes.isEmpty {
                print("""

                Warning: \(profile.name) declares runtimes this bottle does not have:
                \(missingRuntimes.map { "  \($0.displayName) (\($0.verb))" }.joined(separator: "\n"))
                Wyn does not install these — Steam's own prerequisite installer does,
                when the game is installed. Launching anyway.
                """)
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

        @Flag(name: .long, help: "Write a zip to the Desktop instead of printing — send this when reporting a bug.")
        var bundle: Bool = false

        @Option(name: .long, help: "One line describing what went wrong, included in the bundle.")
        var note: String?

        mutating func run() throws {
            var data = BottleData()

            // The bundle has to work on exactly the machines that are broken,
            // so it must not require a healthy install to be produced. A
            // missing WynWine is itself the most useful thing it can report.
            if bundle {
                let registered = data.loadBottles()
                let target = registered.first { $0.settings.name == bottle } ?? registered.first
                let result = try DiagnosticsBundle.create(bottle: target, note: note)
                print("Diagnostics bundle written:")
                print("  \(result.url.path(percentEncoded: false))")
                print("  \(result.fileCount) file(s), \(result.readableSize)")
                print("")
                print("Send that zip. It has no account details in it — Steam's")
                print("config/ is never read, and SteamIDs, e-mail addresses,")
                print("your home path and user name are scrubbed. Open it and")
                print("look if you like; README.txt says exactly what is inside.")
                return
            }

            guard WynWineInstaller.isWynWineInstalled() else {
                print("WynWine is NOT installed. Run: wyn install")
                print("(To report this, run: wyn doctor --bundle)")
                return
            }

            let bottles = data.loadBottles()

            print("Registered bottles: \(bottles.count)")
            let renderer = RendererWiring.inspect()
            print("Shared renderer: \(renderer.statusLines[0])")
            for b in bottles {
                let effective = LaunchDiagnostics.effectiveLayer(for: b)
                print("  - \(b.settings.name): layer=\(b.settings.translationLayer.rawValue) dxvk=\(b.settings.dxvk) effective=\(effective.layer.rawValue)")
                if effective.reason.contains("but Libraries") {
                    print("      \(effective.reason)")
                }
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
            subcommands: [SteamInstall.self, SteamLaunch.self, SteamQuit.self]
        )
    }

    struct SteamInstall: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "install",
            abstract: "Download SteamSetup.exe; silent install, then open Steam (CEF-shimmed)."
        )

        @Option(name: .long, help: "Bottle to install into (default: Steam). Must already exist unless this is Steam.")
        var bottle: String = SteamLauncher.defaultBottleName

        @Flag(name: .long, help: "Stream Wine output.")
        var debug: Bool = false

        mutating func run() async throws {
            guard WynWineInstaller.isWynWineInstalled() else {
                throw ValidationError("WynWine not installed. Run: wyn install")
            }

            let target = try Self.resolveBottle(named: bottle)

            if SteamLauncher.isSteamInstalled(in: target) {
                print("Steam is already installed in \"\(bottle)\". Launch with: wyn steam launch --bottle \"\(bottle)\"")
                return
            }

            print("Wine Mono: msiexec /qn (no installer window), then silent SteamSetup.")
            print("Downloading Steam installer...")
            let installer = try await SteamLauncher.downloadInstaller()
            print("Installing Steam to C:\\Program Files (x86)\\Steam in bottle \"\(bottle)\" (unattended)…\n")

            try await SteamLauncher.runSteamInstaller(in: target, installer: installer)

            guard SteamLauncher.isSteamInstalled(in: target) else {
                throw ValidationError(
                    "SteamSetup finished without steam.exe. Re-run: wyn steam install --bottle \"\(bottle)\""
                )
            }

            print("Steam installed. Opening the client…")
            var options = Wine.LaunchOptions(debug: debug, echoOutput: debug)
            let fossWine = !GPTKInstaller.isWineGPTKAware()
            options.preferFrankeaSteam = fossWine
            options.preferGPTKSteam = !fossWine
            try await SteamLauncher.launchSteam(in: target, options: options)
        }

        /// `createIfMissing: false` for read-only commands. `ensureSteamBottle()`
        /// creates and *registers* a bottle when none is named "Steam" — fine
        /// for `steam install`, wrong for a query like `steam quit`, which
        /// would leave a stray empty bottle behind and then report that Steam
        /// is not running. That is very likely where unexplained empty bottles
        /// come from.
        static func resolveBottle(named name: String, createIfMissing: Bool = true) throws -> Bottle {
            if name == SteamLauncher.defaultBottleName {
                guard createIfMissing else {
                    var data = BottleData()
                    guard let found = data.loadBottles()
                        .first(where: { $0.settings.name == name })
                    else {
                        throw ValidationError(
                            "No bottle named \"\(name)\" yet. Create one with: wyn steam install"
                        )
                    }
                    return found
                }
                return try SteamLauncher.ensureSteamBottle()
            }
            var data = BottleData()
            guard let found = data.loadBottles().first(where: { $0.settings.name == name }) else {
                throw ValidationError("No bottle named \"\(name)\". Create with: wyn create \"\(name)\"")
            }
            return found
        }
    }

    struct SteamLaunch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "launch",
            abstract: "Open the Steam client in the Steam bottle (game-host Libraries/ by default)."
        )

        @Option(name: .long, help: "Bottle to launch (default: Steam).")
        var bottle: String = SteamLauncher.defaultBottleName

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

            let target = try SteamInstall.resolveBottle(named: bottle)

            guard SteamLauncher.isSteamInstalled(in: target) else {
                throw ValidationError("Steam not installed. Run: wyn steam install --bottle \"\(bottle)\"")
            }

            var options = Wine.LaunchOptions(debug: debug, echoOutput: debug)
            // Default: game host (FOSS winecx). --frankea-steam rolls back; --gptk-steam pins game host.
            let fossWine = !GPTKInstaller.isWineGPTKAware()
            options.preferFrankeaSteam = (frankeaSteam || fossWine) && !gptkSteam
            options.preferGPTKSteam = !options.preferFrankeaSteam
            let tree: DeclaredLayerNotice.Tree
            if options.preferFrankeaSteam {
                options.wineTree = .steam
                tree = .frankea
                print("Launching Windows Steam on frankea Wine (DXMT/DXVK)…")
            } else {
                options.wineTree = .game
                tree = .gameHost
                print("Launching Windows Steam on game-host Wine (Libraries/ — FOSS winecx + D3DMetal)…")
            }
            // The tree decides the layer, not the bottle. Say so when they
            // disagree — a Steam-DXMT bottle launched here gets D3DMetal, and
            // anything started from this client inherits it.
            if let notice = DeclaredLayerNotice.message(
                declared: target.settings.translationLayer, tree: tree
            ) {
                print(notice)
            }
            print("Log in here and check Remember me. Press Play in Steam — that should start the game.")
            print("wyn play <game> is fallback if Play hits a launcher/picker instead of the game EXE.\n")
            try await SteamLauncher.launchSteam(in: target, options: options)
        }
    }

    struct SteamQuit: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "quit",
            abstract: "Exit the Steam client the way Steam's own Exit does (never wineserver -k)."
        )

        @Option(name: .long, help: "Bottle to quit Steam in (default: Steam).")
        var bottle: String = SteamLauncher.defaultBottleName

        @Flag(name: .long, help: "Quit Steam even while a game is running (the game keeps running).")
        var evenWhilePlaying: Bool = false

        mutating func run() async throws {
            guard WynWineInstaller.isWynWineInstalled() else {
                throw ValidationError("WynWine not installed. Run: wyn install")
            }
            let target = try SteamInstall.resolveBottle(named: bottle, createIfMissing: false)

            guard SteamLauncher.isSteamClientRunning(in: target) else {
                print("Steam is not running.")
                return
            }

            // Quitting Steam does not close a game, so warn rather than
            // surprise someone mid-session. Wyn never force-closes a game:
            // unsaved progress, and a killed D3DMetal session makes the next
            // launch crash.
            let playing = SteamLauncher.runningGameNames(among: ProfileStore.loadAll())
            if !playing.isEmpty && !evenWhilePlaying {
                throw ValidationError("""
                \(playing.joined(separator: ", ")) is still running.
                Quit the game from its own window first, then: wyn steam quit
                To close Steam anyway and leave the game running: wyn steam quit --even-while-playing
                """)
            }

            if try await SteamLauncher.quitSteam(in: target) {
                print("Steam exited.")
            } else {
                print("Steam did not exit. Use Steam → Exit from its own window.")
                throw ExitCode.failure
            }
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
            print("Renderer:    \(RendererWiring.inspect().statusLines[0])")
            print("GPTK stubs:  \(GPTKInstaller.isWineModulesWired() ? "D3DMetal selected" : "not selected (DXMT/Wine unix)")")
            // Which tree is live right now, not just which is installed. This
            // is the difference between "D3DMetal is available" and "D3DMetal
            // is what the next game will actually get".
            if let steamBottle = GameLibrary.steamBottle() {
                if let running = LayerReality.runningTree(in: steamBottle) {
                    print("Live tree:   \(running.displayName)"
                          + (running == .game ? "" : "  ← D3DMetal not available in this tree"))
                } else {
                    print("Live tree:   nothing running — next launch picks it")
                }
            }
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
                print("Game-host identity ok. Next: wyn gptk install  # GPTK 3.0 from ~/Downloads")
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
                print("FOSS GPTK game-host installed. Next: wyn gptk install  # GPTK 3.0 from ~/Downloads")
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
                print("Wine is FOSS GPTK-aware. Next: wyn gptk install  # GPTK 3.0 from ~/Downloads")
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
            abstract: "Show whether GPTK files are installed (availability, not selection)."
        )

        mutating func run() throws {
            print("WynWine installed: \(WynWineInstaller.isWynWineInstalled() ? "yes" : "no")")
            print("Wine GPTK-aware:   \(GPTKInstaller.isWineGPTKAware() ? "yes (FOSS winecx + CX_APPLEGPTK)" : "no")")
            print("GPTK files:        \(GPTKInstaller.isInstalled() ? "yes (external/)" : "no")")
            if let ver = GPTKInstaller.installedD3DMetalVersion() {
                print("D3DMetal version:  \(ver)")
            }
            print("Wine GPTK stubs:   \(GPTKInstaller.isWineModulesWired() ? "yes (D3DMetal selected)" : "no (not selected)")")
            print("MetalFX/nvngx:     \(GPTKInstaller.isMetalFXWired() ? "yes (nvngx + nvapi64)" : "no — re-run wyn gptk install")")
            if GPTKInstaller.isMetalFXWired() {
                print("nvngx.dll:         \(GPTKInstaller.nvngxDLLURL.path(percentEncoded: false))")
            }
            print("external/:         \(GPTKInstaller.externalFolder.path(percentEncoded: false))")
            if let dl = GPTKInstaller.preferredDownloadsCandidate() {
                print("Downloads 3.0:     \(dl.path(percentEncoded: false))")
            } else {
                print("Downloads 3.0:     (none — put \(GPTKInstaller.downloadsFileName) in ~/Downloads, or: wyn gptk install --pick)")
            }
            if let remembered = GPTKSourcePicker.rememberedFolder {
                let hit = GPTKSourcePicker.rememberedCandidate()
                    .map { " → \($0.lastPathComponent)" } ?? " (no GPTK there now)"
                print("Remembered src:    \(remembered.path(percentEncoded: false))\(hit)")
            }
            let renderer = RendererWiring.inspect()
            for line in renderer.statusLines {
                print("Renderer:          \(line)")
            }
            if let src = GPTKInstaller.findLocalSource() {
                let fw = src.appending(path: "external").appending(path: "D3DMetal.framework")
                let srcVer = GPTKInstaller.versionFromFramework(at: fw).map { " (D3DMetal \($0))" } ?? ""
                print("Auto-detect src:   \(src.path(percentEncoded: false))\(srcVer)")
            } else {
                print("Auto-detect src:   (none — wyn gptk install uses ~/Downloads)")
            }
            if !GPTKInstaller.isWineGPTKAware() {
                print("""
                Note: current Wine cannot load D3DMetal. Build FOSS winecx:
                  ./scripts/build-foss-game-host.sh
                  wyn runtime install --gptk-aware --directory <wine-root>
                Then: wyn gptk install
                """)
            } else if !GPTKInstaller.isInstalled() {
                print("Next: wyn gptk install")
            } else if !GPTKInstaller.isMetalFXWired() {
                print("Next: wyn gptk install  (will overlay MetalFX nvngx/nvapi64)")
            } else if renderer.backend != .d3dMetal {
                print("GPTK is installed. DXMT remains the selected renderer.")
                print("D3D12-only titles need D3DMetal: wyn renderer set d3dmetal")
            } else {
                print("D3DMetal is selected. Switch back with: wyn renderer set dxmt")
            }
        }
    }

    struct GPTKInstall: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "install",
            abstract: "Copy local GPTK 3.0 into WynWine lib/external. Default: ~/Downloads/Game_Porting_Toolkit_3.0.dmg."
        )

        @Option(
            name: .long,
            help: "Path to a GPTK redist or DMG. Default: Game Porting Toolkit 3.0 in ~/Downloads. Wyn never downloads Apple GPTK."
        )
        var from: String?

        @Flag(name: .long, help: "Browse for the GPTK file in Finder instead of auto-detecting.")
        var pick: Bool = false

        @Flag(name: .long, help: "Never open Finder; fail with instructions instead. For scripts and CI.")
        var noPrompt: Bool = false

        @Flag(name: .long, help: "Forget the remembered GPTK folder and exit. Auto-detect goes back to ~/Downloads.")
        var forgetSource: Bool = false

        mutating func run() throws {
            // Maintenance flag: clearing remembered state and installing in one
            // command would be ambiguous about which source the install used.
            if forgetSource {
                let had = GPTKSourcePicker.rememberedFolder
                GPTKSourcePicker.forget()
                if let had {
                    print("Forgot \(had.path(percentEncoded: false)). Auto-detect starts at ~/Downloads again.")
                } else {
                    print("No remembered GPTK folder. Auto-detect already starts at ~/Downloads.")
                }
                return
            }
            guard WynWineInstaller.isWynWineInstalled() else {
                throw ValidationError("WynWine not installed. Run: wyn install")
            }
            if pick && noPrompt {
                throw ValidationError("--pick opens Finder and --no-prompt forbids it. Pick one.")
            }
            let source: URL
            if let from {
                source = URL(fileURLWithPath: from)
                print("GPTK source: \(source.path(percentEncoded: false))")
            } else if pick {
                guard GPTKSourcePicker.isInteractive else {
                    throw ValidationError("--pick needs a terminal. Pass --from <path> instead.")
                }
                guard let chosen = GPTKSourcePicker.chooseSource() else {
                    throw ValidationError("No file chosen.")
                }
                source = chosen
                print("GPTK source: \(chosen.path(percentEncoded: false))")
            } else if let found = GPTKInstaller.preferredLocalSource() {
                source = found
                print("Using \(found.path(percentEncoded: false))")
            } else if !noPrompt, GPTKSourcePicker.isInteractive {
                // Nothing where we look. Rather than telling the user to move
                // their download, let them point at it.
                let start = GPTKSourcePicker.pickerStartFolder()
                print("No Game Porting Toolkit found in \(start.path(percentEncoded: false)).")
                print("Opening Finder — choose the GPTK disk image (Cancel to abort).")
                guard let chosen = GPTKSourcePicker.chooseSource(startingAt: start) else {
                    throw ValidationError(GPTKInstaller.GPTKError.notFoundInDownloads.errorDescription ?? "")
                }
                source = chosen
                print("GPTK source: \(chosen.path(percentEncoded: false))")
            } else {
                throw ValidationError(GPTKInstaller.GPTKError.notFoundInDownloads.errorDescription ?? "")
            }
            let installed = try GPTKInstaller.install(from: source)
            // Only a source that survived install is worth remembering.
            GPTKSourcePicker.remember(source: source)
            print("GPTK/D3DMetal files → \(installed.path(percentEncoded: false))")
            if let ver = GPTKInstaller.installedD3DMetalVersion() {
                print("D3DMetal version: \(ver)")
            }
            if GPTKInstaller.shouldWireWineModules {
                print("Wine PE/MetalFX overlay applied (GPTK-aware Wine).")
                print("MetalFX/nvngx: \(GPTKInstaller.isMetalFXWired() ? "present" : "MISSING (redist may lack nvngx-on-metalfx)")")
            } else {
                print("Wine stubs not overlaid. Need FOSS winecx: wyn runtime install --gptk-aware --directory <wine-root>")
            }
            let renderer = RendererWiring.inspect()
            print("Renderer: \(renderer.statusLines[0])")
            if renderer.backend != .d3dMetal {
                print("GPTK install does not select D3DMetal. DXMT stays selected until: wyn renderer set d3dmetal")
            }
        }
    }
}

// MARK: - Renderer (shared unix d3d*.so selection)

extension WynCLI {
    struct Renderer: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "renderer",
            abstract: "Select the shared Direct3D → Metal backend (DXMT default; D3DMetal opt-in).",
            discussion: """
            Unix d3d11.so / d3d10.so / dxgi.so / d3d12.so in Libraries/ are a shared \
            pointer. Bottle translationLayer is declared intent; if they disagree, \
            the filesystem wins. wyn gptk install only makes D3DMetal available.

            DXMT is D3D11 → Metal. D3D12-only titles still need GPTK (wyn renderer set d3dmetal).
            """,
            subcommands: [RendererStatus.self, RendererSet.self],
            defaultSubcommand: RendererStatus.self
        )
    }

    struct RendererStatus: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Show declared vs wired graphics backend."
        )

        mutating func run() throws {
            guard WynWineInstaller.isWynWineInstalled() else {
                print("WynWine is NOT installed. Run: wyn install")
                return
            }

            print("GPTK files: \(GPTKInstaller.isInstalled() ? "installed (selectable)" : "not installed")")
            if let ver = GPTKInstaller.installedD3DMetalVersion() {
                print("D3DMetal:   \(ver)")
            }
            print("Unix dir:   \(RendererWiring.Context.live.unixDirectory.path(percentEncoded: false))")
            for line in RendererWiring.inspect().statusLines {
                print(line)
            }
            print("")

            var data = BottleData()
            let bottles = data.loadBottles()
            if bottles.isEmpty {
                print("No bottles.")
                return
            }
            print("Bottles:")
            for bottle in bottles {
                let effective = LaunchDiagnostics.effectiveLayer(for: bottle)
                print(
                    "  \(bottle.settings.name): declared=\(bottle.settings.translationLayer.rawValue) " +
                    "effective=\(effective.layer.rawValue)"
                )
                if effective.reason.contains("but Libraries") {
                    print("    \(effective.reason)")
                }
            }
        }
    }

    struct RendererSet: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Repoint shared unix d3d*.so at dxmt, dxvk, or d3dmetal and verify."
        )

        @Argument(help: "Backend: dxmt (default), dxvk, or d3dmetal.")
        var layer: TranslationLayer

        mutating func run() throws {
            guard WynWineInstaller.isWynWineInstalled() else {
                throw ValidationError("WynWine not installed. Run: wyn install")
            }
            try RendererWiring.set(layer)
            print("Renderer → \(layer.displayName)")
            for line in RendererWiring.inspect().statusLines {
                print("  \(line)")
            }
        }
    }
}
