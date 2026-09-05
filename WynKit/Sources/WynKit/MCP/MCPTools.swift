//
//  MCPTools.swift
//  WynKit
//
//  The tools Wyn exposes to whatever Claude the person already has.
//
//  Wyn is the MCP *server*, not the client: no API key lives in the app, no
//  model call costs the project anything, and there is no LLM in the binary.
//  The person points their own Claude Desktop or Claude Code at `wyn mcp` and
//  talks to it.
//
//  The shape of the surface is the argument. Reads are generous — the whole
//  point is that a model can *look at the disk* instead of recalling facts
//  about a game, because "this ships vulkan-1.dll and no d3d12.dll" is
//  checkable and "Solarpunk needs MetalFX" is not. Writes are narrow and
//  gated: `save_profile` refuses anything ProfileValidator rejects, writes only
//  into the user profiles directory, and forces `status: guessed`, because a
//  model cannot verify anything. Verification needs a person who watched the
//  screen, or a launch record from a machine that ran it.
//
//  Nothing here launches, kills, or installs. Nothing here reads Steam's
//  config/ directory.
//

import Foundation

public enum MCPToolError: LocalizedError {
    case unknownTool(String)
    case missingArgument(String)
    case noSteamBottle
    case gameNotInstalled(Int)
    case profileRejected([ProfileValidator.Finding])
    case noMatchingExecutable(profileID: String, patterns: [String], available: [String])

    public var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            return "No such tool: \(name)"
        case .missingArgument(let name):
            return "Missing required argument: \(name)"
        case .noSteamBottle:
            return "No Steam bottle yet. Run Setup in Wyn, or `wyn steam install`."
        case .gameNotInstalled(let appId):
            return "Steam app \(appId) is not installed in this bottle."
        case .profileRejected(let findings):
            let lines = findings.map { "  \($0.rule): \($0.message)" }.joined(separator: "\n")
            return """
            Profile rejected — it breaks rules that each cost days to learn:
            \(lines)

            Fix those and call save_profile again. validate_profile checks
            without writing anything.
            """
        case .noMatchingExecutable(let id, let patterns, let available):
            return """
            None of \(id)'s exePatterns match anything in the game's installed
            files, so this profile could never launch it.

            Patterns given: \(patterns.joined(separator: ", "))

            Executables actually on disk:
            \(available.map { "  \($0)" }.joined(separator: "\n"))

            Use the real filenames. An invented one is the most common way an
            otherwise sensible profile turns out to be useless.
            """
        }
    }
}

public enum MCPTools {

    // MARK: - Declarations

    public struct Tool {
        public let name: String
        public let description: String
        /// JSON Schema for the arguments. `Any` because that is what
        /// JSONSerialization wants on the way out, which costs Sendable.
        public let inputSchema: [String: Any]

        public init(name: String, description: String, inputSchema: [String: Any]) {
            self.name = name
            self.description = description
            self.inputSchema = inputSchema
        }
    }

    private static func object(
        _ properties: [String: Any] = [:],
        required: [String] = []
    ) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return schema
    }

    public static var all: [Tool] {
        [
            Tool(
                name: "list_installed_games",
                description: """
                Every game Steam has installed in Wyn's bottle, with its Steam \
                app id, whether Wyn has a profile for it, and what that profile \
                has actually earned (guessed / launched / verified). Start here: \
                the game the person means is usually already installed, so its \
                real name and app id can be read rather than guessed.
                """,
                inputSchema: object()
            ),
            Tool(
                name: "inspect_game_files",
                description: """
                Read a game's installed files: engine signature and the evidence \
                for it, candidate executables ranked by how much they look like \
                the thing you launch, and which graphics libraries the game \
                ships. This is how to decide a profile — vulkan-1.dll and no \
                d3d12.dll means a Vulkan renderer and D3DMetal cannot translate \
                it. Prefer this over recalling what engine a game uses.
                """,
                inputSchema: object(
                    ["steamAppId": ["type": "integer", "description": "Steam app id, from list_installed_games."]],
                    required: ["steamAppId"]
                )
            ),
            Tool(
                name: "list_profiles",
                description: "Every profile Wyn knows, with its id, name, Steam app id and earned status.",
                inputSchema: object()
            ),
            Tool(
                name: "get_profile",
                description: "One profile, as JSON, exactly as Wyn holds it.",
                inputSchema: object(
                    ["id": ["type": "string", "description": "Profile id, e.g. \"satisfactory\"."]],
                    required: ["id"]
                )
            ),
            Tool(
                name: "read_launch_evidence",
                description: """
                What this machine has actually run and for how long, and which \
                profiles that evidence still supports. Evidence is tied to the \
                settings that produced it, so changing a profile discards its \
                old records. Wyn ships 120 profiles and one was ever measured — \
                this is the only real data there is.
                """,
                inputSchema: object()
            ),
            Tool(
                name: "read_session_performance",
                description: """
                What a game's last session actually did, read from the game's \
                own Unreal log: whether it ran at all, which translation layer \
                really ran, frame rate, the resolution actually rendered, and \
                whether anything caps the frame rate.

                Call this after the person reports back on a launch. It answers \
                the one question no profile can: the layer a game gets is \
                decided by the Wine tree the bottle is running, not by the \
                profile — a d3dmetal profile measured 45 fps on DXVK where \
                D3DMetal gives 120, and every other tool reported success. \
                It also reports a session that stopped — a game that hung on \
                its first frame has no frame rate, and "unmeasurable" must \
                never be read as "fine". Requires the profile to set \
                `unrealProject`.
                """,
                inputSchema: object(
                    ["id": ["type": "string", "description": "Profile id, e.g. \"solarpunk\"."]],
                    required: ["id"]
                )
            ),
            Tool(
                name: "validate_profile",
                description: """
                Check a profile against Wyn's rules without writing anything. \
                The rules encode things that each cost days to find: debug \
                overlays must be off, D3DMetal settings measured to crash a real \
                game may not be enabled by an untested profile, and several \
                launch arguments are forbidden outright. Call this while \
                drafting; save_profile applies the same rules and refuses.
                """,
                inputSchema: object(
                    ["profile": ["type": "object", "description": "A complete profile object."]],
                    required: ["profile"]
                )
            ),
            Tool(
                name: "save_profile",
                description: """
                Write a profile into the person's own profiles directory. \
                Refuses anything validate_profile rejects, never touches the \
                profiles Wyn ships, and always saves with status "guessed" — a \
                profile that has not been run is a guess no matter how confident \
                the reasoning behind it. It is promoted automatically once this \
                machine actually runs the game.
                """,
                inputSchema: object(
                    ["profile": ["type": "object", "description": "A complete profile object."]],
                    required: ["profile"]
                )
            )
        ]
    }

    // MARK: - Dispatch

    /// Runs a tool and returns text for the model. Throwing produces an MCP
    /// tool error, which is what a model should see when it gets something
    /// wrong — not a silent empty result.
    public static func call(name: String, arguments: [String: Any]) throws -> String {
        switch name {
        case "list_installed_games":   return try listInstalledGames()
        case "inspect_game_files":     return try inspectGameFiles(arguments)
        case "list_profiles":          return listProfiles()
        case "get_profile":            return try getProfile(arguments)
        case "read_launch_evidence":   return DiagnosticsBundle.launchRecordReport()
        case "read_session_performance": return try readSessionPerformance(arguments)
        case "validate_profile":       return try validateProfile(arguments)
        case "save_profile":           return try saveProfile(arguments)
        default: throw MCPToolError.unknownTool(name)
        }
    }

    // MARK: - Implementations

    static func steamBottle() throws -> Bottle {
        guard let bottle = GameLibrary.steamBottle() else { throw MCPToolError.noSteamBottle }
        return bottle
    }

    static func listInstalledGames() throws -> String {
        let bottle = try steamBottle()
        let records = LaunchRecordStore.load()
        let items = GameLibrary.installed(in: bottle)
        guard !items.isEmpty else {
            return "No games installed in the Steam bottle yet."
        }

        var lines = ["\(items.count) installed game(s):", ""]
        for item in items {
            let profile = item.profile
            let synthesised = profile.id.hasPrefix("steam-")
            let status = synthesised
                ? "no profile"
                : LaunchRecordStore.effectiveStatus(for: profile, in: records).rawValue
            lines.append("\(profile.name)")
            lines.append("  steamAppId=\(profile.steamAppId.map(String.init) ?? "-")"
                         + "  profile=\(synthesised ? "none" : profile.id)"
                         + "  status=\(status)")
        }
        lines.append("")
        lines.append("""
        "no profile" means Wyn has the game but no launch settings for it — \
        inspect_game_files on its app id is the next step.
        """)
        return lines.joined(separator: "\n")
    }

    static func inspectGameFiles(_ arguments: [String: Any]) throws -> String {
        guard let appId = arguments["steamAppId"] as? Int else {
            throw MCPToolError.missingArgument("steamAppId")
        }
        let bottle = try steamBottle()
        guard let directory = SteamLauncher.installDirectory(forAppId: appId, in: bottle) else {
            throw MCPToolError.gameNotInstalled(appId)
        }
        let report = GameFileInspector.inspect(installDirectory: directory)
        return encode(report)
    }

    static func listProfiles() -> String {
        let records = LaunchRecordStore.load()
        let rows = ProfileStore.loadAll().sorted { $0.id < $1.id }.map { profile in
            [
                "id": profile.id,
                "name": profile.name,
                "steamAppId": profile.steamAppId.map(String.init) ?? "",
                "status": LaunchRecordStore.effectiveStatus(for: profile, in: records).rawValue
            ]
        }
        return encode(rows)
    }

    static func getProfile(_ arguments: [String: Any]) throws -> String {
        guard let id = arguments["id"] as? String else {
            throw MCPToolError.missingArgument("id")
        }
        guard let profile = ProfileStore.profile(id: id) else {
            return "No profile with id \"\(id)\". list_profiles shows what exists."
        }
        return encode(profile)
    }

    /// Reads the game's own log rather than anything Wyn wrote, which is the
    /// point: it is the only source that knows which layer really ran.
    static func readSessionPerformance(_ arguments: [String: Any]) throws -> String {
        guard let id = arguments["id"] as? String else {
            throw MCPToolError.missingArgument("id")
        }
        guard let profile = ProfileStore.profile(id: id) else {
            return "No profile with id \"\(id)\". list_profiles shows what exists."
        }
        return SessionPerformance.report(profile: profile, in: try steamBottle())
    }

    static func decodeProfile(_ arguments: [String: Any]) throws -> GameProfile {
        guard let raw = arguments["profile"] as? [String: Any] else {
            throw MCPToolError.missingArgument("profile")
        }
        let data = try JSONSerialization.data(withJSONObject: raw)
        return try JSONDecoder().decode(GameProfile.self, from: data)
    }

    static func validateProfile(_ arguments: [String: Any]) throws -> String {
        let profile = try decodeProfile(arguments)
        let findings = ProfileValidator.validate(profile)
        guard !findings.isEmpty else {
            return "No findings. This profile passes every rule."
        }
        return findings.map(\.description).joined(separator: "\n")
    }

    static func saveProfile(_ arguments: [String: Any]) throws -> String {
        var profile = try decodeProfile(arguments)

        // A model cannot verify anything, and neither can confident prose. The
        // only routes to a higher status are a launch record from this machine
        // or a person editing the file by hand.
        let claimed = profile.status
        profile.status = .guessed

        let findings = ProfileValidator.validate(profile)
        let errors = findings.filter { $0.severity == .error }
        guard errors.isEmpty else { throw MCPToolError.profileRejected(errors) }

        // Checks beat prompts. The likeliest failure by far is an invented
        // executable name — plausible, unverifiable from text, and fatal, since
        // a profile whose patterns match nothing can never launch the game. If
        // the game is installed we can simply look.
        let executableNote = try verifyExecutablePatterns(profile)

        try ProfileStore.save(profile: profile)

        var lines = [
            "Saved \(profile.id) to \(ProfileStore.userProfilesDirectory.path(percentEncoded: false))."
        ]
        if claimed != .guessed {
            lines.append("""
            Saved as "guessed", not "\(claimed.rawValue)" — nothing has run it \
            yet. Wyn promotes it to "launched" on its own once the game runs for \
            a minute on this machine.
            """)
        }
        let warnings = findings.filter { $0.severity == .warning }
        if !warnings.isEmpty {
            lines.append("")
            lines.append("Saved with warnings:")
            lines.append(contentsOf: warnings.map { "  \($0.rule): \($0.message)" })
        }
        if let executableNote {
            lines.append("")
            lines.append(executableNote)
        }
        lines.append("")
        lines.append("Launch it from Wyn to find out whether any of this was right.")
        return lines.joined(separator: "\n")
    }

    /// At least one `exePattern` must match a file the game actually ships.
    ///
    /// Only checkable when the game is installed — with nothing on disk to
    /// compare against there is no honest check to make, and refusing would
    /// block the legitimate case of writing a profile ahead of installing.
    /// Returns a note when the check could not be performed.
    static func verifyExecutablePatterns(_ profile: GameProfile) throws -> String? {
        guard let appId = profile.steamAppId else {
            return "No steamAppId, so the executable names could not be checked against disk."
        }
        guard let bottle = GameLibrary.steamBottle(),
              let directory = SteamLauncher.installDirectory(forAppId: appId, in: bottle)
        else {
            return "\(profile.name) is not installed here, so the executable names "
                + "could not be checked against disk. Verify them when it is."
        }

        let report = GameFileInspector.inspect(installDirectory: directory)
        guard !report.executables.isEmpty else {
            return "No executables found in the install directory — nothing to check against."
        }

        let matched = report.executables.contains { executable in
            profile.matches(executable: URL(fileURLWithPath: executable.name))
        }
        guard matched else {
            throw MCPToolError.noMatchingExecutable(
                profileID: profile.id,
                patterns: profile.exePatterns,
                available: report.executables.map(\.path)
            )
        }
        return nil
    }

    // MARK: - Encoding

    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
