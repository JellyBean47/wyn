import Foundation
import Testing
@testable import WynKit

/// Wyn is the MCP *server*: the person's own Claude connects to it, so no API
/// key lives in the app and no model call costs the project anything.
///
/// The protocol is exercised by feeding real JSON-RPC strings through
/// `handle(_:)` rather than spawning a process, which is the whole reason it is
/// a pure function.
@Suite("MCP server")
struct MCPServerTests {

    private let server = MCPServer()

    private func send(_ json: String) -> [String: Any]? {
        guard let response = server.handle(json),
              let data = response.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    private func result(_ object: [String: Any]?) -> [String: Any]? {
        object?["result"] as? [String: Any]
    }

    /// Tool errors come back as results with isError, not protocol errors — a
    /// model is meant to read them and try again.
    private func toolText(_ object: [String: Any]?) -> (text: String, isError: Bool)? {
        guard let result = result(object),
              let content = result["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String
        else { return nil }
        return (text, result["isError"] as? Bool ?? false)
    }

    // MARK: - Protocol

    @Test func initializeAnswersWithServerInfo() {
        let response = send(#"""
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}
        """#)
        #expect(response?["jsonrpc"] as? String == "2.0")
        #expect(response?["id"] as? Int == 1)
        let result = result(response)
        #expect((result?["serverInfo"] as? [String: Any])?["name"] as? String == "wyn")
        #expect(result?["protocolVersion"] as? String == "2024-11-05")
        #expect((result?["capabilities"] as? [String: Any])?["tools"] != nil)
    }

    /// Clients differ on revision. Echo one we understand rather than failing a
    /// handshake over a difference that changes nothing here.
    @Test func initializeEchoesTheClientsProtocolVersion() {
        let response = send(#"""
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}
        """#)
        #expect(result(response)?["protocolVersion"] as? String == "2025-06-18")
    }

    /// A notification has no id and must not be answered at all.
    @Test func notificationsGetNoResponse() {
        #expect(server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(server.handle("") == nil)
        #expect(server.handle("   \n ") == nil)
    }

    @Test func malformedJSONIsAParseError() {
        let response = send("{ not json")
        let error = response?["error"] as? [String: Any]
        #expect(error?["code"] as? Int == -32700)
    }

    @Test func unknownMethodsAreRejected() {
        let response = send(#"{"jsonrpc":"2.0","id":9,"method":"does/not/exist"}"#)
        #expect((response?["error"] as? [String: Any])?["code"] as? Int == -32601)
    }

    @Test func pingIsAnswered() {
        #expect(result(send(#"{"jsonrpc":"2.0","id":3,"method":"ping"}"#)) != nil)
    }

    // MARK: - Tools

    @Test func toolsListAdvertisesEveryTool() {
        let tools = result(send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))?["tools"] as? [[String: Any]]
        let names = Set((tools ?? []).compactMap { $0["name"] as? String })
        #expect(names == [
            "list_installed_games", "inspect_game_files", "list_profiles",
            "get_profile", "read_launch_evidence", "validate_profile", "save_profile"
        ])
    }

    /// A tool with no description or schema is a tool a model will misuse.
    @Test func everyToolIsDescribedAndSchemad() {
        for tool in MCPTools.all {
            #expect(tool.description.count > 40, "\(tool.name) needs a real description")
            #expect(tool.inputSchema["type"] as? String == "object", "\(tool.name)")
        }
    }

    @Test func gettingAMissingProfileExplainsItself() {
        let response = send(#"""
        {"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_profile","arguments":{"id":"nope"}}}
        """#)
        #expect(toolText(response)?.text.contains("No profile") == true)
    }

    @Test func aRealProfileComesBackAsJSON() {
        let response = send(#"""
        {"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"get_profile","arguments":{"id":"satisfactory"}}}
        """#)
        let text = toolText(response)?.text ?? ""
        #expect(text.contains("\"id\" : \"satisfactory\""))
        #expect(text.contains("D3DM_ENABLE_METALFX"))
    }

    @Test func anUnknownToolIsAToolError() {
        let response = send(#"""
        {"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"rm_rf","arguments":{}}}
        """#)
        let outcome = toolText(response)
        #expect(outcome?.isError == true)
        #expect(outcome?.text.contains("No such tool") == true)
    }

    @Test func aMissingArgumentIsAToolError() {
        let response = send(#"""
        {"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"get_profile","arguments":{}}}
        """#)
        #expect(toolText(response)?.isError == true)
    }

    // MARK: - Guidance

    /// The soft half of keeping a model on path. `instructions` is what MCP
    /// clients hand the model as server-level context, so if it is missing the
    /// model gets no framing at all beyond per-tool text.
    @Test func initializeCarriesServerInstructions() {
        let response = send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
        let instructions = result(response)?["instructions"] as? String ?? ""
        #expect(instructions.count > 500, "instructions must actually say something")

        // The things a model most needs to know before drafting.
        for expected in [
            "inspect_game_files", "MetalFX", "vulkan", "guessed", "exePatterns"
        ] {
            #expect(instructions.lowercased().contains(expected.lowercased()),
                    "instructions should mention \(expected)")
        }
    }

    /// Adding Solarpunk took four launches because each one started from an
    /// optimistic profile and bisected down after the crash. The fix was a
    /// conservative baseline, and the two settings that actually mattered were
    /// AVX and windowed mode. If that stops being said here, the next game
    /// costs four launches again.
    @Test func guidanceCarriesTheSafeBaseline() {
        let instructions = MCPGuidance.instructions.lowercased()
        #expect(instructions.contains("avxenabled false"))
        #expect(instructions.contains("-windowed"))

        let addGame = MCPGuidance.all.first { $0.name == "add_game" }
        let body = (addGame?.body(nil) ?? "").lowercased()
        for expected in ["avxenabled      false", "-windowed", "msync", "vcrun2019"] {
            #expect(body.contains(expected), "add_game should pin \(expected)")
        }
    }

    /// Tuning is the other half, and its whole value is the ordering: one
    /// change per launch, cheapest-to-revert first.
    @Test func tuningIsOneChangeAtATime() throws {
        let tune = try #require(MCPGuidance.all.first { $0.name == "tune_profile" })
        let body = tune.body("solarpunk")
        #expect(body.contains("solarpunk"))
        #expect(body.lowercased().contains("one change per launch"))
        #expect(body.contains("read_launch_evidence"))

        // The order is the point: windowed, then resolution, then AVX.
        let windowed = try #require(body.range(of: "drop -windowed"))
        let res = try #require(body.range(of: "raise -ResX"))
        let avx = try #require(body.range(of: "avxEnabled true"))
        #expect(windowed.lowerBound < res.lowerBound)
        #expect(res.lowerBound < avx.lowerBound)
    }

    /// It must be honest about the one thing a model cannot do.
    @Test func instructionsSayTheModelCannotVerify() {
        let instructions = MCPGuidance.instructions.lowercased()
        #expect(instructions.contains("cannot mark"))
        #expect(instructions.contains("verified"))
    }

    @Test func promptsAreAdvertisedAndFetchable() {
        let response = send(#"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{}}"#)
        let capabilities = result(response)?["capabilities"] as? [String: Any]
        #expect(capabilities?["prompts"] != nil, "prompts capability must be declared")

        let listed = result(send(#"{"jsonrpc":"2.0","id":3,"method":"prompts/list"}"#))?["prompts"]
            as? [[String: Any]]
        let names = Set((listed ?? []).compactMap { $0["name"] as? String })
        #expect(names == ["add_game", "review_profile", "tune_profile"])
    }

    @Test func aPromptComesBackAsAUserMessage() {
        let response = send(#"""
        {"jsonrpc":"2.0","id":4,"method":"prompts/get","params":{"name":"add_game","arguments":{"game":"Solarpunk"}}}
        """#)
        let messages = result(response)?["messages"] as? [[String: Any]]
        let first = messages?.first
        #expect(first?["role"] as? String == "user")
        let text = (first?["content"] as? [String: Any])?["text"] as? String ?? ""
        #expect(text.contains("Solarpunk"))
        #expect(text.contains("inspect_game_files"))
    }

    /// The argument is optional, so the prompt has to work without it.
    @Test func addGameWorksWithNoGameNamed() {
        let response = send(#"{"jsonrpc":"2.0","id":5,"method":"prompts/get","params":{"name":"add_game"}}"#)
        let messages = result(response)?["messages"] as? [[String: Any]]
        let text = ((messages?.first?["content"]) as? [String: Any])?["text"] as? String ?? ""
        #expect(text.contains("Ask which game"))
    }

    @Test func anUnknownPromptIsRejected() {
        let response = send(#"{"jsonrpc":"2.0","id":6,"method":"prompts/get","params":{"name":"nope"}}"#)
        #expect((response?["error"] as? [String: Any])?["code"] as? Int == -32602)
    }

    // MARK: - The write gate

    /// The rules that cost days apply to whatever the model drafts. This is the
    /// same profile shape that shipped in 72 files.
    @Test func savingAProfileWithDebugOverlaysIsRefused() throws {
        let response = send(#"""
        {"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"save_profile","arguments":{"profile":{
          "id":"mcp-test-refused","name":"Refused","exePatterns":["x.exe"],
          "environment":{"MTL_HUD_ENABLED":"1","D3DM_ENABLE_METALFX":"1"}
        }}}}
        """#)
        let outcome = toolText(response)
        #expect(outcome?.isError == true)
        #expect(outcome?.text.contains("debugOverlayOff") == true)
        #expect(outcome?.text.contains("unmeasuredRiskSetting") == true)

        let written = ProfileStore.userProfilesDirectory.appending(path: "mcp-test-refused.json")
        #expect(!FileManager.default.fileExists(atPath: written.path(percentEncoded: false)),
                "a rejected profile must not reach disk")
    }

    @Test func validateWritesNothing() {
        let response = send(#"""
        {"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"validate_profile","arguments":{"profile":{
          "id":"mcp-test-validate-only","name":"V","exePatterns":["x.exe"],
          "environment":{"MTL_HUD_ENABLED":"1"}
        }}}}
        """#)
        #expect(toolText(response)?.text.contains("debugOverlayOff") == true)
        let written = ProfileStore.userProfilesDirectory.appending(path: "mcp-test-validate-only.json")
        #expect(!FileManager.default.fileExists(atPath: written.path(percentEncoded: false)))
    }

    /// A model cannot verify anything. Claiming it must not make it so.
    @Test func savingCannotClaimVerified() throws {
        let id = "mcp-test-status-\(UUID().uuidString.prefix(8))"
        let written = ProfileStore.userProfilesDirectory.appending(path: "\(id).json")
        defer { try? FileManager.default.removeItem(at: written) }

        let response = send("""
        {"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"save_profile","arguments":{"profile":{
          "id":"\(id)","name":"Status Test","exePatterns":["x.exe"],
          "notes":"measured, honest","status":"verified","environment":{}
        }}}}
        """)
        let outcome = toolText(response)
        #expect(outcome?.isError == false)
        #expect(outcome?.text.contains("guessed") == true)

        let data = try Data(contentsOf: written)
        let saved = try JSONDecoder().decode(GameProfile.self, from: data)
        #expect(saved.status == .guessed)
    }

    /// The likeliest failure a prompt cannot prevent: an invented executable
    /// name. Plausible on the page, unverifiable from text, and fatal — a
    /// profile whose patterns match nothing can never launch the game.
    ///
    /// Only checkable when the game is installed, so this test asserts the
    /// refusal when it can and the honest "could not check" note when it
    /// cannot. Either way it must never silently accept a made-up name as
    /// though it had been confirmed.
    @Test func aMadeUpExecutableIsCaughtWhenTheGameIsInstalled() throws {
        let installed = GameLibrary.steamBottle().map {
            SteamLauncher.installDirectory(forAppId: 526870, in: $0) != nil
        } ?? false

        let id = "mcp-test-exe-\(UUID().uuidString.prefix(8))"
        let written = ProfileStore.userProfilesDirectory.appending(path: "\(id).json")
        defer { try? FileManager.default.removeItem(at: written) }

        let response = send("""
        {"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"save_profile","arguments":{"profile":{
          "id":"\(id)","name":"Satisfactory","steamAppId":526870,
          "exePatterns":["totally-invented-name.exe"],"environment":{},"notes":"n"
        }}}}
        """)
        let outcome = toolText(response)

        if installed {
            #expect(outcome?.isError == true, "an invented exe name must be refused")
            #expect(outcome?.text.contains("could never launch") == true)
            // The refusal has to be actionable: hand back the real names.
            #expect(outcome?.text.contains(".exe") == true)
            #expect(!FileManager.default.fileExists(atPath: written.path(percentEncoded: false)),
                    "a profile that cannot match must not reach disk")
        } else {
            #expect(outcome?.isError == false)
            #expect(outcome?.text.contains("could not be checked") == true,
                    "when the check is impossible, say so rather than implying it passed")
        }
    }

    /// No app id means nothing to check against, and saying so is better than
    /// pretending the names were confirmed.
    @Test func aProfileWithNoAppIdSaysTheCheckWasSkipped() throws {
        let id = "mcp-test-noappid-\(UUID().uuidString.prefix(8))"
        let written = ProfileStore.userProfilesDirectory.appending(path: "\(id).json")
        defer { try? FileManager.default.removeItem(at: written) }

        let response = send("""
        {"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"save_profile","arguments":{"profile":{
          "id":"\(id)","name":"No App Id","exePatterns":["whatever.exe"],"environment":{},"notes":"n"
        }}}}
        """)
        let outcome = toolText(response)
        #expect(outcome?.isError == false)
        #expect(outcome?.text.contains("could not be checked") == true)
    }

    /// And a valid profile does get written.
    @Test func aCleanProfileIsSaved() throws {
        let id = "mcp-test-clean-\(UUID().uuidString.prefix(8))"
        let written = ProfileStore.userProfilesDirectory.appending(path: "\(id).json")
        defer { try? FileManager.default.removeItem(at: written) }

        let response = send("""
        {"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"save_profile","arguments":{"profile":{
          "id":"\(id)","name":"Clean","exePatterns":["clean.exe"],"steamAppId":42,
          "bottle":{"translationLayer":"dxvk","dxvk":true},"environment":{},"notes":"n"
        }}}}
        """)
        #expect(toolText(response)?.isError == false)
        #expect(FileManager.default.fileExists(atPath: written.path(percentEncoded: false)))
    }
}
