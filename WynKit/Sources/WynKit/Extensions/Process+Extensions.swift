//
//  Process+Extensions.swift
//  WynKit
//
//  This file is part of Wyn.
//
//  Wyn is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Wyn is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Wyn.
//  If not, see https://www.gnu.org/licenses/.
//

import Foundation
import os.log

public enum ProcessOutput: Hashable {
    case started(Process)
    case message(String)
    case error(String)
    case terminated(Process)
}

public extension Process {
    /// Run the process returning a stream output
    func runStream(name: String, fileHandle: FileHandle?) throws -> AsyncStream<ProcessOutput> {
        let stream = makeStream(name: name, fileHandle: fileHandle)
        self.logProcessInfo(name: name)
        fileHandle?.writeInfo(for: self)
        try run()
        return stream
    }

    private func makeStream(name: String, fileHandle: FileHandle?) -> AsyncStream<ProcessOutput> {
        let pipe = Pipe()
        let errorPipe = Pipe()
        standardOutput = pipe
        standardError = errorPipe

        return AsyncStream<ProcessOutput> { continuation in
            continuation.onTermination = { termination in
                switch termination {
                case .finished:
                    break
                case .cancelled:
                    guard self.isRunning else { return }
                    self.terminate()
                @unknown default:
                    break
                }
            }

            continuation.yield(.started(self))

            // A `readabilityHandler` fires whenever the descriptor is readable,
            // and once the child closes its end, EOF is readable *forever*.
            // Returning early without clearing the handler therefore spins the
            // dispatch queue at 100% CPU for the lifetime of the app — one core
            // per pipe, two pipes here — and it outlives the child process.
            // Clearing the handler on empty data is the only way out, which is
            // why these read `availableData` directly: `nextLine()` collapsed
            // "EOF" and "nothing yet" into the same `nil`.
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                guard let line = String(data: data, encoding: .utf8), !line.isEmpty else { return }
                continuation.yield(.message(line))
                Logger.wynKit.info("\(line, privacy: .public)")
                fileHandle?.write(line: line)
            }

            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                guard let line = String(data: data, encoding: .utf8), !line.isEmpty else { return }
                continuation.yield(.error(line))
                Logger.wynKit.warning("\(line, privacy: .public)")
                fileHandle?.write(line: line)
            }

            terminationHandler = { (process: Process) in
                // Clear before draining: `readToEnd` leaves the descriptor at
                // EOF, and a live handler on an EOF descriptor is the spin above.
                pipe.fileHandleForReading.readabilityHandler = nil
                errorPipe.fileHandleForReading.readabilityHandler = nil
                do {
                    _ = try pipe.fileHandleForReading.readToEnd()
                    _ = try errorPipe.fileHandleForReading.readToEnd()
                    try fileHandle?.close()
                } catch {
                    Logger.wynKit.error("Error while clearing data: \(error)")
                }

                process.logTermination(name: name)
                continuation.yield(.terminated(process))
                continuation.finish()
            }
        }
    }

    private func logTermination(name: String) {
        if terminationStatus == 0 {
            Logger.wynKit.info(
                "Terminated \(name) with status code '\(self.terminationStatus, privacy: .public)'"
            )
        } else {
            Logger.wynKit.warning(
                "Terminated \(name) with status code '\(self.terminationStatus, privacy: .public)'"
            )
        }
    }

    private func logProcessInfo(name: String) {
        Logger.wynKit.info("Running process \(name)")

        if let arguments = arguments {
            Logger.wynKit.info("Arguments: `\(arguments.joined(separator: " "))`")
        }
        if let executableURL = executableURL {
            Logger.wynKit.info("Executable: `\(executableURL.path(percentEncoded: false))`")
        }
        if let directory = currentDirectoryURL {
            Logger.wynKit.info("Directory: `\(directory.path(percentEncoded: false))`")
        }
        if let environment = environment {
            Logger.wynKit.info("Environment: \(environment)")
        }
    }
}

extension FileHandle {
    /// - Warning: a `nil` here means *either* EOF or "nothing buffered yet", and
    ///   a `readabilityHandler` that cannot tell those apart will spin at 100%
    ///   CPU once the child closes the pipe. `makeStream` reads `availableData`
    ///   itself for that reason. Prefer that pattern over this.
    func nextLine() -> String? {
        guard let line = String(data: availableData, encoding: .utf8) else { return nil }
        if !line.isEmpty {
            return line
        } else {
            return nil
        }
    }
}
