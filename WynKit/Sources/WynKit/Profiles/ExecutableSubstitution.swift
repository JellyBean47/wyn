//
//  ExecutableSubstitution.swift
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

/// "Put the contents of `with` where `replace` is, before this game starts."
///
/// For games whose store launches the wrong build and cannot be told otherwise.
/// Steam's Play runs a title's *default* launch option, and for DOOM (2016)
/// that is `DOOMx64.exe`, the OpenGL build, a dead end at Apple's GL 4.1
/// (`FATAL ERROR: wglCreateContextAttribsARB failed`). The Vulkan build next
/// to it works.
///
/// Doing that copy by hand does not last. Steam puts its own file back
/// whenever it checks the install, and a fresh Steam client checks every
/// library it is shown. Measured 28 Sep 2026: each new bottle queued a
/// 32 MB / 181 MB "update" of DOOM at the *same* BuildID 13954591. The one
/// that ran wrote the OpenGL build back (md5 == the backup) and DOOM crashed.
/// So Wyn applies the substitution at every launch instead, and Steam may
/// repair it as often as it likes.
///
/// Paths are relative to the game's install folder and may not leave it.
public struct ExecutableSubstitution: Codable, Equatable, Sendable {
    /// The file the store launches, e.g. `DOOMx64.exe`.
    public var replace: String
    /// The file whose contents it should have, e.g. `DOOMx64vk.exe`.
    public var with: String

    public init(replace: String, with: String) {
        self.replace = replace
        self.with = with
    }
}

public enum ExecutableSubstitutions {
    public enum Outcome: Equatable, Sendable {
        /// `replace` already had `with`'s contents.
        case alreadyInPlace(String)
        /// `replace` was overwritten; the store's file was saved as `.wyn-bak`.
        case substituted(String)
        /// Nothing done, with the reason.
        case skipped(String, reason: String)
    }

    /// Where the store's own copy of `replace` is kept.
    public static let backupSuffix = ".wyn-bak"

    /// Apply every substitution a profile declares under `installDirectory`.
    ///
    /// The backup always holds the store's latest file: whenever `replace`
    /// does not match `with`, it is by definition something the store put
    /// there (an original or an update to it), so it is saved over the old
    /// backup before being replaced. Nothing is ever deleted.
    @discardableResult
    public static func apply(
        _ substitutions: [ExecutableSubstitution],
        in installDirectory: URL
    ) -> [Outcome] {
        substitutions.map { apply($0, in: installDirectory) }
    }

    static func apply(_ substitution: ExecutableSubstitution, in root: URL) -> Outcome {
        let label = substitution.replace
        guard let target = contained(substitution.replace, in: root),
              let source = contained(substitution.with, in: root)
        else {
            return .skipped(label, reason: "path leaves the install folder")
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path(percentEncoded: false)) else {
            return .skipped(label, reason: "\(substitution.with) is not installed")
        }
        if fm.fileExists(atPath: target.path(percentEncoded: false)),
           sameContents(target, source) {
            return .alreadyInPlace(label)
        }
        do {
            if fm.fileExists(atPath: target.path(percentEncoded: false)) {
                let backup = target.deletingLastPathComponent()
                    .appending(path: target.lastPathComponent + backupSuffix)
                try replaceAtomically(backup, withContentsOf: target)
            }
            try replaceAtomically(target, withContentsOf: source)
            return .substituted(label)
        } catch {
            return .skipped(label, reason: error.localizedDescription)
        }
    }

    /// `relative` resolved under `root`, or nil when it is absolute or climbs out.
    static func contained(_ relative: String, in root: URL) -> URL? {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\\") else { return nil }
        let parts = relative.split(separator: "/")
        guard !parts.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        return parts.reduce(root) { $0.appending(path: String($1)) }
    }

    /// Size first: the two builds differ by 24 MB, so the common case never reads them.
    static func sameContents(_ a: URL, _ b: URL) -> Bool {
        let fm = FileManager.default
        guard let sa = (try? fm.attributesOfItem(atPath: a.path(percentEncoded: false)))?[.size] as? NSNumber,
              let sb = (try? fm.attributesOfItem(atPath: b.path(percentEncoded: false)))?[.size] as? NSNumber,
              sa == sb
        else { return false }
        guard let da = try? Data(contentsOf: a, options: .mappedIfSafe),
              let db = try? Data(contentsOf: b, options: .mappedIfSafe)
        else { return false }
        return da == db
    }

    /// Copy beside `destination`, then swap it in, so a crash mid-copy never
    /// leaves a half-written executable where the store expects one.
    private static func replaceAtomically(_ destination: URL, withContentsOf source: URL) throws {
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).wyn-staging")
        if fm.fileExists(atPath: staging.path(percentEncoded: false)) {
            try fm.removeItem(at: staging)
        }
        try fm.copyItem(at: source, to: staging)
        if fm.fileExists(atPath: destination.path(percentEncoded: false)) {
            _ = try fm.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: destination)
        }
    }
}
