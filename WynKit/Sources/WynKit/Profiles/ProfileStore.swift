//
//  ProfileStore.swift
//  WynKit
//

import Foundation
import os.log

public enum ProfileStore {
    public static let bundledProfilesDirectory = "Profiles"

    public static func loadAll(additionalDirectories: [URL] = []) -> [GameProfile] {
        var profiles: [GameProfile] = []
        var seen: Set<String> = []

        for profile in loadBundledProfiles() + loadFromDirectories(additionalDirectories) {
            guard !seen.contains(profile.id) else { continue }
            profiles.append(profile)
            seen.insert(profile.id)
        }

        if FileManager.default.fileExists(atPath: userProfilesDirectory.path(percentEncoded: false)) {
            for profile in (try? loadFrom(directory: userProfilesDirectory)) ?? [] where !seen.contains(profile.id) {
                profiles.append(profile)
                seen.insert(profile.id)
            }
        }

        return profiles.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func profile(id: String, additionalDirectories: [URL] = []) -> GameProfile? {
        loadAll(additionalDirectories: additionalDirectories).first { $0.id == id }
    }

    public static func match(executable: URL, additionalDirectories: [URL] = []) -> GameProfile? {
        loadAll(additionalDirectories: additionalDirectories).first { $0.matches(executable: executable) }
    }

    public static var userProfilesDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: Bundle.wynSupportIdentifier)
            .appending(path: "Profiles")
    }

    private static func loadBundledProfiles() -> [GameProfile] {
        var profiles: [GameProfile] = []
        let decoder = JSONDecoder()

        if let urls = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: nil) {
            for url in urls {
                guard GameCatalog.isProfileResource(url) else { continue }
                if let profile = decodeProfile(at: url, decoder: decoder) {
                    profiles.append(profile)
                }
            }
        }

        if let urls = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: bundledProfilesDirectory) {
            for url in urls {
                guard GameCatalog.isProfileResource(url) else { continue }
                if let profile = decodeProfile(at: url, decoder: decoder) {
                    profiles.append(profile)
                }
            }
        }

        return profiles
    }

    private static func loadFromDirectories(_ directories: [URL]) -> [GameProfile] {
        directories.flatMap { (try? loadFrom(directory: $0)) ?? [] }
    }

    public static func loadFrom(directory: URL) throws -> [GameProfile] {
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else {
            return []
        }

        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let decoder = JSONDecoder()

        return contents.compactMap { url in
            guard url.pathExtension == "json" else { return nil }
            guard GameCatalog.isProfileResource(url) else { return nil }
            return decodeProfile(at: url, decoder: decoder)
        }
    }

    private static func decodeProfile(at url: URL, decoder: JSONDecoder) -> GameProfile? {
        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode(GameProfile.self, from: data)
        } catch {
            Logger.wynKit.error("Failed to decode profile at \(url.path): \(error)")
            return nil
        }
    }

    public static func save(profile: GameProfile) throws {
        let directory = userProfilesDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: profile.id).appendingPathExtension("json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profile).write(to: url)
    }
}
