//
//  MCPServer.swift
//  WynKit
//
//  MCP over stdio, hand-rolled.
//
//  Line-delimited JSON-RPC 2.0 is about two hundred lines, and a dependency
//  here would be one more thing to pin, audit and keep building on a machine
//  that already compiles its own Wine. `handle(_:)` is a pure function from
//  request string to response string, which is also what makes the protocol
//  testable without spawning anything.
//

import Foundation

public struct MCPServer: Sendable {
    /// The MCP revision this speaks. Clients send their own in `initialize`;
    /// echoing theirs back when we understand it avoids a version handshake
    /// failure over a difference that does not matter here.
    public static let preferredProtocolVersion = "2024-11-05"

    public init() {}

    // MARK: - Handling

    /// One request line in, one response line out. Returns nil for
    /// notifications, which by JSON-RPC must not be answered.
    public func handle(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let data = trimmed.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return encode(errorResponse(id: nil, code: -32700, message: "Parse error"))
        }

        let id = message["id"]
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]

        // No id means a notification: act on it, answer nothing.
        guard id != nil else { return nil }

        switch method {
        case "initialize":
            return encode(initializeResult(id: id, params: params))
        case "ping":
            return encode(["jsonrpc": "2.0", "id": id!, "result": [:] as [String: Any]])
        case "tools/list":
            return encode(toolsListResult(id: id))
        case "tools/call":
            return encode(toolsCallResult(id: id, params: params))
        case "prompts/list":
            return encode(promptsListResult(id: id))
        case "prompts/get":
            return encode(promptsGetResult(id: id, params: params))
        default:
            return encode(errorResponse(
                id: id, code: -32601, message: "Method not found: \(method)"
            ))
        }
    }

    // MARK: - Results

    private func initializeResult(id: Any?, params: [String: Any]) -> [String: Any] {
        let requested = params["protocolVersion"] as? String
        return [
            "jsonrpc": "2.0",
            "id": id!,
            "result": [
                "protocolVersion": requested ?? Self.preferredProtocolVersion,
                "capabilities": [
                    "tools": ["listChanged": false] as [String: Any],
                    "prompts": ["listChanged": false] as [String: Any]
                ] as [String: Any],
                "serverInfo": ["name": "wyn", "version": Self.version],
                // Clients hand this to the model as server-level context, which
                // makes it the nearest thing to a system prompt Wyn gets. The
                // gates in ProfileValidator and save_profile are what actually
                // hold; this only makes refusals rarer and drafts better.
                "instructions": MCPGuidance.instructions
            ] as [String: Any]
        ]
    }

    private func promptsListResult(id: Any?) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id!,
            "result": [
                "prompts": MCPGuidance.all.map { prompt in
                    [
                        "name": prompt.name,
                        "description": prompt.description,
                        "arguments": prompt.arguments.map { argument in
                            [
                                "name": argument.0,
                                "description": argument.1,
                                "required": argument.2
                            ] as [String: Any]
                        }
                    ] as [String: Any]
                }
            ] as [String: Any]
        ]
    }

    private func promptsGetResult(id: Any?, params: [String: Any]) -> [String: Any] {
        let name = params["name"] as? String ?? ""
        guard let prompt = MCPGuidance.all.first(where: { $0.name == name }) else {
            return errorResponse(id: id, code: -32602, message: "No such prompt: \(name)")
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        // Every prompt here takes at most one argument, and it is the subject.
        let subject = prompt.arguments.first.flatMap { arguments[$0.0] as? String }

        return [
            "jsonrpc": "2.0",
            "id": id!,
            "result": [
                "description": prompt.description,
                "messages": [
                    [
                        "role": "user",
                        "content": ["type": "text", "text": prompt.body(subject)] as [String: Any]
                    ] as [String: Any]
                ]
            ] as [String: Any]
        ]
    }

    private func toolsListResult(id: Any?) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id!,
            "result": [
                "tools": MCPTools.all.map { tool in
                    [
                        "name": tool.name,
                        "description": tool.description,
                        "inputSchema": tool.inputSchema
                    ] as [String: Any]
                }
            ] as [String: Any]
        ]
    }

    private func toolsCallResult(id: Any?, params: [String: Any]) -> [String: Any] {
        let name = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? [String: Any] ?? [:]

        do {
            let text = try MCPTools.call(name: name, arguments: arguments)
            return [
                "jsonrpc": "2.0",
                "id": id!,
                "result": [
                    "content": [["type": "text", "text": text] as [String: Any]],
                    "isError": false
                ] as [String: Any]
            ]
        } catch {
            // An MCP tool error is a *result*, not a protocol error: the model
            // is meant to read it and try again, which is exactly what should
            // happen when a profile is rejected.
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            return [
                "jsonrpc": "2.0",
                "id": id!,
                "result": [
                    "content": [["type": "text", "text": message] as [String: Any]],
                    "isError": true
                ] as [String: Any]
            ]
        }
    }

    private func errorResponse(id: Any?, code: Int, message: String) -> [String: Any] {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message] as [String: Any]
        ]
        response["id"] = id ?? NSNull()
        return response
    }

    // MARK: - Plumbing

    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    private func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else {
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Encoding failed"}}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Running

    /// Pump stdin to stdout until the client closes the pipe.
    ///
    /// stdout carries protocol only — anything else printed there corrupts the
    /// stream and the client disconnects with no useful message. Diagnostics go
    /// to stderr, which is where an MCP client collects logs anyway.
    public func run() {
        FileHandle.standardError.write(Data(
            "wyn mcp: ready, \(MCPTools.all.count) tools\n".utf8
        ))
        while let line = readLine(strippingNewline: true) {
            guard let response = handle(line) else { continue }
            print(response)
            fflush(stdout)
        }
    }
}
