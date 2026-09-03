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
