//
//  Program+Extensions.swift
//  WynKit
//

import Foundation
import AppKit
import os.log

extension Program {
    public func run(withProfile profile: GameProfile? = nil) async throws {
        if let profile {
            ProfileApplicator.apply(profile: profile, to: bottle)
        }

        let environment = ProfileApplicator.launchEnvironment(profile: profile, program: self)
        let arguments = ProfileApplicator.launchArguments(profile: profile, program: self)

        try await Wine.runProgram(
            at: url, args: arguments, bottle: bottle, environment: environment
        )
    }

    public func generateTerminalCommand(profile: GameProfile? = nil) -> String {
        if let profile {
            ProfileApplicator.apply(profile: profile, to: bottle)
        }

        let environment = ProfileApplicator.launchEnvironment(profile: profile, program: self)
        let arguments = ProfileApplicator.launchArguments(profile: profile, program: self)
        let argsString = arguments.joined(separator: " ")

        return Wine.generateRunCommand(
            at: url, bottle: bottle, args: argsString, environment: environment
        )
    }

    public func runInTerminal(profile: GameProfile? = nil) {
        let wineCmd = generateTerminalCommand(profile: profile).replacingOccurrences(of: "\\", with: "\\\\")

        let script = """
        tell application "Terminal"
            activate
            do script "\(wineCmd)"
        end tell
        """

        Task.detached(priority: .userInitiated) {
            var error: NSDictionary?
            guard let appleScript = NSAppleScript(source: script) else { return }
            appleScript.executeAndReturnError(&error)

            if let error = error {
                Logger.wynKit.error("Failed to run terminal script \(error)")
                if let description = error["NSAppleScriptErrorMessage"] as? String {
                    fputs("Failed to launch: \(description)\n", stderr)
                }
            }
        }
    }
}
