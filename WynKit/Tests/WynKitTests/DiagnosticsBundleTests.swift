import Foundation
import Testing
@testable import WynKit

/// A diagnostics bundle is made to be emailed to a stranger. These tests are
/// the reason it can be: they pin what must never leave the tester's machine.
///
/// Every input line below is real in shape — copied from the logs the bundle
/// actually collects — because a redactor tested only against invented strings
/// tends to miss the format that matters.
@Suite("Diagnostics bundle")
struct DiagnosticsBundleTests {

    private let home = "/Users/alice"
    private let user = "alice"

    private func scrub(_ text: String) -> String {
        DiagnosticsBundle.redact(text, homeDirectory: home, userName: user)
    }

    // MARK: - What must never leave the machine

    /// Steam stamps the SteamID on nearly every webhelper line.
    @Test func steamIDIsRemoved() {
        let line = #"-steampid=560 -steamid=76561198012345678 -buildid=1788291500"#
        let out = scrub(line)
        #expect(!out.contains("76561198012345678"))
        #expect(out.contains("<steamid>"))
        #expect(out.contains("-buildid=1788291500"))   // build ids are not personal
    }

    @Test func emailIsRemoved() {
        let out = scrub("logon failure for someone@example.com (retry 2)")
        #expect(!out.lowercased().contains("someone@example.com"))
        #expect(out.contains("<email>"))
    }

    /// The home path is in every Wine command line, both spellings.
    @Test func homePathIsRemovedInBothSpellings() {
        let unix = scrub("/Users/alice/Library/Containers/com.fly.gaming/Bottles/ABC")
        #expect(!unix.contains("/Users/alice"))
        #expect(unix.hasPrefix("~/Library/Containers"))

        let windows = scrub(#"Z:\Users\alice\Library\Containers\com.fly.gaming"#)
        #expect(!windows.lowercased().contains(#"users\alice"#))
    }

    /// A log written before a move, or on another volume, still carries the
    /// short name outside any path the home pass covers.
    @Test func bareUserNameIsRemoved() {
        let out = scrub("owner: alice   group: staff")
        #expect(!out.contains("alice"))
        #expect(out.contains("<user>"))
        #expect(out.contains("staff"))
    }

    /// Wine's own user is literally "crossover" — that is not the tester, and
    /// scrubbing it would make paths unreadable for no gain.
    @Test func wineUserIsNotTouched() {
        let out = scrub(#"C:\users\crossover\AppData\Local\Steam\htmlcache"#)
        #expect(out.contains("crossover"))
    }

    /// A two-letter user name would shred every log it appears in. Guarded.
    @Test func veryShortUserNameIsNotSubstituted() {
        let out = DiagnosticsBundle.redact(
            "an image was placed in the frame",
            homeDirectory: "/Users/an",
            userName: "an"
        )
        #expect(out.contains("an image"))
    }

    /// Redaction must not destroy the evidence the bundle exists to carry.
    @Test func theDiagnosticEvidenceSurvivesRedaction() {
        let line = #"[2026-09-03 01:06:51] Startup - webhelper launched pid: 1268 commandline: "C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper_real.exe" --disable-gpu --in-process-gpu -steamid=76561198012345678"#
        let out = scrub(line)
        #expect(out.contains("cef.win64"))
        #expect(out.contains("steamwebhelper_real.exe"))
        #expect(out.contains("--in-process-gpu"))
        #expect(out.contains("2026-09-03 01:06:51"))
        #expect(!out.contains("76561198012345678"))
    }

    @Test func verifyLoopEvidenceSurvivesRedaction() {
        let line = #"[2026-09-03 00:14:08] BVerifyInstalledFiles: bin\cef\cef.win64\steamwebhelper.exe is 151908 bytes, expected 7488152"#
        let out = scrub(line)
        #expect(out.contains("151908"))
        #expect(out.contains("7488152"))
        #expect(out.contains("BVerifyInstalledFiles"))
    }

    // MARK: - Files that are refused outright

    @Test func credentialFilesAreExcluded() {
        #expect(DiagnosticsBundle.isExcluded(fileName: "loginusers.vdf"))
        #expect(DiagnosticsBundle.isExcluded(fileName: "config.vdf"))
        #expect(DiagnosticsBundle.isExcluded(fileName: "ssfn2048116977000000000"))
        #expect(DiagnosticsBundle.isExcluded(fileName: "SSFN123"))          // case
        #expect(DiagnosticsBundle.isExcluded(fileName: "libraryfolders.vdf"))
    }

    @Test func logFilesAreAllowed() {
        for name in DiagnosticsBundle.steamLogNames {
            #expect(!DiagnosticsBundle.isExcluded(fileName: name), "\(name) should be collectable")
        }
        #expect(!DiagnosticsBundle.isExcluded(fileName: "wyn-launch.log"))
    }

    /// The collector is a whitelist, so no name in it may be a credential file.
    /// This is the test that fails if someone adds `config.vdf` to the list.
    @Test func theWhitelistContainsNothingSensitive() {
        for name in DiagnosticsBundle.steamLogNames {
            #expect(!name.lowercased().hasSuffix(".vdf"))
            #expect(!name.lowercased().hasPrefix("ssfn"))
        }
    }

    // MARK: - Trimming

    /// Steam's logs are CRLF, and Swift reads "\r\n" as one Character, so a
    /// literal "\n" split sees one enormous line and trims nothing — the file
    /// then arrives whole, which is how a megabyte log gets into a bundle.
    @Test func crlfLogsAreTrimmed() {
        let text = (1...500).map { "line \($0)" }.joined(separator: "\r\n")
        let out = DiagnosticsBundle.tail(text, lines: 100)
        #expect(out.contains("400 earlier line(s) trimmed"))
        #expect(out.contains("line 500"))
        #expect(!out.contains("line 1\r"))
    }

    @Test func shortLogsAreNotTrimmed() {
        let text = (1...10).map { "line \($0)" }.joined(separator: "\n")
        #expect(DiagnosticsBundle.tail(text, lines: 100) == text)
    }

    /// Trimming keeps the END — a launch failure is always at the end — and
    /// says it trimmed, so nobody chases a launch that was merely cut off.
    @Test func longLogsKeepTheirTailAndSaySo() {
        let text = (1...500).map { "line \($0)" }.joined(separator: "\n")
        let out = DiagnosticsBundle.tail(text, lines: 100)
        #expect(out.contains("line 500"))
        #expect(out.contains("line 401"))
        #expect(!out.contains("\nline 400\n"))
        #expect(out.contains("400 earlier line(s) trimmed"))
    }

    // MARK: - End to end

    /// Build a real bundle from a fake bottle whose Steam logs carry
    /// credentials, then read every byte back out of the zip. Nothing
    /// identifying may survive, and the CEF evidence must be there.
    @Test func aRealBundleCarriesEvidenceAndNoCredentials() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: "Library/Caches/com.wyn.gaming/DiagnosticsTests")
            .appending(path: UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let bottle = Bottle(bottleUrl: root.appending(path: "bottle"))
        let steam = SteamCEFShim.steamRoot(in: bottle)
        let logs = steam.appending(path: "logs")
        let config = steam.appending(path: "config")
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        try fm.createDirectory(at: config, withIntermediateDirectories: true)

        try #"""
        [2026-09-03 01:06:51] Startup - webhelper launched pid: 1268 commandline: "C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper_real.exe" --disable-gpu --in-process-gpu -steamid=76561198012345678
        """#.write(to: logs.appending(path: "webhelper.txt"), atomically: true, encoding: .utf8)

        // The file that must never be read, holding the thing that must never leak.
        try #"""
        "ConnectCache" { "1234" "TOPSECRETJWTVALUE" }
        """#.write(to: config.appending(path: "config.vdf"), atomically: true, encoding: .utf8)
        try #"""
        "users" { "76561198012345678" { "AccountName" "alice_secret" } }
        """#.write(to: config.appending(path: "loginusers.vdf"), atomically: true, encoding: .utf8)

        let out = root.appending(path: "out")
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let result = try DiagnosticsBundle.create(bottle: bottle, destinationDirectory: out)

        #expect(fm.fileExists(atPath: result.url.path(percentEncoded: false)))
        #expect(result.byteCount > 0)

        // Unpack and read everything back.
        let unpacked = root.appending(path: "unpacked")
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", result.url.path(percentEncoded: false),
                           unpacked.path(percentEncoded: false)]
        try unzip.run()
        unzip.waitUntilExit()
        #expect(unzip.terminationStatus == 0)

        var combined = ""
        var names: [String] = []
        if let walker = fm.enumerator(at: unpacked, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where !url.hasDirectoryPath {
                names.append(url.lastPathComponent)
                combined += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
        }

        // The evidence is present.
        #expect(names.contains("README.txt"))
        #expect(names.contains("cef-shim.txt"))
        #expect(names.contains("webhelper.txt"))
        #expect(combined.contains("--in-process-gpu"))

        // The credentials are not — neither the files nor their contents.
        #expect(!names.contains("config.vdf"))
        #expect(!names.contains("loginusers.vdf"))
        #expect(!combined.contains("TOPSECRETJWTVALUE"))
        #expect(!combined.contains("alice_secret"))
        #expect(!combined.contains("76561198012345678"))
        #expect(!combined.contains(NSHomeDirectory()))
    }
}
