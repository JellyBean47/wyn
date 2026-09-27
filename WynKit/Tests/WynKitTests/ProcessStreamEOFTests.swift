//
//  ProcessStreamEOFTests.swift
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
//  You should have received a copy of the GNU General Public License along with
//  Wyn. If not, see https://www.gnu.org/licenses/.
//

import Foundation
import Testing
@testable import WynKit

/// Measured 21 Sep 2026: launching a game left Wyn pinned at 100–172% CPU for
/// the life of the app, continuing after the game exited. Cause: a
/// `readabilityHandler` fires whenever its descriptor is readable, and once the
/// child closes its end EOF is readable *forever*. The handler returned early on
/// empty data without ever clearing itself, so dispatch re-fired it immediately
/// — a hot spin, one core per pipe, and `makeStream` opens two.
///
/// These tests are about CPU, not output, so they assert on consumed CPU time.
@Suite("Process stream does not spin at EOF")
struct ProcessStreamEOFTests {

    /// CPU seconds this process has burned, user + system.
    private func cpuSecondsUsed() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let sys = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + sys
    }

    /// Lowest CPU-seconds-per-wall-second seen across several short windows.
    ///
    /// `getrusage(RUSAGE_SELF)` covers the whole test process, and the runner
    /// executes suites in parallel — a single window picks up whatever the other
    /// ~380 tests are doing (measured: 1.6 CPU-s of ambient). The spin, by
    /// contrast, is relentless: every window sees it. Taking the minimum drops
    /// the ambient bursts and keeps the thing we are actually testing.
    private func quietestCPURate(windows: Int = 5, each: Duration = .milliseconds(300)) async throws -> Double {
        var lowest = Double.greatestFiniteMagnitude
        let seconds = Double(each.components.seconds) + Double(each.components.attoseconds) / 1e18
        for _ in 0..<windows {
            let before = cpuSecondsUsed()
            try await Task.sleep(for: each)
            lowest = min(lowest, (cpuSecondsUsed() - before) / seconds)
        }
        return lowest
    }

    private func drain(_ process: Process) async throws -> [ProcessOutput] {
        let stream = try process.runStream(name: "eof-test", fileHandle: nil)
        var seen: [ProcessOutput] = []
        for await event in stream {
            seen.append(event)
        }
        return seen
    }

    @Test func shortLivedProcessStreamsItsOutputAndFinishes() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "echo hello-from-child"]

        let seen = try await drain(process)

        let messages = seen.compactMap { if case .message(let m) = $0 { return m } else { return nil } }
        #expect(messages.joined().contains("hello-from-child"))
        #expect(seen.contains { if case .terminated = $0 { return true } else { return false } })
    }

    /// The regression. After the child exits, the pipes sit at EOF. If the
    /// handlers are still installed they spin, and this process burns roughly a
    /// full CPU-second per wall-second — per pipe. Idle bookkeeping is a few
    /// milliseconds, so the threshold is generous and still fails hard on a spin.
    @Test func eofDoesNotSpinTheCPUAfterTheChildExits() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "echo done"]
        _ = try await drain(process)

        // Child is gone and both pipes are at EOF. A cleared handler costs ~0;
        // the spin measured 4.0 CPU-s per wall-second when this was broken.
        let rate = try await quietestCPURate()

        #expect(
            rate < 0.6,
            """
            Quietest window still burned \(String(format: "%.2f", rate)) CPU-seconds per \
            wall-second after the child exited. A cleared readabilityHandler costs ~0; \
            the EOF spin measured ~4.0. See makeStream in Process+Extensions.swift.
            """
        )
    }

    /// A child that writes nothing still reaches EOF, which is the same trap
    /// with no output to mask it.
    @Test func silentChildAlsoSettles() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        _ = try await drain(process)

        let rate = try await quietestCPURate()

        #expect(rate < 0.6, "Silent child left a spinning handler: \(rate) CPU-seconds per wall-second while idle")
    }
}
