//
//  DiagnosticsBundle.swift
//  WynKit
//
//  One zip on the Desktop that answers "why did it not work" without the
//  person who hit the bug needing to know where anything lives.
//
//  This exists because of the black Steam login window (#36, #39). Diagnosing
//  it took bottle directory birth times, a grep of Steam's webhelper.txt for
//  `--in-process-gpu`, and a count of BVerifyInstalledFiles hits in
//  bootstrap_log.txt — three files buried inside a bottle, none of which a
//  tester could be expected to find, on a machine nobody else can reach. A
//  report that says "it was black" cannot be actioned. This bundle is what
//  turns that report into the one we could actually diagnose.
//
//  A bundle is meant to be emailed to a stranger, so it is built by
//  WHITELIST — named files are copied in, directories are never walked
//  wholesale — and everything that goes in is redacted. Steam's `config/`
//  holds the account name and the remember-me JWT and is never read at all.
//

import Foundation

public enum DiagnosticsBundle {

    // MARK: - Redaction

    /// Belt to the whitelist's braces. Nothing matching this may enter a
    /// bundle even if some future caller points the collector at a directory.
    ///
    /// `config.vdf` carries the remember-me JWT; `loginusers.vdf` the account
    /// name and SteamID; `ssfn*` are Steam's auth blobs. Any of the three is a
    /// credential leak, so the whole `.vdf` family is refused rather than
    /// enumerated — no vdf is worth the risk of being wrong about.
    public static func isExcluded(fileName: String) -> Bool {
        let lower = fileName.lowercased()
        if lower.hasPrefix("ssfn") { return true }
        if lower.hasSuffix(".vdf") { return true }
        if lower.contains("loginusers") || lower.contains("credential") { return true }
        return false
    }

    /// Strip anything that identifies the person or their account.
    ///
    /// Steam's logs carry the SteamID on nearly every webhelper line
    /// (`-steamid=76561198…`), the account name on login, and the full home
    /// path in every Wine command line. None of it is needed to diagnose a
    /// launch failure, and all of it is the tester's, not ours.
    ///
    /// `homeDirectory` and `userName` are parameters rather than reads of the
    /// environment so this stays a pure function and the tests can prove it.
    public static func redact(
        _ text: String,
        homeDirectory: String,
        userName: String
    ) -> String {
        var out = text

        // Longest-first, or "/Users/alice" inside "/Users/alice/Library" leaves
        // a stray fragment behind.
        if !homeDirectory.isEmpty {
            out = out.replacingOccurrences(of: homeDirectory, with: "~")
            // Wine logs the same path Z:-prefixed with backslashes.
            let windowsHome = "Z:" + homeDirectory.replacingOccurrences(of: "/", with: "\\")
            out = out.replacingOccurrences(of: windowsHome, with: "Z:\\~", options: .caseInsensitive)
        }

        out = replacingMatches(in: out, pattern: "7656[0-9]{13}", with: "<steamid>")
        out = replacingMatches(in: out, pattern: "\\b[0-9]{16,20}\\b", with: "<id>")
        out = replacingMatches(
            in: out,
            pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}",
            with: "<email>"
        )

        // The macOS short name survives inside paths the home-directory pass
        // does not cover — a different volume, a log written before the move.
        // Guarded: a one- or two-letter user name would shred the text.
        if userName.count >= 3 {
            out = replacingMatches(
                in: out,
                pattern: "\\b" + NSRegularExpression.escapedPattern(for: userName) + "\\b",
                with: "<user>",
                options: [.caseInsensitive]
            )
        }
        return out
    }

    private static func replacingMatches(
        in text: String,
        pattern: String,
        with replacement: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: replacement
        )
    }

    // MARK: - Trimming

    /// Steam's `webhelper.txt` runs to megabytes and the interesting part is
    /// always the end. Keep the tail; say so in the file rather than silently
    /// truncating, or the next reader will chase a launch that was simply cut.
    /// Splits on newline-ness, not on a "\n" literal: Steam's logs are CRLF and
    /// Swift treats "\r\n" as one Character, so a literal split leaves the
    /// whole file as a single line and trims nothing.
    public static func tail(_ text: String, lines limit: Int) -> String {
        let all = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard all.count > limit else { return text }
        let kept = all.suffix(limit).joined(separator: "\n")
        return "[… \(all.count - limit) earlier line(s) trimmed by wyn diagnostics …]\n" + kept
    }
}
